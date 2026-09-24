#!/usr/bin/env python3
"""The host half of ticket 42's emoji-focus leg (emoji_focus.py is the guest).

Starts the guest half over ssh, then for each phase it announces sends that
phase's physical keys through QMP (`sendkey`, the lab keyboard belongs to
the host's QEMU monitor) and touches the go-file. The guest asserts; this
side only types and prints the guest's report.

  OSK_EMOJI_FOCUS_LIVE=1 python3 tools/integration/emoji_focus_host.py
"""
import os
import subprocess
import sys
import time

GUEST = "omarchy-vm"
DOMAIN = "oskar"
PHASE_DIR = "/run/user/1000/osk-emoji-leg"
PHASES = [("1-latin", ["o", "s", "k"]), ("2-cyrillic", ["a"]),
          ("3-backspace", ["backspace"]), ("4-escape", ["esc"]),
          ("5-app", ["h", "i", "ret"])]
GUEST_COMMAND = (
    "export XDG_RUNTIME_DIR=/run/user/1000; "
    "sig=$(for s in $(command ls -t /run/user/1000/hypr); do "
    "timeout 2 hyprctl -i $s version >/dev/null 2>&1 && { echo $s; break; }; "
    "done); "
    "export HYPRLAND_INSTANCE_SIGNATURE=$sig WAYLAND_DISPLAY=wayland-1; "
    "cd ${OSK_CANARY_TREE:-~/oskar} && OSK_EMOJI_FOCUS_LIVE=1 "
    "python3 tools/integration/emoji_focus.py")


def ssh(command):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", GUEST, command],
                          capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=30)


def sendkey(key):
    subprocess.run(["virsh", "-c", "qemu:///session", "qemu-monitor-command",
                    "--hmp", DOMAIN, f"sendkey {key}"], capture_output=True,
                   stdin=subprocess.DEVNULL, timeout=30, check=True)


def main():
    if os.environ.get("OSK_EMOJI_FOCUS_LIVE") != "1":
        print("FAIL  set OSK_EMOJI_FOCUS_LIVE=1 to drive the lab")
        return 1
    guest = subprocess.Popen(["ssh", "-o", "BatchMode=yes", GUEST,
                              GUEST_COMMAND], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True)
    for name, keys in PHASES:
        deadline = time.monotonic() + 300
        while guest.poll() is None and time.monotonic() < deadline:
            if ssh(f"test -e {PHASE_DIR}/phase-{name}").returncode == 0:
                break
            time.sleep(1)
        else:
            break
        time.sleep(1)
        for key in keys:
            sendkey(key)
            time.sleep(0.3)
        time.sleep(1)
        ssh(f"rm -f {PHASE_DIR}/phase-{name}; touch {PHASE_DIR}/go-{name}")
    output, _ = guest.communicate(timeout=300)
    print(output.rstrip())
    return guest.returncode


if __name__ == "__main__":
    sys.exit(main())
