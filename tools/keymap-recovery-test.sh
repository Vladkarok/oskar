#!/usr/bin/env bash
# Ticket 06's acceptance choreography — run INSIDE the VM, against the
# live session (see docs/vm-handoff.md first).
#
#   tools/keymap-recovery-test.sh run|cleanup
#
# `run` walks the audit's scenarios with custom keymaps chosen so every
# cap assertion DISCRIMINATES from the fallback: dvorak (AD01=', against
# us q) starts, colemak (AD01=q) is the edited replacement — each step's
# glyph can only come from the custom file being read fresh:
#   1. the user's own kb_file is captured, recorded in the helper's
#      sidecar, and the compositor is pointed at the published keymap;
#   2. shell SIGKILL with the helper alive: the compositor is left on the
#      published keymap, and the NEW shell's panel recovers the source
#      from the sidecar — caps and typing still derive from the custom
#      file (AD01 = q);
#   3. helper restart in the same session: whatever systemd does to the
#      runtime directory, the live panel re-feeds the source and the
#      sidecar converges back;
#   4. an edited custom file at the same path changes the caps on the
#      next configure (dvorak: AD01 = ');
#   5. an unrelated path whose suffix resembles the published path is
#      treated as the USER's file, never as ours;
#   6. clearing the user's kb_file clears the record.
#
# `cleanup` puts the compositor back on RMLVO and removes the fixtures.

set -euo pipefail

phase="${1:-}"
[[ -n "$phase" ]] || { echo "usage: tools/keymap-recovery-test.sh run|cleanup" >&2; exit 2; }

PLUGIN_ID=io.github.vladkarok.osk
CUSTOM="$HOME/osk-06-custom.xkb"
LOOKALIKE_DIR="$HOME/osk-06-lookalike/omarchy-osk"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-osk"
SIDECAR="$RUNTIME_DIR/user-keymap-source"
PUBLISHED="$RUNTIME_DIR/keymap.xkb"
PASS=0
FAIL=0

ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
no() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else no "$3 (wanted: $2, got: ${1:-<none>})"; fi; }

session_env() {
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
  export OMARCHY_PATH=/usr/share/omarchy
  local sig
  sig="$(for d in "$XDG_RUNTIME_DIR"/hypr/*/; do
    printf 'j/version' | socat - UNIX-CONNECT:"$d.socket.sock" >/dev/null 2>&1 && basename "$d"
  done | tail -1)"
  [[ -n "$sig" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$sig" || true
}

set_kbfile() {
  hyprctl eval "hl.config({input = {kb_file = '${1:-}'}})" >/dev/null
}

get_kbfile() {
  hyprctl getoption input:kb_file -j | jq -r '.str // ""'
}

# One keycap fact for a position, from the live helper. The positional
# caps request answers `caps\t<gen>\t<group>\t<position>\x1F<t><glyph>...`:
# tabs to the record section, 0x1F between a record's fields, and the
# first level field is a type tag ('t') followed by the glyph.
cap_for() {
  printf 'caps 0 %s\n' "$1" | timeout 2 socat -t1 - \
    UNIX-CONNECT:"$RUNTIME_DIR/control.sock" 2>/dev/null |
    python3 -c '
import sys
line = sys.stdin.read().split("\n")[0]
parts = line.split("\t", 4)
if len(parts) < 4 or not parts[3]:
    sys.exit(0)
fields = parts[3].split("\x1f")
first = fields[1] if len(fields) > 1 else ""
print(first[1:] if first[:1] == "t" else first)
'
}

hello() {
  printf 'hello 5\n' | timeout 2 socat -t1 - UNIX-CONNECT:"$RUNTIME_DIR/control.sock" 2>/dev/null |
    head -n1
}

panel_open() {
  omarchy-shell shell toggle "$PLUGIN_ID" >/dev/null 2>&1 || true
}

shell_pid() { pgrep -x quickshell | head -1; }

# The shell is no unit in this session: uwsm spawns it as a bare process
# (`quickshell -n -p /usr/share/omarchy/shell`). Respawn it the same way.
start_shell() {
  (setsid quickshell -n -p /usr/share/omarchy/shell >/dev/null 2>&1 &)
}

sidecar_value() { cat "$SIDECAR" 2>/dev/null | tr -d '\n'; }
kbfile_value() { get_kbfile; }
ad01_cap() { cap_for AD01; }
kbfile_value() { get_kbfile; }

wait_for() {
  local desc="$1" wanted="$2" getter="$3" tries=40 out=""
  while ((tries-- > 0)); do
    out="$("$getter")"
    [[ "$out" == "$wanted" ]] && break
    sleep 0.5
  done
  printf '%s' "$out"
}

phase_run() {
  session_env
  # Settle first: a helper restart that just happened (an upgrade, a setup)
  # needs a beat before its socket answers, and the choreography's first
  # assertions otherwise race the service's own start.
  local settle=20
  while ((settle-- > 0)); do
    [[ "$(hello)" == "hello 5" ]] && break
    sleep 0.5
  done
  command -v xkbcli >/dev/null || { sudo pacman -Sy --noconfirm libxkbcommon >/dev/null; }

  # Fixtures: dvorak first (AD01='), colemak as the later edit (AD01=q),
  # and a lookalike directory whose suffix is our published path (its
  # content stays dvorak while $CUSTOM moves on, so step 5 discriminates).
  xkbcli compile-keymap --layout us --variant dvorak >"$CUSTOM"
  mkdir -p "$LOOKALIKE_DIR"
  cp "$CUSTOM" "$LOOKALIKE_DIR/keymap.xkb"

  # --- 1. capture: the user sets a custom kb_file, the panel adopts it,
  # records it, and points the compositor at the published keymap.
  set_kbfile "$CUSTOM"
  panel_open; sleep 4
  local side
  side="$(wait_for sidecar "$CUSTOM" sidecar_value)"
  check "$side" "$CUSTOM" "the helper recorded the user's kb_file source"
  local pub
  pub="$(wait_for published "$PUBLISHED" kbfile_value)"
  check "$pub" "$PUBLISHED" "the compositor is on the published keymap"
  check "$(cap_for AD01)" "'" "typing derives from the custom file (AD01=', dvorak)"

  # --- 2. shell SIGKILL, then a HELPER RESTART while the shell is dead:
  # RuntimeDirectoryPreserve keeps the runtime directory across service
  # stops, and this is the probe that it really does — a Preserve
  # regression deletes the record here and step 8 below fails with the
  # us fallback's q. The compositor stays on the published keymap, and
  # the sidecar is the ONLY record left.
  local oldpid
  oldpid="$(shell_pid)"
  kill -9 "$oldpid"
  sleep 2
  check "$(get_kbfile)" "$PUBLISHED" "SIGKILL left the compositor on the published keymap"
  check "$(hello)" "hello 5" "the helper survived the shell's death"
  systemctl --user restart omarchy-osk.service
  sleep 2
  check "$(cat "$SIDECAR" 2>/dev/null | tr -d '\n')" "$CUSTOM" \
    "the record survived the helper restart (RuntimeDirectoryPreserve)"
  start_shell
  sleep 6
  local seed
  seed="$(wait_for sidecar2 "$CUSTOM" sidecar_value)"
  check "$seed" "$CUSTOM" "the new shell recovered the source from the sidecar"
  # Discriminating: the restarted helper's own default is us (AD01=q);
  # seeing dvorak's quote means the fresh panel REALLY re-fed the custom
  # file through the recovery seed.
  check "$(cap_for AD01)" "'" "caps derive from the custom file after crash+helper-restart (AD01=')"

  # --- 3. helper restart in the same session: the live panel re-feeds the
  # source on the new handshake whatever systemd did to the runtime dir.
  systemctl --user restart omarchy-osk.service
  sleep 3
  check "$(hello)" "hello 5" "the helper restarted in the same session"
  local after
  after="$(wait_for sidecar3 "$CUSTOM" sidecar_value)"
  check "$after" "$CUSTOM" "the sidecar converged back after the helper restart"
  check "$(cap_for AD01)" "'" "typing still derives from the custom file (AD01=')"

  # --- 3.5 the routine trigger: `omarchy-osk upgrade` restarts the helper
  # and then the shell — with the custom map set, nothing may lose it.
  omarchy-osk upgrade >/dev/null
  sleep 4
  check "$(cat "$SIDECAR" 2>/dev/null | tr -d '\n')" "$CUSTOM" \
    "the record survived omarchy-osk upgrade's helper restart"
  check "$(ad01_cap)" "'" "typing derives from the custom file after upgrade (AD01=')"

  # --- 4. an edited custom file at the same path: the record holds the
  # PATH, the compile reads fresh content.
  xkbcli compile-keymap --layout us --variant colemak >"$CUSTOM"
  systemctl --user restart omarchy-osk.service
  sleep 4
  local cap
  cap="$(wait_for cap-colemak "q" ad01_cap)"
  check "$cap" "q" "an edited file at the same path recompiles (AD01=q, colemak)"
  side="$(cat "$SIDECAR" 2>/dev/null | tr -d '\n')"
  check "$side" "$CUSTOM" "the edited file did not disturb the record"

  # --- 5. a lookalike path is the USER's file: remembered, never treated
  # as the published keymap.
  set_kbfile "$LOOKALIKE_DIR/keymap.xkb"
  sleep 4
  side="$(cat "$SIDECAR" 2>/dev/null | tr -d '\n')"
  check "$side" "$LOOKALIKE_DIR/keymap.xkb" "a lookalike path is recorded as the user's own"
  check "$(ad01_cap)" "'" "the lookalike file's own content types (AD01=', dvorak — not the colemak it replaced)"

  # --- 6. clearing the user's kb_file clears the record.
  set_kbfile ""
  sleep 4
  [[ ! -e "$SIDECAR" ]] && ok "clearing kb_file cleared the record" \
    || no "the record outlived the cleared setting ($(cat "$SIDECAR" 2>/dev/null))"

  printf -- '--- run: %d passed, %d failed ---\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

phase_cleanup() {
  session_env
  set_kbfile ""
  rm -f "$CUSTOM"
  rm -rf "$HOME/osk-06-lookalike"
  echo "fixtures removed; kb_file back to RMLVO"
}

case "$phase" in
run) phase_run ;;
cleanup) phase_cleanup ;;
*) echo "unknown phase: $phase" >&2; exit 2 ;;
esac
