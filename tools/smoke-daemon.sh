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
# short-circuit it instead of compiling again. The reply alone cannot prove
# that (both paths answer "configured"), so the caller counts the daemon's
# "keymap compiled" log lines afterwards.
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
]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
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
sock.close()
PY

# The daemon sits on the group the last `group` command selected, and that
# state is visible as the virtual keyboard device's active_layout_index — the
# one layout fact about the helper that can be read back without a client.
# Retry briefly: the modifiers event crosses the compositor asynchronously.
# The name match is deliberately the protocol prefix, not the process name:
# Hyprland names virtual keyboards hl-virtual-keyboard[-<binary>] depending on
# misc:name_vk_after_proc, and the nested session has no other virtual
# keyboard for the prefix to collide with.
group_of() {
  hyprctl devices -j | jq -r '
    [.keyboards[] | select(.name | test("hl-virtual-keyboard"))][0].active_layout_index' 2>/dev/null
}
wait_for_group() {
  local wanted="$1"
  for _ in $(seq 1 40); do
    [[ "$(group_of)" == "$wanted" ]] && return 0
    sleep 0.05
  done
  echo "device group never became $wanted (saw: $(group_of))" >&2
  return 1
}
wait_for_group 1
echo "device group follows 'group 1'"

# A client that dies mid-chord must not take the helper with it, and the keys
# it left pressed are its connection's problem: the helper releases them and
# zeroes the modifier mask on disconnect. Survival is what is asserted here —
# the release itself has no client-observable trace — so the disconnect must
# be real: the makefile holds the socket open, and closing only the socket
# would never deliver the EOF the daemon's read loop waits for.
python3 - "$socket" <<'PY'
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.write("down LCTL\n")
f.flush()
reply = f.readline().strip()
if reply != "ok":
    raise SystemExit(f"'down LCTL': expected 'ok', got {reply!r}")
f.close()
s.close()
PY

python3 - "$socket" <<'PY'
import socket
import sys
import time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.write("hello 2\n")
f.flush()
reply = f.readline().strip()
if reply != "hello 2":
    raise SystemExit(f"helper did not survive a client dying mid-chord: hello -> {reply!r}")
f.write("tap AD01\n")
f.flush()
reply = f.readline().strip()
if reply != "ok":
    raise SystemExit(f"tap after disconnect: expected 'ok', got {reply!r}")
print("disconnect mid-chord -> helper survives, fresh client works")
f.close()
s.close()
PY

# Back to the first layout, and the device must follow.
python3 - "$socket" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.write("group 0\n")
f.flush()
reply = f.readline().strip()
if reply != "ok":
    raise SystemExit(f"'group 0': expected 'ok', got {reply!r}")
f.close()
s.close()
PY
wait_for_group 0
echo "device group follows 'group 0'"

# Two keymaps total — the default compiled at startup and the configured one.
# A third line means the byte-identical configure recompiled, which is the
# churn-storm shape in miniature.
compiles=$(grep -c "keymap compiled for" "$log")
if [[ "$compiles" != "2" ]]; then
  echo "expected 2 keymap compiles (default + configured), saw $compiles" >&2
  exit 1
fi

hyprctl devices -j | jq -e '
  .keyboards[]
  | select(.name | test("hl-virtual-keyboard"))
  | .layout == "us,ua"
' >/dev/null

echo "nested helper smoke test passed"
