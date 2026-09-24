#!/usr/bin/env bash
# The regression wall: ONE command, every layer, one table.
#
# The breakage classes we actually shipped are netted layer by layer:
#   host battery    — the pure JS seams (13 suites) + qmllint's fatal
#                     class + the packaging file-set gate (renames,
#                     constants, contract drift — classes 1 and 5)
#   clippy          — the daemon's own regressions (class 6)
#   live legs (lab) — the REAL panel from the tree in the disposable
#                     lab: the canary (packaged-panel load + facts,
#                     classes 2 and 3), the restart-settle repro (the
#                     incident's bounce — class 4), the layout audit
#                     (no two click targets collide), and the canary's
#                     QMP clicks through the compositor. Over ssh, hostname-
#                     gated by the legs themselves; a BUSY lab (another
#                     tenant holds it) skips the live layers LOUDLY —
#                     the wall never hangs or fails silently.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WALL_TMP="$(mktemp -d /tmp/oskar-wall.XXXXXX)" || exit 1
# A failing row's detail points into WALL_TMP, so the logs outlive the run
# whenever anything failed; a clean run leaves nothing behind.
trap 'if (( failed )); then echo "logs kept in $WALL_TMP"; else rm -rf "$WALL_TMP"; fi' EXIT
LAB=omarchy-vm
declare -a ROWS
wall=0
failed=0

row() { # <name> <status> <detail>
  ROWS+=("$(printf '%-14s %-4s %s' "$1" "$2" "$3")")
  [[ "$2" == "PASS" ]] || wall=1
  [[ "$2" == "FAIL" ]] && failed=1
  return 0
}

echo "== host battery"
if (cd "$root" && ./tools/run-tests.sh >"$WALL_TMP"/host.log 2>&1); then
  row "host-battery" PASS "$(grep -cE 'passed, 0 failed' "$WALL_TMP"/host.log) suites + qml gates"
else
  row "host-battery" FAIL "tail: $(tail -n 3 "$WALL_TMP"/host.log | tr '\n' ' ')"
fi

echo "== clippy"
if (cd "$root" && cargo clippy --manifest-path daemon/Cargo.toml \
      --all-targets --quiet -- -D warnings >"$WALL_TMP"/clippy.log 2>&1); then
  row "clippy" PASS "daemon clean under -D warnings"
else
  row "clippy" FAIL "see $WALL_TMP/clippy.log"
fi

# The lab layers: deliberate (OSK_WALL_LIVE=1), and only when the lab is
# ours — the legs stop the lab's service and drive its session, so a lab
# held by another working agent (a design pass, a choreography) must not
# be barged into on a process-name guess. A held or unreachable lab
# skips LOUDLY; the host layers above always stand on their own.
if [[ "${OSK_WALL_LIVE:-}" != "1" ]]; then
  row "live-legs" SKIP "set OSK_WALL_LIVE=1 for the lab layers"
elif ssh -o ConnectTimeout=5 "$LAB" true 2>/dev/null; then
  # Tenancy: BOTH halves of a standing leg must be visible — the QMP
  # legs run their host half (virsh monitor + this script's children)
  # while the guest frame runs in the lab, so a running qmp_guest_frame
  # means the lab is held even though no guest-side leg process matches
  # the other legs' pattern.
  if pgrep -f "integration/panel_canary" >/dev/null 2>&1 \
      || ssh "$LAB" 'pgrep -f "integration/(panel_canary|restart_settle|chooser35|emoji_focus|hold_column|qmp_guest_frame|layout_leg|socket_rebuild)" >/dev/null 2>&1'; then
    row "live-legs" SKIP "another tenant holds the lab — rerun when free"
  else
    # The live legs need the lab session's own environment (the wall's
    # first live run found the latent bug: ssh without it dies at the
    # socket wait) — the vm-handoff.md pattern, sourced guest-side.
    for leg in panel_canary restart_settle layout_leg; do
      echo "== live: $leg"
      env_var="OSK_$(echo "$leg" | tr 'a-z' 'A-Z')_LIVE=1"
      # Each leg's own convention: the canary gate is OSK_PANEL_CANARY_LIVE.
      case "$leg" in
        panel_canary) env_var="OSK_PANEL_CANARY_LIVE=1" ;;
        restart_settle) env_var="OSK_RESTART_SETTLE_LIVE=1" ;;
        layout_leg) env_var="OSK_LAYOUT_LIVE=1" ;;
      esac
      # The live signature is PROBED, not guessed: `ls -t | head -1`
      # can grab a corpse, since interrupted leg runs leave
      # dead sig dirs behind, and the live session's dir can be the
      # OLDEST of the bunch. Newest-first, but only a signature whose
      # socket actually answers hyprctl counts; none answering is a lab
      # without a session — loud, not a fake run.
      if ssh "$LAB" "cd ~/oskar \
          && export XDG_RUNTIME_DIR=/run/user/\$(id -u) \
          && sig=\$(for s in \$(ls -t \$XDG_RUNTIME_DIR/hypr 2>/dev/null); do \
                timeout 2 hyprctl -i \"\$s\" version >/dev/null 2>&1 \
                  && { echo \"\$s\"; break; }; \
              done) \
          && { [ -n \"\$sig\" ] || { \
                echo 'no live Hyprland signature in the lab — is the session up?'; \
                exit 1; }; } \
          && export HYPRLAND_INSTANCE_SIGNATURE=\$sig \
          && export WAYLAND_DISPLAY=wayland-1 \
          && env $env_var python3 tools/integration/$leg.py" \
          >"$WALL_TMP/$leg.log" 2>&1; then
        row "$leg" PASS "$(grep -cE '^ok ' "$WALL_TMP/$leg.log") assertions"
      else
        row "$leg" FAIL "see $WALL_TMP/$leg.log"
      fi
    done
    # The QMP half: the canary's mask and real-click legs run
    # HOST-side against the lab over the virsh monitor — the one row that
    # proves compositor-routed clicks reach the daemon. Same tenancy as
    # the guest legs above; the strace oracle uses the lab's passwordless
    # sudo.
    echo "== live: canary-qmp (host half)"
    if (cd "$root" && OSK_PANEL_CANARY_LIVE=1 OSK_CANARY_QMP=1 \
          python3 tools/integration/panel_canary.py) \
        >"$WALL_TMP/canary-qmp.log" 2>&1; then
      row "canary-qmp" PASS "$(grep -cE '^ok ' "$WALL_TMP/canary-qmp.log") assertions"
    else
      row "canary-qmp" FAIL "see $WALL_TMP/canary-qmp.log"
    fi
  fi
else
  row "live-legs" SKIP "lab unreachable — host layers above still stand"
fi

echo
echo "==================== regression wall ===================="
printf '%s\n' "${ROWS[@]}"
echo "========================================================="
exit "$wall"
