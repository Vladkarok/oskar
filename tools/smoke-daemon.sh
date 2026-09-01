#!/usr/bin/env bash
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
[[ -S "$socket" ]] || { echo "helper socket did not appear" >&2; exit 1; }

python3 - "$socket" <<'PY'
import socket
import sys
import time

commands = [
    "hello 2",
    "configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t1",
    "tap AD01",
    "group 0",
]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for attempt in range(50):
    try:
        sock.connect(sys.argv[1])
        break
    except ConnectionRefusedError:
        if attempt == 49:
            raise
        time.sleep(0.05)
stream = sock.makefile("rw")

for command in commands:
    stream.write(command + "\n")
    stream.flush()
    reply = stream.readline().strip()
    if command == "hello 2":
        expected = "hello 2"
    elif command.startswith("configure"):
        expected = "configured"
    else:
        expected = "ok"
    if reply != expected:
        raise SystemExit(f"{command!r}: expected {expected!r}, got {reply!r}")
    print(f"{command} -> {reply}")
PY

hyprctl devices -j | jq -e '
  .keyboards[]
  | select(.name | test("omarchy-osk"))
  | .layout == "us,ua"
' >/dev/null

echo "nested helper smoke test passed"
