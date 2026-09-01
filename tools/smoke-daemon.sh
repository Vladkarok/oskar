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
if [[ ! -S "$socket" ]]; then
  echo "helper socket did not appear" >&2
  echo "--- helper log ---" >&2
  cat "$log" >&2 || true
  exit 1
fi

# The daemon sits on the group its last `group`/`configure` command selected,
# and that state is visible as the virtual keyboard device's
# active_layout_index — the one layout fact about the helper that can be read
# back without a client. Retry briefly: the modifiers event crosses the
# compositor asynchronously. The name match is deliberately the protocol
# prefix, not the process name: Hyprland names virtual keyboards
# hl-virtual-keyboard[-<binary>] depending on misc:name_vk_after_proc, and the
# nested session has no other virtual keyboard for the prefix to collide with.
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

# The second configure is byte-identical to the first: the daemon must
# short-circuit it instead of compiling again. The reply alone cannot prove
# that (both paths answer "configured"), so the caller counts the daemon's
# "keymap compiled" log lines at the end.

python3 - "$socket" <<'PY'
import socket
import sys
import time

configure = "configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t1"
# Every typing operation sits between two group assertions, so what is
# asserted is the group the tap actually ran under, not a final state.
commands = [
    "hello 2",
    configure,        # starts the helper on group 1, the second layout (ua)
    "tap AD01",
    "group 0",
    "tap AD01",       # under group 0 (us)
    configure,        # identical payload: must be a short-circuit, not a recompile
    "tap AD01",       # back under group 1
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

wait_for_group 1
echo "device group follows configure/group 1"

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

# Multi-client ownership, asserted at the protocol level. The compositor
# exposes no per-device modifier state a client could read back
# (active_layout_index follows the client-asserted mask, not the keys held),
# but the daemon's own rules make ownership visible: a connection that never
# claimed a code cannot release it, and a tap may not lift someone else's
# hold. LCTL carries no lock actions, so taps stay inert.
python3 - "$socket" <<'PY'
import socket
import sys

def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sys.argv[1])
    return s, s.makefile("rw")

a, fa = connect()
b, fb = connect()

def ask(f, command, expected):
    f.write(command + "\n")
    f.flush()
    reply = f.readline().strip()
    if reply != expected:
        raise SystemExit(f"{command!r}: expected {expected!r}, got {reply!r}")

ask(fa, "down LCTL", "ok")
ask(fa, "down LCTL", "ok")           # duplicate: one claim, not two
ask(fb, "up LCTL", "err not holding")  # B cannot end A's hold
ask(fa, "tap LCTL", "err key held")    # a tap may not lift A's hold either
ask(fb, "down LCTL", "ok")             # B claims it too: one press, two holders
ask(fa, "up LCTL", "ok")               # A lets go: B's hold keeps the key down
ask(fa, "tap LCTL", "err key held")
ask(fb, "up LCTL", "ok")               # last holder: the release goes out
ask(fa, "tap LCTL", "ok")              # nothing held any more: a tap works
print("multi-client holds: foreign releases rejected, shared hold survives a holder, owner's release lands")
fa.close(); a.close()
fb.close(); b.close()
PY

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
