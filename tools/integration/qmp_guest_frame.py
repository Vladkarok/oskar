#!/usr/bin/env python3
"""Ticket 48's guest half of the QMP canary legs (run BY the host driver).

The canary's QMP legs are two-sided by physics: input comes from the
lab HOST (virsh QMP absolute pointer), while the hosted panel, its
daemon and the observation live in the GUEST. This frame is the guest
side: it boots the same CanaryDaemon + hosted Panel as the standing
canary, opens the keyboard, and then serves a small command file so
the host driver can force the overlay state (the mask-red lever),
bounce the daemon (the pre-47 wedge lever), and read the daemon pid
for strace. State goes to one append-only log; commands come from one
file whose mtime the frame polls.

Launched by the host driver as:

  ssh omarchy-vm 'cd <tree> && XDG_RUNTIME_DIR=/run/user/1000 \
      WAYLAND_DISPLAY=wayland-1 \
      HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1) \
      python3 tools/integration/qmp_guest_frame.py <tree>'

Never run it by hand against a session you care about: it stops the
packaged OSK service for its whole lifetime (LiveSession semantics,
restored in its finally).
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hold_column import Failure, LiveSession, wait_for  # noqa: E402
from panel_canary import (  # noqa: E402
    CanaryDaemon, Panel, own_socket_or_die, service_active,
)

CMD_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""),
                        "osk-qmp-cmd")
LOG_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""),
                        "osk-qmp-log")
SOCKET = os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""),
                      "oskar/control.sock")


def note(line):
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(f"{time.time():.3f} {line}\n")


def wait_cmd(deadline_s=600):
    """Return the next command word, or None when the deadline hits.

    The driver writes "word seq" with a fresh seq every time, so the
    raw file text changing IS the signal — no mtime tricks.
    """
    last = None
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        try:
            with open(CMD_PATH, encoding="utf-8") as handle:
                text = handle.read().strip()
        except OSError:
            time.sleep(0.1)
            continue
        if text and text != last:
            last = text
            return text.rsplit(" ", 1)[0]
        time.sleep(0.1)
    return None


def main():
    repo = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
    for path in (LOG_PATH, CMD_PATH):
        if os.path.exists(path):
            os.unlink(path)
    note(f"frame-start tree={repo}")

    with LiveSession() as lab:
        for attempt in range(4):
            subprocess.run(
                ["systemctl", "--user", "stop", "oskar.service"],
                capture_output=True, timeout=15)
            try:
                wait_for(lambda: not service_active(), 5,
                         "the packaged service to stop")
                break
            except Failure:
                if attempt == 3:
                    raise
                continue
        if os.path.exists(SOCKET):
            os.unlink(SOCKET)

        daemon = CanaryDaemon(repo)
        panel = None
        try:
            daemon.wait_socket()
            own_socket_or_die()
            note(f"daemon-pid {daemon.process.pid}")
            panel = Panel(repo)
            wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                     120, "the hosted panel to start")
            panel.command("open", "opened")
            wait_for(lambda: panel.state()["opened"] is True, 20,
                     "the panel window to open")
            wait_for(lambda: panel.state()["ready"] is True, 90,
                     "the keyboard to become ready to type")
            note("frame-ready")

            while True:
                command = wait_cmd()
                if command is None:
                    note("frame-timeout")
                    break
                note(f"cmd {command}")
                if command == "forceoverlay":
                    panel.command("forceoverlay", "overlay-forced")
                    note("overlay-forced")
                elif command == "clearoverlay":
                    panel.command("clearoverlay", "overlay-cleared")
                    note("overlay-cleared")
                elif command == "bounce":
                    daemon.close()
                    if os.path.exists(SOCKET):
                        os.unlink(SOCKET)
                    daemon = CanaryDaemon(repo)
                    daemon.wait_socket()
                    note(f"daemon-pid {daemon.process.pid}")
                    note("bounced")
                elif command == "state":
                    note("state " + " ".join(panel.marker_lines()[-2:]))
                elif command == "quit":
                    note("frame-done")
                    break
                else:
                    note(f"unknown-command {command}")
        finally:
            if panel is not None:
                try:
                    panel.command("close", "closed")
                except Exception:
                    pass
                panel.close()
            daemon.close()
    note("frame-exit")


if __name__ == "__main__":
    if not os.environ.get("XDG_RUNTIME_DIR", "").startswith("/run/user/"):
        raise SystemExit("run me inside the lab guest session (see header)")
    main()
