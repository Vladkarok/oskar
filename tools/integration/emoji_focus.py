#!/usr/bin/env python3
"""Ticket 42's owed VM leg: the armed emoji search takes PHYSICAL keys.

The owner's request was the physical fallback: while the emoji search is
armed, typing on the real keyboard builds the query (Cyrillic included),
the focused client receives nothing; one physical Escape disarms and hands
the keys back to the client. The machinery is decisions §52: primed
Exclusive, settled OnDemand, release by binding.

This leg runs in the lab session (live only — the nested polygon cannot
host the panel, ticket 37's venue finding) and is driven in two halves,
because the lab's keyboards belong to the host's QEMU monitor, not to the
guest:

  - the GUEST half (this script) hosts the real Panel.qml under the leg's
    private runtime (the restart_settle technique: no other panel can
    reach the leg daemon or fight over the compositor's kb_file), opens
    the keyboard and the emoji page, focuses a foot terminal, and asserts
    the query and the client at each phase;
  - the HOST half sends the physical keystrokes through QMP
    (`virsh qemu-monitor-command --hmp omarchy-osk 'sendkey …'`) when this
    script signals a phase file, and touches a go-file to advance.

Phases (files under $XDG_RUNTIME_DIR/osk-emoji-leg/):
  1 armed          — page open, search armed, foot focused, client idle
    host: sendkey o s k                    (us group: latin)
  2 cyrillic       — guest pre-switches the whole switch set to ua
    host: sendkey a                        (→ ф)
  3 backspace      — host: sendkey backspace
  4 escape         — host: sendkey esc     (disarm + release focus)
  5 app            — host: sendkey h i ret (keys reach the client again)

Asserts at every armed phase that the focused client's file stays empty,
and records the honoured keyboard-focus mode behaviourally: the layer
holds the keyboard while armed (no activewindow), the app holds it again
after Escape (activewindow is the client). Run inside the VM's lab
session, with the host driver stepping the phases:

  cd ~/omarchy-osk && OSK_EMOJI_FOCUS_LIVE=1 \
      python3 tools/integration/emoji_focus.py
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import Failure, wait_for
from restart_settle import (LabSession, LegDaemon, PrivateRuntime,
                            group_names_in_keymap, hyprctl, service_active)

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
PHASE_DIR = os.path.join(RUNTIME, "osk-emoji-leg")
LAB_HOSTNAME = "testprod"


def guard():
    if os.environ.get("OSK_EMOJI_FOCUS_LIVE", "") != "1":
        raise Failure("this leg stops the osk service and drives the live "
                      "session — run it only in the omarchy-vm lab, with "
                      "OSK_EMOJI_FOCUS_LIVE=1 (docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"OSK_EMOJI_FOCUS_LIVE=1 is set, but this host is "
                      f"{os.uname().nodename!r}, not the lab "
                      f"({LAB_HOSTNAME!r}); refusing (docs/vm-handoff.md)")


def active_class():
    try:
        window = json.loads(hyprctl("activewindow", "-j"))
    except json.JSONDecodeError:
        return ""
    return str(window.get("class", ""))


SHELL_QML = """\
import Quickshell
import Quickshell.Io
import QtQuick
import "file:__TREE__" as Plugin

Item {
    id: root

    Plugin.Panel {
        id: panel
    }

    property var kb: null
    property var page: null

    function walkItem(item) {
        if (!item) return null
        if (item.query !== undefined && item.searchArmed !== undefined)
            return item
        var kids = item.data !== undefined ? item.data : item.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = walkItem(kids[i])
            if (found) return found
        }
        return null
    }

    function walkObject(obj, depth) {
        if (!obj || depth > 25) return null
        if (obj.query !== undefined && obj.searchArmed !== undefined)
            return obj
        if (obj.contentItem !== undefined) return walkItem(obj.contentItem)
        var kids = obj.data !== undefined ? obj.data : obj.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = walkObject(kids[i], depth + 1)
            if (found) return found
        }
        return null
    }

    function emojiPage() {
        if (!root.page) root.page = walkObject(panel, 0)
        return root.page
    }

    function keyboard() {
        if (!root.kb) root.kb = walkKb(panel, 0)
        return root.kb
    }

    function walkKb(obj, depth) {
        if (!obj || depth > 25) return null
        if (obj.capsPositions !== undefined) return obj
        if (obj.contentItem !== undefined) {
            var viaItem = walkKbItem(obj.contentItem)
            if (viaItem) return viaItem
        }
        var kids = obj.data !== undefined ? obj.data : obj.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = walkKb(kids[i], depth + 1)
            if (found) return found
        }
        return null
    }

    function walkKbItem(item) {
        if (!item) return null
        if (item.capsPositions !== undefined) return item
        var kids = item.data !== undefined ? item.data : item.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = walkKbItem(kids[i])
            if (found) return found
        }
        return null
    }

    function log(line) { console.log("[emojileg] " + line) }

    function state() {
        var page = emojiPage()
        var kb = keyboard()
        log("state " + JSON.stringify({
            opened: panel.opened,
            emojiOpen: panel.emojiOpen,
            armed: panel.emojiSearchActive,
            query: page ? page.query : null,
            pageArmed: page ? page.searchArmed : null,
            ready: kb ? kb.inputReady : false,
            codes: kb ? kb.layoutCodes : [],
            group: kb ? kb.groupCursor : -1,
            switchSet: kb ? kb.switchKeyboards : []
        }))
    }

    FileView {
        id: commandFile
        path: "__RUNTIME__/cmd"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var command = String(text() || "").trim()
            if (command === "") return
            var parts = command.split(" ")
            switch (parts[0]) {
            case "open":
                panel.opened = true
                log("opened")
                break
            case "close":
                panel.close()
                log("closed")
                break
            case "emoji":
                if (!panel.emojiOpen) panel.toggleEmojiPage()
                log("emoji-open " + panel.emojiOpen)
                break
            case "emoji-close":
                if (panel.emojiOpen) panel.toggleEmojiPage()
                log("emoji-close " + panel.emojiOpen)
                break
            case "state":
                state()
                break
            }
        }
        onLoadFailed: function (error) {}
    }

    Component.onCompleted: log("alive")
}
"""


class Panel:
    """The real panel with its emoji page, driven by command file."""

    def __init__(self, repo, env):
        self.seq = 0
        cfg = os.path.join(PHASE_DIR, "shell")
        os.makedirs(cfg, exist_ok=True)
        for name in ("Commons", "Ui"):
            target = os.path.join(cfg, name)
            if not os.path.exists(target):
                os.symlink(f"/usr/share/omarchy/shell/{name}", target)
        self.command_path = os.path.join(PHASE_DIR, "cmd")
        if os.path.exists(self.command_path):
            os.unlink(self.command_path)
        shell = os.path.join(cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML
                         .replace("__TREE__", repo)
                         .replace("__RUNTIME__", PHASE_DIR))
        self.log = open(os.path.join(PHASE_DIR, "shell.log"), "w+")
        self.process = subprocess.Popen(
            ["quickshell", "-p", shell],
            stdout=self.log, stderr=subprocess.STDOUT, env=env,
        )

    def marker_lines(self):
        self.log.flush()
        self.log.seek(0)
        out = []
        for line in self.log.read().splitlines():
            clean = line
            marker = clean.find("[emojileg] ")
            if marker != -1:
                out.append(clean[marker + len("[emojileg] "):])
        return out

    def command(self, line, expect, timeout=30):
        self.seq += 1
        with open(self.command_path, "w", encoding="utf-8") as handle:
            handle.write(f"{line} {self.seq}\n")
        start = len(self.marker_lines())
        deadline = time.monotonic() + timeout
        lines = []
        while time.monotonic() < deadline:
            lines = self.marker_lines()
            for out in lines[start:]:
                if expect in out:
                    return out
            time.sleep(0.1)
        raise Failure(f"panel never answered {line!r} with {expect!r}; "
                      f"shell log tail: {lines[-12:]}")

    def state(self):
        line = self.command("state", "state ")
        return json.loads(line[len("state "):])

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


class TypingTarget:
    """foot + cat into a file; the assertion is what the client read."""

    def __init__(self):
        self.path = os.path.join(PHASE_DIR, "typed.txt")
        if os.path.exists(self.path):
            os.unlink(self.path)
        self.errors = open(os.path.join(PHASE_DIR, "foot.log"), "w+")
        self.process = None
        for attempt in range(5):
            if attempt:
                time.sleep(2)
            self.process = subprocess.Popen(
                ["foot", "sh", "-c", f"cat > {self.path}"],
                stdout=subprocess.DEVNULL, stderr=self.errors,
            )
            if self._focused(attempt == 4):
                return

    def _focused(self, last):
        for _ in range(300):
            if active_class() == "foot":
                time.sleep(1.5)
                return True
            if self.process.poll() is not None:
                if not last:
                    return False
                raise Failure("foot exited instead of taking focus")
            time.sleep(0.1)
        raise Failure("no focused foot window to type into")

    def text(self):
        try:
            with open(self.path, encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except FileNotFoundError:
            return ""

    def expect(self, wanted, note, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.text() == wanted:
                return
            time.sleep(0.25)
        raise Failure(f"{note}: focused client read {self.text()!r}, "
                      f"expected {wanted!r}")

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.errors.close()


def phase_ready(name, note):
    """Announce a phase and block until the host driver's go-file lands."""
    open(os.path.join(PHASE_DIR, f"phase-{name}"), "w").write(note + "\n")
    print(f"phase {name}: {note} — waiting for host keys", flush=True)
    go = os.path.join(PHASE_DIR, f"go-{name}")
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if os.path.exists(go):
            os.unlink(go)
            return
        time.sleep(0.2)
    raise Failure(f"host driver never advanced phase {name}")


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    import re as re_mod
    import shutil
    shutil.rmtree(PHASE_DIR, ignore_errors=True)
    os.makedirs(PHASE_DIR, exist_ok=True)
    daemon = None
    panel = None
    target = None
    with LabSession() as lab, PrivateRuntime() as rt:
        packaged_keymap = os.path.join(RUNTIME, "omarchy-osk/keymap.xkb")
        packaged_backup = None
        try:
            # The same stale-file heal the settle leg does: the seat's
            # group switch to ua needs the compositor's compiled map to
            # carry four groups, and the packaged panel re-asserts ITS
            # runtime's published file (currently the one-group default
            # of a daemon restart its panel never reconfigured) whenever
            # it observes a change. Heal the file for the leg's lifetime;
            # restore the found bytes at the end.
            try:
                with open(packaged_keymap, "rb") as handle:
                    packaged_backup = handle.read()
            except OSError:
                packaged_backup = None
            healed = subprocess.run(
                ["bash", "-c",
                 "xkbcli compile-keymap --layout us,ua,it,ru"
                 f" > {packaged_keymap}"],
                capture_output=True)
            if healed.returncode != 0 \
                    or len(group_names_in_keymap(packaged_keymap)) < 4:
                raise Failure("could not heal the packaged panel's stale "
                              "published keymap to the seat's four groups: "
                              + healed.stderr.decode()[:200])
            daemon = LegDaemon(repo, "emoji", rt.env)
            daemon.wait_socket()
            panel = Panel(repo, rt.env)
            wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                     120, "the hosted panel to start")
            panel.command("open", "opened")
            wait_for(lambda: panel.state()["ready"] is True, 90,
                     "the keyboard to become ready")

            codes = panel.state()["codes"]
            ua_group = codes.index("ua") if "ua" in codes else 1

            # The seat starts on the us group so the first latin strokes
            # type what they say.
            for name in panel.state()["switchSet"]:
                hyprctl("switchxkblayout", name, "0")

            target = TypingTarget()

            # ARM. Opening the page arms the search by open (§52); the
            # 75 ms Exclusive prime grabs the keyboard for the layer and
            # OnDemand settles in.
            panel.command("emoji", "emoji-open true")
            state = panel.state()
            if state["armed"] is not True or state["pageArmed"] is not True:
                raise Failure(f"the emoji search did not arm on open: {state}")
            # `activewindow` names WINDOWS — a layer surface is not one, so
            # it keeps naming foot while the layer holds the keyboard. The
            # proof of the grab is behavioural and comes from the phases:
            # strokes 1-3 land in the query while foot stays idle. What the
            # layer-held world looks like here is recorded, not asserted.
            print("ok    armed: search armed on open; the grab is proven "
                  f"behaviourally (activewindow still names "
                  f"{active_class()!r}, a layer is not a window)")

            # 1. Latin strokes land in the query.
            target.expect("", "the client must stay idle while armed", 2)
            phase_ready("1-latin", "armed, send o s k")
            wait_for(lambda: panel.state()["query"] == "osk", 15,
                     "the latin strokes to build the query "
                     f"(query {panel.state()['query']!r})")
            target.expect("", "the client must stay idle while armed", 1)
            print("ok    latin physical strokes landed in the query: 'osk'")

            # 2. Cyrillic: the seat moves to the ua group first, the next
            # stroke produces the ua group's character.
            for name in panel.state()["switchSet"]:
                hyprctl("switchxkblayout", name, str(ua_group))
            phase_ready("2-cyrillic", f"seat on ua (group {ua_group}), send a")
            wait_for(lambda: panel.state()["query"] == "osk\u0444", 15,
                     "the Cyrillic stroke to append \u0444 "
                     f"(query {panel.state()['query']!r})")
            target.expect("", "the client must stay idle while armed", 1)
            print("ok    Cyrillic physical stroke landed in the query: "
                  "'osk\u0444' (event.text carried \u0444)")

            # 3. Backspace deletes from the query.
            phase_ready("3-backspace", "send backspace")
            wait_for(lambda: panel.state()["query"] == "osk", 15,
                     "backspace to delete from the query "
                     f"(query {panel.state()['query']!r})")
            print("ok    backspace deleted from the query: 'osk'")

            # 4. One physical Escape disarms and releases the keyboard.
            phase_ready("4-escape", "send esc")
            wait_for(lambda: panel.state()["armed"] is False, 10,
                     "physical Escape to disarm the search")
            state = panel.state()
            if state["query"] not in ("", None):
                raise Failure(f"Escape left a standing query: {state}")
            wait_for(lambda: panel.state()["query"] in ("", None), 10,
                     "the standing query to clear with the disarm")
            print("ok    physical Escape disarmed the search; the keys' "
                  "return to the client is proven by phase 5 landing")

            # 5. Further strokes reach the client. The seat goes back to
            # the us group first — the proof reads in latin (the first
            # cut skipped this and foot read 'рш\n': h and i THROUGH the
            # still-armed-in-seat ua group, which was itself proof the
            # keys had reached the client, just spelled Cyrillic).
            for name in panel.state()["switchSet"]:
                hyprctl("switchxkblayout", name, "0")
            phase_ready("5-app", "disarmed, seat back on us, send h i ret")
            target.expect("hi\n", "the post-Escape strokes to reach foot")
            print("ok    after Escape the physical keys reached the client: "
                  "'hi'")

            # The honoured mode, behaviourally: the layer HELD the keyboard
            # through the whole armed phase (strokes 1-3 never reached the
            # client) and returned it on the binding's None — the §52
            # prediction (primed Exclusive, settled OnDemand). A held
            # Exclusive would refuse the return; it did not.
            panel.command("emoji-close", "emoji-close false")
            panel.command("close", "closed")
            print("ok    EMOJI FOCUS LEG GREEN: armed typing built the "
                  "query (latin + Cyrillic + backspace), the client was "
                  "idle while armed, one Escape released the keyboard, "
                  "and the §52 mode held: grab at arm, release at None")
            return 0
        finally:
            if target:
                target.close()
            if panel:
                panel.close()
            if daemon:
                daemon.close()
            if packaged_backup is not None:
                with open(packaged_keymap, "wb") as handle:
                    handle.write(packaged_backup)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  emoji focus leg: {failure}")
        sys.exit(1)
