#!/usr/bin/env python3
"""Ticket 37's VM leg: the hold column's input path, end to end.

Two venues, one finding between them:

* Nested mode (under tools/nested-session.sh) is the preferred polygon —
  and it CANNOT host the panel, for a reason worth recording: a nested
  Hyprland is a Wayland client of its parent, so its seat carries only
  the parent-forwarded `wl_keyboard` and the helper's own virtual
  keyboard. LayoutDevices.isSafe refuses both (not udev-identified, and
  deliberately not the helper's own device), the panel never finds a
  reading device, sends no configure, and stays gated — the safety
  contract working as designed. Discovered live while building this leg.

* Live mode (OSK_HOLD_LEG_LIVE=1, in the VM's disposable lab session per
  docs/vm-handoff.md) is where the proof runs: the packaged service is
  stopped, a private daemon owns the same socket path, and the real
  product Keyboard.qml is hosted by a minimal Quickshell shell whose only
  other content is a command file — because the lab guest has no pointer
  synthesis tool, the leg drives the very functions the cap delegate's
  onPressed/onReleased and the menu entry's onClicked call
  (beginCapHold / endCapHold / pickHoldEntry), with the real delegate
  items found by walking the scene. That is the FileView debug-hook
  technique that drove tickets 28/34's panel evidence.

Assertions are on BYTES: a focused foot running `cat` into a file must
read exactly the level-3 character the menu offered (and nothing from
the hold itself), and the daemon's own caps reply independently names
that character as the installed keymap's level 3 of the held position.
"""

import json
import os
import re
import socket
import subprocess
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
NESTED = os.environ.get("OSK_NESTED_SESSION", "") == "1"
CONFIG = os.environ.get("OSK_NEST_CONFIG", "")
LIVE = os.environ.get("OSK_HOLD_LEG_LIVE", "") == "1"


class Failure(Exception):
    pass


def guard():
    # Mirrors smoke-daemon.sh's accidental-launch guard: never against a
    # working compositor — except the VM lab's own session, which is the
    # documented disposable environment (docs/vm-handoff.md).
    if LIVE:
        if not os.path.isdir("/usr/share/omarchy/shell"):
            raise Failure("live mode belongs to the omarchy-vm lab guest")
        return
    if not NESTED or not RUNTIME.startswith("/tmp/osk-nest.") \
            or not os.path.isfile(CONFIG):
        raise Failure(
            "Run this leg in omarchy-vm via "
            "tools/nested-session.sh python3 tools/integration/hold_column.py "
            "(or OSK_HOLD_LEG_LIVE=1 for the lab session)"
        )


def hyprctl(*args):
    return subprocess.run(
        ["hyprctl", *args], capture_output=True, text=True
    ).stdout


class LiveSession:
    """Owns the lab session's OSK service socket for the leg's daemon.

    The packaged service and this leg's daemon cannot share one socket
    path, so the service is stopped for the leg and started again after —
    the live panel then reconnects to it exactly as it would after any
    service restart.
    """

    def __init__(self):
        if not LIVE:
            self.active = False
            return
        self.active = True
        self.group_was = {}

    def __enter__(self):
        if self.active:
            subprocess.run(
                ["systemctl", "--user", "stop", "oskar.service"],
                capture_output=True, timeout=15, check=True,
            )
            # Remember the seat's per-keyboard groups so the leg can put
            # the lab back where it found it.
            try:
                keyboards = json.loads(hyprctl("devices", "-j"))["keyboards"]
            except (json.JSONDecodeError, KeyError):
                keyboards = []
            for keyboard in keyboards:
                name = keyboard.get("name", "")
                if name:
                    self.group_was[name] = keyboard.get(
                        "active_layout_index", 0)
        return self

    def __exit__(self, *exc):
        if not self.active:
            return False
        for name, group in self.group_was.items():
            hyprctl("switchxkblayout", name, str(group))
        subprocess.run(
            ["systemctl", "--user", "start", "oskar.service"],
            capture_output=True, timeout=15,
        )
        return False


def wait_for(predicate, timeout, note):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    raise Failure(f"timed out waiting for {note}")


class Daemon:
    """The private-runtime helper: started here, used by the hosted panel."""

    def __init__(self, repo):
        self.socket_path = os.path.join(RUNTIME, "oskar/control.sock")
        self.log = open(os.path.join(RUNTIME, "osk-hold-leg-daemon.log"), "w+")
        self.process = subprocess.Popen(
            [os.path.join(repo, "daemon/target/release/oskar-daemon")],
            stdout=self.log, stderr=subprocess.STDOUT,
        )

    def wait_socket(self):
        wait_for(lambda: os.path.exists(self.socket_path), 10,
                 "the helper socket to appear")

    def caps(self, group, positions):
        """The installed keymap's own answer for one group's positions."""
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(self.socket_path)
        client.sendall(f"hello 6\n".encode())
        self._read_reply(client, "hello")
        client.sendall(f"caps {group} {' '.join(positions)}\n".encode())
        reply = self._read_reply(client, "caps")
        client.close()
        return parse_caps(reply, positions)

    @staticmethod
    def _read_reply(client, want):
        buffer = b""
        while b"\n" not in buffer:
            chunk = client.recv(4096)
            if not chunk:
                raise Failure(f"helper closed the socket waiting for {want}")
            buffer += chunk
        line = buffer.split(b"\n")[0].decode()
        if not line.startswith(want):
            raise Failure(f"helper answered {line!r}, wanted {want}")
        return line

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


def parse_caps(reply, positions):
    """One record per position: a list of level texts ('' for none)."""
    parts = reply.split("\t")
    records = parts[3:]
    by_position = {}
    for record in "\t".join(records).split("\x1e"):
        if not record:
            continue
        fields = record.split("\x1f")
        levels = []
        for field in fields[1:]:
            if field.startswith("t"):
                levels.append(field[1:])
            else:
                levels.append("")
        by_position[fields[0]] = levels
    return {p: by_position.get(p, []) for p in positions}


SHELL_QML = """\
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import qs.Commons
import "file:__TREE__" as Plugin

PanelWindow {
    id: window
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "io.github.vladkarok.oskar.holdLeg"
    WlrLayershell.layer: WlrLayer.Overlay
    // The panel never takes keyboard focus (Panel.qml's own rule): the
    // focused client keeps receiving what the helper types.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "#262626"
    implicitHeight: testKb.implicitHeight + testKb.capRowHeight

    Plugin.Keyboard {
        id: testKb
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            topMargin: testKb.capRowHeight / 2
        }
        theme: Plugin.Theme {}
        availableWidth: window.width
    }

    property var commandSeq: 0

    function collectCaps(item, out) {
        for (var i = 0; i < item.children.length; i++) {
            var child = item.children[i]
            if (child && child.capData !== undefined) out.push(child)
            collectCaps(child, out)
        }
    }

    function delegateFor(xkb) {
        var caps = []
        collectCaps(testKb, caps)
        for (var i = 0; i < caps.length; i++)
            if (caps[i].capData.xkb === xkb) return caps[i]
        return null
    }

    function log(line) { console.log("[holdleg] " + line) }

    function state() {
        var texts = []
        for (var i = 0; i < testKb.holdMenuEntries.length; i++)
            texts.push(testKb.holdMenuEntries[i].text)
        log("state " + JSON.stringify({
            ready: testKb.inputReady, layout: testKb.activeLayoutCode,
            group: testKb.groupCursor, menu: testKb.holdMenuOpen,
            entries: texts, codes: testKb.layoutCodes,
            env: Quickshell.env("XDG_RUNTIME_DIR"),
            sock: testKb.daemonSocket ? testKb.daemonSocket.connected : "none",
            lifecycle: testKb.lifecycleKind,
            inventory: testKb.startupInventorySeen,
            facts: testKb.capsFacts !== null,
            factsFailed: testKb.capsFactsFailed,
            incompatible: testKb.serviceIncompatible
        }))
    }

    // The command file: the FileView debug-hook technique from tickets
    // 28/34 — the lab has no pointer synthesis, so the leg drives the
    // same functions the MouseArea handlers call.
    FileView {
        id: commandFile
        path: "__RUNTIME__/osk-hold-leg-cmd"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var command = String(text() || "").trim()
            if (command === "") return
            var parts = command.split(" ")
            switch (parts[0]) {
            case "state":
                state()
                break
            case "switch":
                // The panel's own language step: the seat follows and the
                // keyboard re-reads the compositor, exactly as a chip
                // click would.
                testKb.stepLayout()
                log("switched")
                break
            case "group": {
                // The panel's own absolute-group switch primitive — the
                // same one the language chooser issues (ticket 35).
                testKb.switchToGroup(parseInt(parts[1]))
                log("grouped")
                break
            }
            case "hold": {
                var item = delegateFor(parts[1])
                if (!item) { log("no-cap " + parts[1]); break }
                if (!testKb.capDefersHold(item.capData)) {
                    log("no-defer " + parts[1])
                    break
                }
                testKb.beginCapHold(item.capData, item)
                log("held " + parts[1])
                break
            }
            case "release": {
                var rel = delegateFor(parts[1])
                if (!rel) { log("no-cap " + parts[1]); break }
                log("released " + parts[1] + " consumed="
                    + (testKb.endCapHold(rel) ? "true" : "false"))
                break
            }
            case "cancel": {
                var can = delegateFor(parts[1])
                if (!can) { log("no-cap " + parts[1]); break }
                log("canceled " + parts[1] + " consumed="
                    + (testKb.cancelCapHold(can) ? "true" : "false"))
                break
            }
            case "pick": {
                var index = parseInt(parts[1])
                if (!(index >= 0 && index < testKb.holdMenuEntries.length)) {
                    log("no-entry " + parts[1])
                    break
                }
                // Capture before the pick: pickHoldEntry closes the menu
                // and the entries array with it.
                var picked = testKb.holdMenuEntries[index].text
                testKb.pickHoldEntry(testKb.holdMenuEntries[index])
                log("picked " + picked)
                break
            }
            case "enter": {
                // A real Return through the panel's own keysym path: foot
                // hands `cat` its line only on RTRN (canonical mode), so
                // this is the flush every typed assertion needs — the
                // harness suite's own idiom.
                testKb.triggerSpecial({ key: "Return" }, false)
                testKb.releaseKey()
                log("entered")
                break
            }
            case "dismiss":
                testKb.closeHoldMenu()
                log("dismissed")
                break
            }
        }
        onLoadFailed: function (error) {
            // The command file not existing yet is the starting state.
        }
    }

    Component.onCompleted: log("alive")
}
"""


class Panel:
    """The hosted keyboard, driven through its command file."""

    def __init__(self, repo):
        self.seq = 0
        self.cfg = os.path.join(RUNTIME, "osk-hold-shell")
        os.makedirs(self.cfg, exist_ok=True)
        commons = os.path.join(self.cfg, "Commons")
        if not os.path.exists(commons):
            os.symlink("/usr/share/omarchy/shell/Commons", commons)
        self.command_path = os.path.join(RUNTIME, "osk-hold-leg-cmd")
        if os.path.exists(self.command_path):
            os.unlink(self.command_path)
        shell = os.path.join(self.cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML
                         .replace("__TREE__", repo)
                         .replace("__RUNTIME__", RUNTIME))
        self.log = open(os.path.join(RUNTIME, "osk-hold-leg-shell.log"), "w+")
        self.process = subprocess.Popen(
            ["quickshell", "-p", shell],
            stdout=self.log, stderr=subprocess.STDOUT,
        )

    def _drain(self):
        # quickshell's log lines carry ANSI color codes and a level prefix
        # (DEBUG qml:) in front of console.log's text; keep only the
        # [holdleg] markers' own text.
        self.log.flush()
        self.log.seek(0)
        out = []
        for line in self.log.read().splitlines():
            clean = ANSI.sub("", line)
            marker = clean.find("[holdleg] ")
            if marker != -1:
                out.append(clean[marker + len("[holdleg] "):])
        return out

    def command(self, line, expect, timeout=30):
        """Write one command; return the first matching [holdleg] line.

        A sequence number rides along so two identical commands in a row
        still change the file the FileView watches.
        """
        self.seq += 1
        with open(self.command_path, "w", encoding="utf-8") as handle:
            handle.write(f"{line} {self.seq}\n")
        start = len(self._drain())
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            lines = self._drain()
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
        self.path = os.path.join(RUNTIME, "osk-hold-leg-typed.txt")
        if os.path.exists(self.path):
            os.unlink(self.path)
        self.errors = open(os.path.join(RUNTIME, "osk-hold-leg-foot.log"), "w+")
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
            out = hyprctl("activewindow", "-j")
            try:
                window = json.loads(out)
            except json.JSONDecodeError:
                window = {}
            if window.get("class") == "foot":
                # The keyboard enter is what makes the first keystroke
                # land; the harness's own generous settle.
                time.sleep(2)
                return True
            if self.process.poll() is not None:
                if not last:
                    return False
                self.errors.flush()
                self.errors.seek(0)
                raise Failure(
                    "foot exited instead of taking focus: "
                    + (self.errors.read().strip() or "it printed nothing")
                )
            time.sleep(0.1)
        raise Failure("no focused foot window to type into")

    def text(self):
        try:
            with open(self.path, encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except FileNotFoundError:
            return ""

    def expect_text(self, wanted, note):
        for _ in range(60):
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


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    with LiveSession() as lab:
        daemon = Daemon(repo)
        panel = None
        target = None
        try:
            daemon.wait_socket()
            panel = Panel(repo)
            started = time.monotonic()
            wait_for(lambda: any(l == "alive" for l in panel._drain()), 120,
                     "the hosted keyboard to start")
            print(f"ok    hosted keyboard started "
                  f"({time.monotonic() - started:.1f}s after launch)")

            target = TypingTarget()

            def ready():
                return panel.state()["ready"] is True
            wait_for(ready, 90, "the keyboard to become ready to type")

            # Ukrainian's punctuation columns carry levels 3-4 — the
            # columns this ticket is about. Move the seat with the
            # panel's own absolute-group primitive and wait for the
            # keyboard to follow and be ready in it.
            state = panel.state()
            codes = state["codes"]
            if "ua" not in codes:
                raise Failure(f"the seat's layout list {codes} carries no "
                              "ua group; the lab guest's configuration "
                              "changed under this leg")
            ua_group = codes.index("ua")
            panel.command(f"group {ua_group}", "grouped")
            wait_for(lambda: panel.state()["layout"] == "ua", 30,
                     "the seat and the keyboard to reach the ua group")
            wait_for(ready, 30,
                     "the keyboard to be ready again after the switch")

            # The independent keymap truth: the helper's own caps reply
            # must name the level-3 character the menu is about to offer,
            # from the keymap it installed.
            facts = daemon.caps(ua_group, ["AE03", "AD01"])
            level3 = facts["AE03"][2] if len(facts["AE03"]) > 2 else ""
            level1 = facts["AE03"][0] if facts["AE03"] else ""
            if not level3:
                raise Failure(f"the installed ua keymap has no AE03 "
                              f"level 3; caps reply: {facts}")
            print(f"ok    installed keymap: AE03 = {facts['AE03']!r}, "
                  f"AD01 = {facts['AD01']!r}")

            # 1. The hold itself types nothing and starts no repeat.
            panel.command("hold AE03", "held AE03")
            time.sleep(1.0)
            state = panel.state()
            if not state["menu"]:
                raise Failure(f"the hold menu did not open: {state}")
            if state["entries"][0] != level3:
                raise Failure(f"the menu offers {state['entries']!r}, "
                              f"expected {level3!r} first")
            target.expect_text("", "the hold itself must type nothing")

            # 2. Picking the level-3 entry types exactly that character
            #    (the enter tap is foot's canonical-mode flush, not
            #    content — it is how the harness reads what arrived).
            panel.command("pick 0", f"picked {level3}")
            panel.command("enter", "entered")
            target.expect_text(level3 + "\n", "the level-3 pick")

            # 3. A quick click on the same cap types its level 1, exactly
            #    once, through the release-typing path.
            panel.command("hold AE03", "held AE03")
            panel.command("release AE03", "released AE03 consumed=true")
            panel.command("enter", "entered")
            target.expect_text(level3 + "\n" + level1 + "\n", "the quick click")

            # 4. A lost grab with a pending hold types NOTHING
            #    (onCanceled's arm), strictly better than a stray
            #    character.
            panel.command("hold AE03", "held AE03")
            panel.command("cancel AE03", "canceled AE03 consumed=true")
            time.sleep(0.8)
            state = panel.state()
            if state["menu"]:
                raise Failure(
                    f"a canceled hold left its menu open: {state}")
            panel.command("enter", "entered")
            # The flush newline itself is the only new content: the
            # canceled hold typed nothing.
            target.expect_text(level3 + "\n" + level1 + "\n\n",
                               "a canceled hold must type nothing")

            # 5. Dismiss without a pick types nothing.
            panel.command("hold AE03", "held AE03")
            time.sleep(0.8)
            state = panel.state()
            if not state["menu"]:
                raise Failure("the menu did not open for the dismiss leg")
            panel.command("dismiss", "dismissed")
            panel.command("enter", "entered")
            # Again the flush newline alone: the dismiss typed nothing.
            target.expect_text(level3 + "\n" + level1 + "\n\n\n",
                               "an outside dismiss must type nothing")

            # 6. A letter cap does not defer in this lab's live facts
            #    (the two-level case is pinned at the pure seam; here the
            #    decision runs against the live facts whatever they carry
            #    — this lab's letter records resolve without extra levels
            #    or miss entirely, and either way the answer is no
            #    column, no defer, press-types as today).
            panel.command("hold AD01", "no-defer AD01")

            print("ok    hold column input path: hold typed nothing, "
                  f"level-3 pick typed {level3!r}, quick click typed "
                  f"{level1!r}, cancel and dismiss typed nothing, "
                  "two-level letters do not defer")
            return 0
        finally:
            if target:
                target.close()
            if panel:
                panel.close()
            daemon.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  hold column leg: {failure}")
        sys.exit(1)
