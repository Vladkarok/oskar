#!/usr/bin/env python3
"""The panel's click targets never collide: a lab leg over the real layout.

No host suite loads Panel.qml, so a layout mistake — a control anchored
under another — is invisible to every offscreen check; the emoji search's
clear chip once sat under the tone button for days. This leg hosts the real
panel in the lab session and audits every visible, enabled MouseArea in
each of its windows, in several states:

  keyboard      the docked keyboard, open
  emoji-query   the emoji page with a query typed (the clear chip shows)
  settings      the settings popover open

(Popups — the skin-tone picker — overlap what they cover by design and are
not audited; neither is a full-width backdrop such as the settings
layer's click-outside dismiss area.)

Two shapes are defects:
  - PARTIAL overlap: two click targets intersect and neither contains the
    other (a pointer on the seam hits whichever is on top by accident);
  - FOREIGN containment: a target lies wholly inside another it is not
    nested in by design — it is not a descendant of that target's parent
    (the field-under-button shape). Designed layering, like a chip drawn
    inside its own field, nests inside the field's subtree and passes.

Run inside the VM's lab session (docs/vm-handoff.md):
  cd ~/oskar && OSK_LAYOUT_LIVE=1 python3 tools/integration/layout_leg.py
"""
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import Failure, wait_for  # noqa: E402
from restart_settle import (LabSession, LegDaemon,  # noqa: E402
                            PrivateRuntime)

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
LEG_DIR = os.path.join(RUNTIME, "osk-layout-leg")
LAB_HOSTNAME = "testprod"
MARK = "[layoutleg] "

SHELL_QML = """\
import Quickshell
import Quickshell.Io
import QtQuick
import "file:__TREE__" as Plugin

Item {
    id: root

    Plugin.Panel { id: panel }

    function log(line) { console.log("__MARK__" + line) }

    function kids(obj) {
        var out = []
        if (obj.contentItem !== undefined && obj.contentItem)
            out.push(obj.contentItem)
        var list = obj.data !== undefined ? obj.data : obj.children
        if (list)
            for (var i = 0; i < list.length; i++) out.push(list[i])
        return out
    }

    // The first object in the tree that answers `test`.
    function find(obj, test, depth) {
        if (!obj || depth > 60) return null
        if (test(obj)) return obj
        var list = kids(obj)
        for (var i = 0; i < list.length; i++) {
            var hit = find(list[i], test, depth + 1)
            if (hit) return hit
        }
        return null
    }

    function page() {
        return find(panel, function (o) {
            return o.query !== undefined && o.searchArmed !== undefined
        }, 0)
    }

    function settingsLayer() {
        return find(panel, function (o) {
            return typeof o.openPopover === "function"
        }, 0)
    }

    function isMouseArea(o) {
        return o.pressAndHoldInterval !== undefined
            && o.containsMouse !== undefined && o.mapToItem !== undefined
    }

    function label(o) {
        var p = o.parent
        var text = ""
        if (p) {
            var list = p.children || []
            for (var i = 0; i < list.length && text === ""; i++)
                if (list[i].text !== undefined && String(list[i].text) !== "")
                    text = String(list[i].text)
        }
        return String(p) + (text !== "" ? " '" + text.slice(0, 24) + "'" : "")
    }

    function sceneRoot(o) {
        var r = o
        while (r.parent) r = r.parent
        return r
    }

    function descends(o, ancestor) {
        for (var p = o; p; p = p.parent) if (p === ancestor) return true
        return false
    }

    function collect(obj, depth, seen, out) {
        if (!obj || depth > 60 || seen.indexOf(obj) !== -1) return
        seen.push(obj)
        if (isMouseArea(obj) && obj.visible && obj.enabled
                && obj.width > 0 && obj.height > 0) {
            var at = obj.mapToItem(null, 0, 0)
            var top = sceneRoot(obj)
            // A full-width area is a backdrop (the click-outside dismiss
            // spans the window above the keyboard): under everything by
            // design, not a collision. No control spans a whole window.
            var backdrop = at.x <= 0 && obj.width >= top.width - 1
            if (!backdrop)
                out.push({ obj: obj, root: top, x: at.x, y: at.y,
                           w: obj.width, h: obj.height })
        }
        var list = kids(obj)
        for (var i = 0; i < list.length; i++)
            collect(list[i], depth + 1, seen, out)
    }

    function inside(a, b) {
        return a.x >= b.x && a.y >= b.y
            && a.x + a.w <= b.x + b.w && a.y + a.h <= b.y + b.h
    }

    function audit(name) {
        var areas = []
        collect(panel, 0, [], areas)
        var defects = []
        for (var i = 0; i < areas.length; i++) {
            for (var j = i + 1; j < areas.length; j++) {
                var a = areas[i], b = areas[j]
                if (a.root !== b.root) continue
                var ix = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)
                var iy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y)
                if (ix <= 0 || iy <= 0) continue
                var aInB = inside(a, b), bInA = inside(b, a)
                var shape = ""
                if (!aInB && !bInA) shape = "partial"
                else if (aInB && !descends(a.obj, b.obj.parent)) shape = "foreign"
                else if (bInA && !descends(b.obj, a.obj.parent)) shape = "foreign"
                if (shape !== "")
                    defects.push(shape + ": " + label(a.obj) + " ["
                        + [a.x, a.y, a.w, a.h].map(Math.round) + "] vs "
                        + label(b.obj) + " ["
                        + [b.x, b.y, b.w, b.h].map(Math.round) + "]")
            }
        }
        log("audit " + JSON.stringify({ state: name, areas: areas.length,
                                        defects: defects }))
    }

    FileView {
        path: "__DIR__/cmd"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var parts = String(text() || "").trim().split(" ")
            switch (parts[0]) {
            case "open":
                panel.opened = true
                log("opened")
                break
            case "emoji":
                if (!panel.emojiOpen) panel.toggleEmojiPage()
                page().query = "layout"
                log("emoji " + panel.emojiOpen)
                break
            case "tone":
                page().tonePickerOpen = true
                log("tone " + page().tonePickerOpen)
                break
            case "emoji-close":
                page().tonePickerOpen = false
                page().query = ""
                if (panel.emojiOpen) panel.toggleEmojiPage()
                log("emoji-closed")
                break
            case "settings":
                settingsLayer().openPopover()
                log("settings " + settingsLayer().popoverVisible)
                break
            case "audit":
                audit(parts[1])
                break
            case "close":
                panel.close()
                log("closed")
                break
            }
        }
        onLoadFailed: function (error) {}
    }

    Component.onCompleted: log("alive")
}
"""


class Panel:
    def __init__(self, repo, env):
        self.seq = 0
        cfg = os.path.join(LEG_DIR, "shell")
        os.makedirs(cfg, exist_ok=True)
        for name in ("Commons", "Ui"):
            target = os.path.join(cfg, name)
            if not os.path.exists(target):
                os.symlink(f"/usr/share/omarchy/shell/{name}", target)
        self.command_path = os.path.join(LEG_DIR, "cmd")
        shell = os.path.join(cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML.replace("__TREE__", repo)
                         .replace("__DIR__", LEG_DIR)
                         .replace("__MARK__", MARK))
        self.log = open(os.path.join(LEG_DIR, "shell.log"), "w+")
        self.process = subprocess.Popen(["quickshell", "-p", shell],
                                        stdout=self.log,
                                        stderr=subprocess.STDOUT, env=env)

    def marker_lines(self):
        self.log.flush()
        self.log.seek(0)
        return [line[line.find(MARK) + len(MARK):]
                for line in self.log.read().splitlines() if MARK in line]

    def command(self, line, expect, timeout=30):
        self.seq += 1
        start = len(self.marker_lines())
        with open(self.command_path, "w", encoding="utf-8") as handle:
            handle.write(f"{line} {self.seq}\n")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for out in self.marker_lines()[start:]:
                if out.startswith(expect):
                    return out
            time.sleep(0.1)
        raise Failure(f"panel never answered {line!r} with {expect!r}")

    def audit(self, state):
        time.sleep(1.0)  # let the layout settle after the state change
        line = self.command(f"audit {state}", "audit ")
        return json.loads(line[len("audit "):])

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


def guard():
    if os.environ.get("OSK_LAYOUT_LIVE", "") != "1":
        raise Failure("this leg stops the oskar service and drives the live "
                      "session — run it only in the lab, with "
                      "OSK_LAYOUT_LIVE=1 (docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"not the lab ({os.uname().nodename!r}); refusing")


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    shutil.rmtree(LEG_DIR, ignore_errors=True)
    os.makedirs(LEG_DIR, exist_ok=True)
    daemon = panel = None
    failures = []
    with LabSession(), PrivateRuntime() as rt:
        try:
            daemon = LegDaemon(repo, "layout", rt.env)
            daemon.wait_socket()
            panel = Panel(repo, rt.env)
            wait_for(lambda: "alive" in panel.marker_lines(), 120,
                     "the hosted panel to start")
            panel.command("open", "opened")
            steps = [("keyboard", None), ("emoji-query", "emoji"),
                     ("settings", "emoji-close")]
            for state, action in steps:
                if action:
                    panel.command(action, action.split("-")[0])
                if state == "settings":
                    panel.command("settings", "settings")
                report = panel.audit(state)
                if report["defects"]:
                    failures.append(report)
                    print(f"FAIL  {state}: {len(report['defects'])} "
                          f"collision(s) among {report['areas']} targets")
                    for defect in report["defects"]:
                        print(f"        {defect}")
                else:
                    print(f"ok    {state}: {report['areas']} click targets, "
                          "none collide")
            panel.command("close", "closed")
        finally:
            if panel:
                panel.close()
            if daemon:
                daemon.close()
    if failures:
        raise Failure(f"{len(failures)} state(s) with colliding click targets")
    print("ok    LAYOUT LEG GREEN")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  layout leg: {failure}")
        sys.exit(1)
