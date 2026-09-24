#!/usr/bin/env python3
"""The summon-output leg: the panel's first mapped frame is on the pointer's
output. The real Panel.qml is hosted in the lab session, a second (headless)
output is added, and the panel is summoned with the pointer reported on
it. Every `visible` flip of every panel window is logged with the output
it maps on at that instant; a map on any other output fails the leg. The
pointer then "returns" to the first output and the summon is repeated, so
a placement left over from the previous summon (the reset on close) is
covered too. The headless output is removed afterwards.

The pointer is not moved: the lab has no pointer synthesis, and this
Hyprland's Lua dispatch table has no cursor move the leg could call. The
panel asks `hyprctl cursorpos -j` for the pointer, so the hosted shell
gets a `hyprctl` wrapper first on its PATH that answers exactly that
query from the leg's pointer file and hands everything else to the real
binary. The panel's own output resolution (screenAt over the compositor's
screen list) and the compositor's mapping of the layer surface on the
chosen output run unchanged.

Run inside the VM's lab session:
  cd ~/oskar && OSK_SUMMON_LIVE=1 python3 tools/integration/summon_output.py
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import ANSI, Failure, hyprctl  # noqa: E402

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
MARK = "[summonleg] "

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

    function log(line) { console.log("[summonleg] " + line) }

    // Every window the panel declares: an object with a scene
    // (contentItem) and an output (screen). Each gets a watcher that logs
    // the output it is on at the instant its visibility flips.
    property var watched: []
    function watchWindows() {
        var kids = panel.data !== undefined ? panel.data : panel.children
        var count = 0
        for (var i = 0; kids && i < kids.length; i++) {
            var obj = kids[i]
            if (!obj || obj.contentItem === undefined || obj.screen === undefined) continue
            var watcher = Qt.createQmlObject(
                'import QtQuick; Connections { property int index: 0; property var win: null; '
                + 'function onVisibleChanged() { root.log("visible " + index + " " + win.visible + " " + (win.screen ? win.screen.name : "none")) } '
                + 'function onScreenChanged() { root.log("screen " + index + " " + (win.screen ? win.screen.name : "none") + " visible=" + win.visible) } }',
                root, "watcher")
            watcher.index = count
            watcher.win = obj
            watcher.target = obj
            count += 1
        }
        log("watching " + count)
    }

    FileView {
        id: commandFile
        path: "__RUNTIME__/osk-summon-cmd"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var command = String(text() || "").trim()
            if (command === "") return
            var parts = command.split(" ")
            switch (parts[0]) {
            case "watch": watchWindows(); break
            case "open": panel.opened = true; log("opened"); break
            case "close": panel.close(); log("closed"); break
            }
        }
    }

    Component.onCompleted: log("alive")
}
"""


def guard():
    if os.environ.get("OSK_SUMMON_LIVE", "") != "1":
        raise Failure("this leg drives the lab session: run it in omarchy-vm "
                      "with OSK_SUMMON_LIVE=1 (docs/vm-handoff.md)")
    if not os.path.isdir("/usr/share/omarchy/shell"):
        raise Failure("OSK_SUMMON_LIVE=1 is set, but this host is not the lab")


def monitors():
    return {m["name"]: m for m in json.loads(hyprctl("monitors", "-j"))}


WRAPPER = """\
#!/bin/sh
# The leg's stand-in pointer: only `cursorpos -j` is answered here.
if [ "$1" = "cursorpos" ] && [ "$2" = "-j" ]; then
    cat "__POINTER__"
    exit 0
fi
exec "__REAL__" "$@"
"""


class Host:
    """The hosted panel, driven through its command file."""

    def __init__(self, repo):
        self.seq = 0
        self.cfg = os.path.join(RUNTIME, "osk-summon-shell")
        os.makedirs(self.cfg, exist_ok=True)
        # Panel.qml imports qs.Commons and qs.Ui: the `qs` prefix resolves
        # beside the -p shell.qml, so the shell's own directories are
        # symlinked in, as the canary does.
        for name in ("Commons", "Ui"):
            target = os.path.join(self.cfg, name)
            if not os.path.exists(target):
                os.symlink(f"/usr/share/omarchy/shell/{name}", target)
        self.command_path = os.path.join(RUNTIME, "osk-summon-cmd")
        if os.path.exists(self.command_path):
            os.unlink(self.command_path)
        shell = os.path.join(self.cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML.replace("__TREE__", repo)
                         .replace("__RUNTIME__", RUNTIME))
        real = subprocess.run(["sh", "-c", "command -v hyprctl"],
                              capture_output=True, text=True).stdout.strip()
        if not real:
            raise Failure("no hyprctl on PATH")
        self.pointer_path = os.path.join(self.cfg, "pointer.json")
        self.point(0, 0)
        wrapper_dir = os.path.join(self.cfg, "bin")
        os.makedirs(wrapper_dir, exist_ok=True)
        wrapper = os.path.join(wrapper_dir, "hyprctl")
        with open(wrapper, "w", encoding="utf-8") as handle:
            handle.write(WRAPPER.replace("__POINTER__", self.pointer_path)
                         .replace("__REAL__", real))
        os.chmod(wrapper, 0o755)
        env = dict(os.environ)
        env["PATH"] = wrapper_dir + os.pathsep + env.get("PATH", "")
        self.log = open(os.path.join(RUNTIME, "osk-summon-shell.log"), "w+")
        self.process = subprocess.Popen(["quickshell", "-p", shell],
                                        stdout=self.log,
                                        stderr=subprocess.STDOUT, env=env)

    def point(self, x, y):
        with open(self.pointer_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"x": x, "y": y}))

    def lines(self):
        self.log.flush()
        self.log.seek(0)
        out = []
        for line in self.log.read().splitlines():
            clean = ANSI.sub("", line)
            at = clean.find(MARK)
            if at != -1:
                out.append(clean[at + len(MARK):])
        return out

    def command(self, line, expect, timeout=20):
        self.seq += 1
        start = len(self.lines())
        with open(self.command_path, "w", encoding="utf-8") as handle:
            handle.write(f"{line} {self.seq}\n")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            new = self.lines()[start:]
            for out in new:
                if out.startswith(expect):
                    return start, out
            time.sleep(0.05)
        raise Failure(f"panel never answered {line!r} with {expect!r}; "
                      f"log tail: {self.lines()[-12:]}")

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


def settle(host, start, timeout=2.0):
    """The visibility lines that arrived after `start`, once they stop."""
    deadline = time.monotonic() + timeout
    seen = None
    while time.monotonic() < deadline:
        now = host.lines()[start:]
        if seen is not None and len(now) == len(seen):
            break
        seen = now
        time.sleep(0.25)
    return [l for l in (seen or []) if l.startswith("visible ")
            or l.startswith("screen ")]


def summon_on(host, name, center, expected_windows):
    host.point(center[0], center[1])
    start, _ = host.command("open", "opened")
    events = settle(host, start)
    maps = [e for e in events if e.startswith("visible ") and " true " in e]
    if len(maps) < expected_windows:
        raise Failure(f"summon on {name}: expected {expected_windows} window "
                      f"maps, saw {maps} (events {events})")
    wrong = [m for m in maps if not m.endswith(" " + name)]
    if wrong:
        raise Failure(f"summon on {name}: a window mapped on another output "
                      f"first — {wrong} (events {events})")
    print(f"ok    summon on {name}: {len(maps)} windows mapped on it and "
          f"nowhere else first — {maps}")
    start, _ = host.command("close", "closed")
    events = settle(host, start)
    unmaps = [e for e in events if e.startswith("visible ") and " false " in e]
    if len(unmaps) < expected_windows:
        raise Failure(f"close on {name}: expected {expected_windows} unmaps, "
                      f"saw {events}")
    print(f"ok    close on {name}: {len(unmaps)} windows unmapped")


def main():
    guard()
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    before = monitors()
    if not before:
        raise Failure("no monitors")
    first = sorted(before.values(), key=lambda m: (m["x"], m["y"]))[0]
    out = hyprctl("output", "create", "headless").strip()
    if out != "ok":
        raise Failure(f"hyprctl output create headless: {out!r}")
    added = None
    host = None
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not added:
            new = [n for n in monitors() if n not in before]
            added = new[0] if new else None
            time.sleep(0.2)
        if not added:
            raise Failure("the headless output never appeared")
        mons = monitors()
        second = mons[added]
        print(f"ok    outputs: {first['name']} at {first['x']},{first['y']} "
              f"and {added} at {second['x']},{second['y']}")

        def center(m):
            return (m["x"] + m["width"] // 2, m["y"] + m["height"] // 2)

        host = Host(repo)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and "alive" not in host.lines():
            time.sleep(0.2)
        if "alive" not in host.lines():
            raise Failure(f"the hosted panel never started; log tail: "
                          f"{host.lines()[-8:]}")
        print("ok    hosted panel started")
        _, line = host.command("watch", "watching")
        windows = int(line.split()[1])
        if windows < 1:
            raise Failure("no panel windows found to watch")
        print(f"ok    watching {windows} panel windows")
        # The second output first: the panel has never mapped, so this is
        # the cold summon; then the first output, which is the reset-on-close
        # case (a placement left over from the previous summon).
        summon_on(host, added, center(second), windows)
        summon_on(host, first["name"], center(first), windows)
        summon_on(host, added, center(second), windows)
        print("ok    summon-output leg passed")
    finally:
        if host:
            host.close()
        if added:
            hyprctl("output", "remove", added)


if __name__ == "__main__":
    try:
        main()
    except Failure as failure:
        print(f"FAIL  {failure}")
        sys.exit(1)
