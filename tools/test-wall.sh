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
  if ssh "$LAB" 'pgrep -f "integration/(panel_canary|restart_settle|chooser35|emoji_focus|hold_column)" >/dev/null 2>&1'; then
    row "live-legs" SKIP "another tenant holds the lab — rerun when free"
  else
    for leg in panel_canary restart_settle chooser35; do
      echo "== live: $leg"
      env_var="OSK_$(echo "$leg" | tr 'a-z' 'A-Z')_LIVE=1"
      # Each leg's own convention: the canary gate is OSK_PANEL_CANARY_LIVE.
      case "$leg" in
        panel_canary) env_var="OSK_PANEL_CANARY_LIVE=1" ;;
        restart_settle) env_var="OSK_RESTART_SETTLE_LIVE=1" ;;
        chooser35) env_var="OSK_CHOOSER35_LIVE=1" ;;
      esac
      if ssh "$LAB" "cd ~/omarchy-osk && env $env_var python3 tools/integration/$leg.py" \
          >"/tmp/wall-$leg.log" 2>&1; then
        row "$leg" PASS "$(grep -cE '^ok ' "/tmp/wall-$leg.log") assertions"
      else
        row "$leg" FAIL "see /tmp/wall-$leg.log"
      fi
    done
  fi
else
  row "live-legs" SKIP "lab unreachable — host layers above still stand"
fi

echo
echo "==================== regression wall ===================="
printf '%s\n' "${ROWS[@]}"
echo "========================================================="
exit "$wall"
