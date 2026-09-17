#!/usr/bin/env bash
# The regression wall (ticket 43): ONE command, every layer, one table.
#
# The breakage classes we actually shipped are netted layer by layer:
#   host battery    — the pure JS seams (13 suites) + qmllint's fatal
#                     class + the packaging file-set gate (renames,
#                     constants, contract drift — classes 1 and 5)
#   provenance      — zero shared lines with the upstream sketch
#   clippy          — the daemon's own regressions (class 6)
#   live legs (lab) — the REAL panel from the tree in the disposable
#                     lab: the canary (packaged-panel load + facts,
#                     classes 2 and 3), the restart-settle repro (the
#                     incident's bounce — class 4), and the chooser
#                     through the real UI path. Over ssh, hostname-
#                     gated by the legs themselves; a BUSY lab (another
#                     tenant holds it) skips the live layers LOUDLY —
#                     the wall never hangs or fails silently.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAB=omarchy-vm
declare -a ROWS
wall=0

row() { # <name> <status> <detail>
  ROWS+=("$(printf '%-14s %-4s %s' "$1" "$2" "$3")")
  [[ "$2" == "PASS" ]] || wall=1
}

echo "== host battery"
if (cd "$root" && ./tools/run-tests.sh >/tmp/wall-host.log 2>&1); then
  row "host-battery" PASS "$(grep -cE 'passed, 0 failed' /tmp/wall-host.log) suites + qml gates"
else
  row "host-battery" FAIL "tail: $(tail -n 3 /tmp/wall-host.log | tr '\n' ' ')"
fi

echo "== provenance"
if (cd "$root" && ./tools/provenance.py >/tmp/wall-prov.log 2>&1); then
  row "provenance" PASS "$(grep -oE 'total +0 / [0-9]+' /tmp/wall-prov.log | tail -1)"
else
  row "provenance" FAIL "see /tmp/wall-prov.log"
fi

echo "== clippy"
if (cd "$root" && cargo clippy --manifest-path daemon/Cargo.toml \
      --all-targets --quiet -- -D warnings >/tmp/wall-clippy.log 2>&1); then
  row "clippy" PASS "daemon clean under -D warnings"
else
  row "clippy" FAIL "see /tmp/wall-clippy.log"
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
  # the older pattern (ticket 48 review).
  if pgrep -f "integration/panel_canary" >/dev/null 2>&1 \
      || ssh "$LAB" 'pgrep -f "integration/(panel_canary|restart_settle|chooser35|emoji_focus|hold_column|qmp_guest_frame)" >/dev/null 2>&1'; then
    row "live-legs" SKIP "another tenant holds the lab — rerun when free"
  else
    # The live legs need the lab session's own environment (the wall's
    # first live run found the latent bug: ssh without it dies at the
    # socket wait) — the vm-handoff.md pattern, sourced guest-side.
    for leg in panel_canary restart_settle; do
      echo "== live: $leg"
      env_var="OSK_$(echo "$leg" | tr 'a-z' 'A-Z')_LIVE=1"
      # Each leg's own convention: the canary gate is OSK_PANEL_CANARY_LIVE.
      case "$leg" in
        panel_canary) env_var="OSK_PANEL_CANARY_LIVE=1" ;;
        restart_settle) env_var="OSK_RESTART_SETTLE_LIVE=1" ;;
      esac
      if ssh "$LAB" "cd ~/oskar \
          && export XDG_RUNTIME_DIR=/run/user/\$(id -u) \
          && export HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t \$XDG_RUNTIME_DIR/hypr | head -1) \
          && export WAYLAND_DISPLAY=wayland-1 \
          && env $env_var python3 tools/integration/$leg.py" \
          >"/tmp/wall-$leg.log" 2>&1; then
        row "$leg" PASS "$(grep -cE '^ok ' "/tmp/wall-$leg.log") assertions"
      else
        row "$leg" FAIL "see /tmp/wall-$leg.log"
      fi
    done
    # The QMP half (ticket 48): the canary's mask and real-click legs run
    # HOST-side against the lab over the virsh monitor — the one row that
    # proves compositor-routed clicks reach the daemon. Same tenancy as
    # the guest legs above; the sudo password for the strace oracle comes
    # from the environment (never a literal — see panel_canary.py).
    if [[ -n "${OSK_LAB_SUDO_PASSWORD:-}" ]]; then
      echo "== live: canary-qmp (host half)"
      if (cd "$root" && OSK_PANEL_CANARY_LIVE=1 OSK_CANARY_QMP=1 \
            python3 tools/integration/panel_canary.py) \
          >/tmp/wall-canary-qmp.log 2>&1; then
        row "canary-qmp" PASS "$(grep -cE '^ok ' /tmp/wall-canary-qmp.log) assertions"
      else
        row "canary-qmp" FAIL "see /tmp/wall-canary-qmp.log"
      fi
    else
      row "canary-qmp" SKIP "set OSK_LAB_SUDO_PASSWORD for the strace oracle"
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
