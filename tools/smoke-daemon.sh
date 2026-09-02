#!/usr/bin/env bash
#
# Entry point for the control-socket integration seam. This script owns the
# helper process and nothing else; the assertions live in
# tools/integration/suite.py and the plumbing they use in harness.py.
#
# Needs a compositor, so run it under the nested session:
#
#   tools/nested-session.sh tools/smoke-daemon.sh
#
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
daemon="$root/daemon/target/release/omarchy-osk-daemon"
socket="$XDG_RUNTIME_DIR/omarchy-osk/control.sock"
log="$XDG_RUNTIME_DIR/omarchy-osk-smoke.log"

"$daemon" >"$log" 2>&1 &
daemon_pid=$!
cleanup() {
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo "--- helper log ---" >&2; cat "$log" >&2' ERR

for _ in $(seq 1 50); do
  [[ -S "$socket" ]] && break
  sleep 0.05
done
if [[ ! -S "$socket" ]]; then
  echo "helper socket did not appear" >&2
  echo "--- helper log ---" >&2
  cat "$log" >&2 || true
  exit 1
fi

python3 "$root/tools/integration/suite.py" "$socket" "$log"

echo "nested helper integration suite passed"
