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

# The second configure is byte-identical to the first: the daemon must
# short-circuit it instead of compiling again, which is what keeps the
# xkbcomp count in nested-session.sh at its two-install floor.
configure = "configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t1"
commands = [
    "hello 2",
    configure,
    "tap AD01",       # types in group 1, the second layout (ua)
    "group 0",
    "tap AD01",       # types in group 0 (us)
    "group 1",
    configure,        # identical payload: must be a short-circuit, not a recompile
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
stream.close()

# A client that dies mid-chord must not take the helper with it, and the
# keys it left pressed are its connection's problem: the helper releases
# them and zeroes the modifier mask on disconnect. Nothing observable from
# here — the point is that a fresh client still gets a working helper.
chord = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
chord.connect(sys.argv[1])
chord_stream = chord.makefile("rw")
chord_stream.write("down LCTL\n")
chord_stream.flush()
reply = chord_stream.readline().strip()
if reply != "ok":
    raise SystemExit(f"'down LCTL': expected 'ok', got {reply!r}")
chord.close()

retry = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
retry.connect(sys.argv[1])
retry_stream = retry.makefile("rw")
retry_stream.write("hello 2\n")
retry_stream.flush()
reply = retry_stream.readline().strip()
if reply != "hello 2":
    raise SystemExit(f"helper did not survive a client dying mid-chord: hello -> {reply!r}")
retry_stream.write("tap AD01\n")
retry_stream.flush()
reply = retry_stream.readline().strip()
if reply != "ok":
    raise SystemExit(f"tap after disconnect: expected 'ok', got {reply!r}")
print("disconnect mid-chord -> helper survives, fresh client works")
retry_stream.close()
PY

hyprctl devices -j | jq -e '
  .keyboards[]
  | select(.name | test("omarchy-osk"))
  | .layout == "us,ua"
' >/dev/null

echo "nested helper smoke test passed"
