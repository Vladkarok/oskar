#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
daemon="$root/daemon/target/release/omarchy-osk-daemon"
socket="$XDG_RUNTIME_DIR/omarchy-osk/control.sock"

"$daemon" >"$XDG_RUNTIME_DIR/omarchy-osk-smoke.log" 2>&1 &
daemon_pid=$!
cleanup() {
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  [[ -S "$socket" ]] && break
  sleep 0.05
done
[[ -S "$socket" ]] || { echo "helper socket did not appear" >&2; exit 1; }

python3 - "$socket" <<'PY'
import socket
import sys

commands = ["hello 1", "layout us,ua", "group 1", "tap AD01", "group 0"]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
stream = sock.makefile("rw")

for command in commands:
    stream.write(command + "\n")
    stream.flush()
    reply = stream.readline().strip()
    expected = "ready 1" if command == "hello 1" else "ok"
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
