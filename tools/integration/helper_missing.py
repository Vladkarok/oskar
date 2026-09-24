#!/usr/bin/env python3
"""Ticket 65's lab leg: a panel with no helper installed says what to run.

A plugin placed on its own (`omarchy plugin add`) has no helper unit yet.
The panel must not offer Retry for a unit that does not exist; it must say
"not installed" and hand over the install command (the Copy chip). Once
the unit exists again, the hint returns to the ordinary stopped state.

In the lab (the unit file is hidden and restored; the service restarts on
exit):
  1. hide /usr/lib/systemd/user/oskar.service, daemon-reload;
  2. host the real panel with no helper: the hint is "missing", action
     "install", the command is an install command;
  3. restore the unit, daemon-reload: the hint turns to stopped/"retry".

  cd ~/oskar && OSK_HELPER_MISSING_LIVE=1 \\
      python3 tools/integration/helper_missing.py
"""
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import Failure, wait_for  # noqa: E402
from layout_leg import LEG_DIR, Panel  # noqa: E402
from restart_settle import LabSession  # noqa: E402

UNIT = "/usr/lib/systemd/user/oskar.service"
HIDDEN = "/var/tmp/oskar.service.hidden-by-leg"
LAB_HOSTNAME = "testprod"


def sh(*command):
    return subprocess.run(list(command), capture_output=True, text=True,
                          timeout=30)


def hint(panel):
    line = panel.command("hint", "hint ")
    return json.loads(line[len("hint "):])


def restore_unit():
    if os.path.exists(HIDDEN):
        sh("sudo", "-n", "mv", HIDDEN, UNIT)
    sh("systemctl", "--user", "daemon-reload")


def main():
    if os.environ.get("OSK_HELPER_MISSING_LIVE") != "1" \
            or os.uname().nodename != LAB_HOSTNAME:
        raise Failure("run only in the lab with OSK_HELPER_MISSING_LIVE=1")
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    shutil.rmtree(LEG_DIR, ignore_errors=True)
    os.makedirs(LEG_DIR, exist_ok=True)
    panel = None
    with LabSession():
        try:
            if sh("sudo", "-n", "mv", UNIT, HIDDEN).returncode != 0:
                raise Failure(f"cannot hide {UNIT} (passwordless sudo?)")
            sh("systemctl", "--user", "daemon-reload")
            state = sh("systemctl", "--user", "show", "oskar.service",
                       "-p", "LoadState", "--value").stdout.strip()
            if state != "not-found":
                raise Failure(f"the hidden unit still loads: {state}")

            panel = Panel(repo, dict(os.environ))
            wait_for(lambda: "alive" in panel.marker_lines(), 120,
                     "the hosted panel to start")
            panel.command("open", "opened")
            wait_for(lambda: hint(panel)["action"] == "install", 30,
                     "the missing-helper hint")
            seen = hint(panel)
            if seen["kind"] != "missing" or "not installed" not in seen["text"]:
                raise Failure(f"unexpected missing-helper hint: {seen}")
            if not (seen["command"] == "oskar setup"
                    or seen["command"].endswith("/install.sh")):
                raise Failure(f"the copied command is not an install "
                              f"command: {seen['command']!r}")
            print(f"ok    no unit: '{seen['text']}', Copy hands over "
                  f"{seen['command']!r}, no Retry")

            restore_unit()
            wait_for(lambda: hint(panel)["action"] == "retry", 20,
                     "the hint to return to stopped once the unit exists")
            print("ok    unit restored: the hint is back to "
                  f"'{hint(panel)['text']}' with Retry")
            panel.command("close", "closed")
            print("ok    HELPER MISSING LEG GREEN")
        finally:
            if panel:
                panel.close()
            restore_unit()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  helper-missing leg: {failure}")
        sys.exit(1)
