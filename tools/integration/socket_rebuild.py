#!/usr/bin/env python3
"""The helper dies under a live panel: the panel must re-share the keymap.

A restarted helper counts install generations from one again, so the
generation the panel last shared with the compositor can repeat. The panel
therefore zeroes its shared generation whenever it loses the helper — on a
clean disconnect and on the watchdog's rebuild of a socket that still
reports itself connected (SocketWatch.rebuildResets) — or the
once-per-generation share guard would skip the re-share and the compositor
would keep compiling the dead helper's keymap.

The leg, on the lab session with the real Panel.qml hosted under a private
runtime (the restart_settle technique):
  1. the panel shares its keymap: `sharedGen` >= 1;
  2. SIGKILL the helper: the panel notices the loss and `sharedGen` drops
     to 0 (whichever path noticed — a disconnect or the watchdog rebuild);
  3. a new helper on the same socket: the panel reconnects and shares
     again (`sharedGen` >= 1), and the compositor's kb_file names the
     published keymap under the leg's runtime.

Run inside the VM's lab session (docs/vm-handoff.md):
  cd ~/oskar && OSK_SOCKET_REBUILD_LIVE=1 \\
      python3 tools/integration/socket_rebuild.py
"""
import json
import os
import signal
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import Failure, wait_for
from restart_settle import (PRIVATE, STATE_FILE, LabSession, LegDaemon, Panel,
                            PrivateRuntime, hyprctl, kb_file_option,
                            read_state, restore_compositor_kb_file,
                            restore_service, sane_restore_target)

LAB_HOSTNAME = "testprod"


def guard():
    if os.environ.get("OSK_SOCKET_REBUILD_LIVE", "") != "1":
        raise Failure("this leg stops the oskar service and drives the live "
                      "session — run it only in the lab, with "
                      "OSK_SOCKET_REBUILD_LIVE=1 (docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"not the lab ({os.uname().nodename!r}); refusing")


def shared_gen(panel):
    return panel.state().get("sharedGen", -1)


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    state_backup = read_state()
    kb_file_was = kb_file_option()
    daemon = None
    panel = None
    with LabSession(), PrivateRuntime() as rt:
        try:
            daemon = LegDaemon(repo, "before", rt.env)
            daemon.wait_socket()
            panel = Panel(repo, rt.env, tag="rebuild")
            wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                     120, "the hosted panel to start")
            panel.command("open", "opened")
            wait_for(lambda: panel.state()["ready"] is True, 90,
                     "the keyboard to become ready")
            wait_for(lambda: shared_gen(panel) >= 1, 30,
                     "the panel to share its keymap with the compositor")
            print(f"ok    shared before the loss: sharedGen {shared_gen(panel)}")

            daemon.process.send_signal(signal.SIGKILL)
            daemon.process.wait(timeout=5)
            wait_for(lambda: shared_gen(panel) == 0, 45,
                     "the panel to zero its shared generation after the "
                     "helper died")
            print("ok    helper SIGKILLed: the panel zeroed its shared "
                  "generation")
            daemon.close()

            daemon = LegDaemon(repo, "after", rt.env)
            daemon.wait_socket()
            wait_for(lambda: panel.state()["ready"] is True, 90,
                     "the panel to reconnect to the new helper")
            wait_for(lambda: shared_gen(panel) >= 1, 45,
                     "the panel to re-share the new helper's keymap")
            kb_file = json.loads(hyprctl("getoption", "input:kb_file", "-j")) \
                .get("str", "")
            if not kb_file.startswith(PRIVATE):
                raise Failure(f"the compositor's kb_file is {kb_file!r}, not "
                              f"the new helper's published keymap under "
                              f"{PRIVATE}")
            print(f"ok    new helper: re-shared (sharedGen "
                  f"{shared_gen(panel)}), kb_file {kb_file}")
            panel.command("close", "closed")
            print("ok    SOCKET REBUILD LEG GREEN: the lost helper zeroed the "
                  "share, and the new one was shared again")
        finally:
            if panel:
                panel.close()
            if daemon:
                daemon.close()
            if state_backup is not None:
                with open(STATE_FILE, "w", encoding="utf-8") as handle:
                    json.dump(state_backup, handle, indent=2)
            restore_compositor_kb_file(sane_restore_target(kb_file_was),
                                       "the socket-rebuild leg's teardown")
    restore_service()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  socket-rebuild leg: {failure}")
        sys.exit(1)
