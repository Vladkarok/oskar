#!/usr/bin/env python3
"""Ticket 40's live-panel canary leg: the real plugin, in the lab, watched.

Extends the ticket-37 live-session harness (hold_column.py's LiveSession
venue and its FileView debug-hook technique) into the audit backlog's
canary: it boots the REAL panel — Panel.qml with the Keyboard inside it,
not a fixture — from the synced tree in the disposable lab session
(docs/vm-handoff.md), opens the keyboard, toggles the language group both
ways, and asserts:

1. zero `keycap fallback` lines in the shell journal for the leg's window
   — the leg's own shell process, and the session's journal too (the
   packaged panel reconnects to the leg's daemon while the service is
   stopped, so its drawing is on the surface the owner actually sees);
2. no NEW QML WARN/ERROR lines naming our files. The pre-existing
   `Cannot anchor to an item that isn't a parent or sibling` warnings
   from Panel.qml are grandfathered: counted at baseline, asserted not to
   grow, and every occurrence must still be exactly that message;
3. the canary itself: keycap facts in hand with AD01 present for BOTH
   groups, and the ua group's AD01 level 1 is й — in the session's stored
   facts and in the map actually drawn in each group (the ticket-39
   failure mode was a silently degraded caps request; this is the tripwire
   that fires the day it returns).

Everything is driven through the command file (the lab has no pointer
synthesis): open, close, group switches and state reads go through the
same properties and functions the omarchy shell's IPC uses — `opened`,
`close()`, `switchToGroup` — with the real items found by walking the
scene. Run inside the VM's lab session:

  cd ~/omarchy-osk && python3 tools/integration/panel_canary.py
"""

import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import ANSI, Daemon, Failure, LiveSession, wait_for

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")

# Our files, for the warning sweep: a warning naming our tree carries the
# tree's path (the leg loads file:~/omarchy-osk/…, the packaged panel
# /usr/share/omarchy-osk/…) and one of our basenames. Both halves are
# required, so the omarchy shell's own Commons/Ui files cannot collide.
OURS = re.compile(
    r"(Panel|Keyboard|BarWidget|Theme|HoverTooltip|KeyClickSound|CursorPolicy"
    r"|Settings\w*|EmojiPage|EmojiCatalog|LanguageControl|HoldColumn"
    r"|LayoutDevices|ModifierReducer|KeyboardSession|ClipboardPaste|Config)\.(qml|js)")
OURS_LINE = re.compile(r"omarchy-osk")
GRANDFATHERED = "Cannot anchor to an item that isn't a parent or sibling"
FALLBACK = "keycap fallback"


LAB_HOSTNAME = "testprod"


def guard():
    # Live-only, and PROVEN live: the nested polygon cannot host the panel
    # (ticket 37's venue finding), so this leg runs only in the lab session
    # itself — and a wrong machine must refuse before it can stop a service,
    # unlink a control socket or open a panel on someone's working
    # compositor. The old check (a directory the working HOST also has)
    # passed exactly there (ticket-40 review, block): two gates now, the
    # deliberate human opt-in the hold_column leg already uses, and the
    # lab's documented hostname (docs/vm-handoff.md) as the positive proof.
    if os.environ.get("OSK_PANEL_CANARY_LIVE", "") != "1":
        raise Failure("this leg stops the osk service and drives the live "
                      "session — run it only in the omarchy-vm lab, with "
                      "OSK_PANEL_CANARY_LIVE=1 (docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"OSK_PANEL_CANARY_LIVE=1 is set, but this host is "
                      f"{os.uname().nodename!r}, not the lab "
                      f"({LAB_HOSTNAME!r}); refusing (docs/vm-handoff.md)")


def journal_lines(since_epoch, until_epoch):
    out = subprocess.run(
        ["journalctl", "--user", "--no-pager", "--since",
         f"@{since_epoch:.0f}", "--until", f"@{until_epoch:.0f}"],
        capture_output=True, text=True,
    ).stdout
    return out.splitlines()


def kb_file_option():
    out = subprocess.run(
        ["hyprctl", "getoption", "input:kb_file", "-j"],
        capture_output=True, text=True,
    ).stdout
    try:
        return json.loads(out).get("str", "")
    except json.JSONDecodeError:
        return out.strip()


def group_names_in_keymap(path):
    """The group display names compiled into one xkb keymap file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return re.findall(r'name\[\d+\]="[^"]*"', handle.read())
    except OSError:
        return []


def wait_compositor_on_published(published_path, group_count):
    """The product's own §35 contract: after the share, the compositor's
    kb_file IS the published keymap, and that keymap carries every group
    the configure declared. The group toggle is meaningless until both."""
    wait_for(lambda: kb_file_option() == published_path, 45,
             f"the compositor's kb_file to reach {published_path} "
             f"(now {kb_file_option()!r})")
    wait_for(lambda: len(group_names_in_keymap(published_path)) >= group_count,
             15, f"{group_count} groups in the published keymap "
             f"(now {group_names_in_keymap(published_path)})")


def sweep(lines):
    """Count the canary's findings in one batch of log lines."""
    fallbacks = 0
    ours = []
    for line in lines:
        if FALLBACK in line:
            fallbacks += 1
        if (OURS.search(line) and OURS_LINE.search(line)
                and re.search(r"(WARN|ERROR|warning|error)", line,
                              re.IGNORECASE)):
            ours.append(line.strip())
    return {"fallbacks": fallbacks, "ours": ours}


def our_warnings(lines):
    """Our-file warning lines, with the grandfathered anchor split out."""
    grandfathered, new = [], []
    for line in lines:
        if not (OURS.search(line) and OURS_LINE.search(line)):
            continue
        if GRANDFATHERED in line and "Panel.qml" in line:
            grandfathered.append(line.strip())
        else:
            new.append(line.strip())
    return grandfathered, new


SHELL_QML = """\
import Quickshell
import Quickshell.Io
import QtQuick
import "file:__TREE__" as Plugin

Item {
    id: root

    // The real panel: the same component the omarchy shell loads from the
    // plugin manifest's panel entry point. It brings its own PanelWindows,
    // its config and state files, and the socket client.
    Plugin.Panel {
        id: panel
    }

    property var kb: null

    function walkItem(item) {
        if (item && item.capsPositions !== undefined) return item
        if (!item) return null
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
        if (obj.capsPositions !== undefined) return obj
        // A window exposes its scene through contentItem; an Item keeps
        // its declared children (windows included) in data.
        if (obj.contentItem !== undefined) return walkItem(obj.contentItem)
        var kids = obj.data !== undefined ? obj.data : obj.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = walkObject(kids[i], depth + 1)
            if (found) return found
        }
        return null
    }

    function findKeyboard() {
        // The panel's keyboard is under one of its PanelWindows: the walk
        // goes root -> data -> window -> contentItem -> scene, the same
        // scene walk the hold leg uses once it is under a window.
        return walkObject(panel, 0)
    }

    function keyboard() {
        if (!root.kb) root.kb = findKeyboard()
        return root.kb
    }

    function log(line) { console.log("[canary] " + line) }

    function state() {
        var kb = keyboard()
        if (!kb) { log("state no-keyboard"); return }
        var caps = kb.session ? kb.session.caps : null
        var byGroup = {}
        if (caps) {
            for (var g in caps.byGroup) {
                var record = caps.byGroup[g]
                byGroup[g] = record && record.AD01 && record.AD01.length > 0
                    && record.AD01[0].text !== undefined
                    ? String(record.AD01[0].text) : null
            }
        }
        var facts = kb.capsFacts
        log("state " + JSON.stringify({
            opened: panel.opened,
            ready: kb.inputReady,
            codes: kb.layoutCodes,
            group: kb.groupCursor,
            lifecycle: kb.lifecycleKind,
            facts: facts !== null,
            factsAD01: facts && facts.AD01 && facts.AD01.length > 0
                && facts.AD01[0].text !== undefined
                ? String(facts.AD01[0].text) : null,
            byGroupAD01: byGroup,
            switchSet: kb.switchKeyboards,
            anchor: kb.anchorKeyboardName
        }))
    }

    // The command file: the FileView debug-hook technique (tickets
    // 28/34/37) — the lab has no pointer synthesis, so the leg drives the
    // exact properties and functions the shell's own toggle and the
    // language chooser's rows drive.
    FileView {
        id: commandFile
        path: "__RUNTIME__/osk-canary-cmd"
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
                // The shell-IPC contract's own arm: the shell invokes
                // close() by name.
                panel.close()
                log("closed")
                break
            case "group": {
                var kb = keyboard()
                if (!kb) { log("no-keyboard"); break }
                kb.switchToGroup(parseInt(parts[1]))
                log("grouped")
                break
            }
            case "state":
                state()
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


class CanaryDaemon(Daemon):
    """hold_column's private-runtime helper, with the canary's log names."""

    def __init__(self, repo):
        self.socket_path = os.path.join(RUNTIME, "omarchy-osk/control.sock")
        self.log = open(os.path.join(RUNTIME, "osk-canary-daemon.log"), "w+")
        self.process = subprocess.Popen(
            [os.path.join(repo, "daemon/target/release/omarchy-osk-daemon")],
            stdout=self.log, stderr=subprocess.STDOUT,
        )


class Panel:
    """The real panel, hosted by a minimal shell and driven by command file."""

    def __init__(self, repo):
        self.seq = 0
        self.cfg = os.path.join(RUNTIME, "osk-canary-shell")
        os.makedirs(self.cfg, exist_ok=True)
        # Panel.qml and Keyboard.qml import qs.Commons and qs.Ui: the `qs`
        # prefix resolves beside the -p shell.qml, so the shell's own two
        # directories are symlinked in, exactly as the hold leg does.
        for name in ("Commons", "Ui"):
            target = os.path.join(self.cfg, name)
            if not os.path.exists(target):
                os.symlink(f"/usr/share/omarchy/shell/{name}", target)
        self.command_path = os.path.join(RUNTIME, "osk-canary-cmd")
        if os.path.exists(self.command_path):
            os.unlink(self.command_path)
        shell = os.path.join(self.cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML
                         .replace("__TREE__", repo)
                         .replace("__RUNTIME__", RUNTIME))
        self.log = open(os.path.join(RUNTIME, "osk-canary-shell.log"), "w+")
        self.process = subprocess.Popen(
            ["quickshell", "-p", shell],
            stdout=self.log, stderr=subprocess.STDOUT,
        )

    def raw_lines(self):
        self.log.flush()
        self.log.seek(0)
        return [ANSI.sub("", line) for line in self.log.read().splitlines()]

    def marker_lines(self):
        out = []
        for line in self.raw_lines():
            marker = line.find("[canary] ")
            if marker != -1:
                out.append(line[marker + len("[canary] "):])
        return out

    def command(self, line, expect, timeout=30):
        """Write one command; return the first matching [canary] line.

        A sequence number rides along so two identical commands in a row
        still change the file the FileView watches.
        """
        self.seq += 1
        with open(self.command_path, "w", encoding="utf-8") as handle:
            handle.write(f"{line} {self.seq}\n")
        start = len(self.marker_lines())
        deadline = time.monotonic() + timeout
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

    def warnings(self):
        """Our-file warnings from the leg's own shell log."""
        return sweep(self.raw_lines())["ours"]

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


def assert_no_growth(baseline, final, where):
    base_grand, base_new = baseline
    final_grand, final_new = final
    if final_new:
        for line in final_new[:8]:
            print("      new warning: " + line)
        raise Failure(f"{where}: {len(final_new)} QML warning(s) naming our "
                      "files are not the grandfathered anchor warning")
    if len(final_grand) != len(base_grand):
        for line in final_grand[len(base_grand):][:8]:
            print("      grown grandfathered: " + line)
        raise Failure(f"{where}: grandfathered Panel.qml anchor warnings "
                      f"grew {len(base_grand)} -> {len(final_grand)}")


def service_active():
    out = subprocess.run(
        ["systemctl", "--user", "is-active", "omarchy-osk.service"],
        capture_output=True, text=True,
    ).stdout.strip()
    return out == "active"


def band_statistics():
    """Ticket 47's visibility facts for the open, docked panel band.

    grim writes a binary PPM for the strip's geometry (no imaging
    dependency in the lab); the counts are the two numbers that separate
    a drawn keyboard from a flat slab: pixels in the cap-text luminance
    band, and distinct sampled colours (card background, cap fill, cap
    border, accent, text antialiasing). Measured live on this lab's
    1280x800 output: a drawn keyboard reads ~900-1300 text-band pixels
    (US and Cyrillic groups differ) over ~190 sampled colours. The very
    bottom screen rows carry a bright compositor edge that would pollute
    the count, so the capture stops five pixels short of it.
    """
    out = subprocess.run(
        ["hyprctl", "monitors", "-j"], capture_output=True, text=True).stdout
    try:
        monitor = json.loads(out)[0]
        width, height = monitor["width"], monitor["height"]
    except (ValueError, IndexError, KeyError):
        raise Failure(f"cannot read the lab output's geometry: {out!r}")
    path = os.path.join(RUNTIME, "osk-canary-band.ppm")
    geometry = f"0,{max(0, height - 305)} {width}x295"
    shot = subprocess.run(["grim", "-t", "ppm", "-g", geometry, path],
                          capture_output=True, text=True)
    if shot.returncode != 0:
        raise Failure(f"grim could not capture the panel band: "
                      f"{shot.stderr.strip()}")
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"P6"):
        raise Failure(f"unexpected band capture format: {data[:15]!r}")
    fields = []
    cursor = 2
    while len(fields) < 3:
        while cursor < len(data) and data[cursor:cursor + 1].isspace():
            cursor += 1
        if data[cursor:cursor + 1] == b"#":
            while cursor < len(data) and data[cursor:cursor + 1] != b"\n":
                cursor += 1
            continue
        start = cursor
        while cursor < len(data) and not data[cursor:cursor + 1].isspace():
            cursor += 1
        fields.append(int(data[start:cursor]))
    cursor += 1  # the single whitespace byte before the raster
    px_w, px_h, _ = fields
    raster = data[cursor:cursor + px_w * px_h * 3]
    textish = 0
    colors = set()
    for index in range(0, len(raster) - 2, 3):
        r, g, b = raster[index], raster[index + 1], raster[index + 2]
        lum = (r + g + b) / 3
        if 140 <= lum <= 230:
            textish += 1
        if index % 12 == 0:  # sampled: the spread, not the census
            colors.add((r // 8, g // 8, b // 8))
    return {"textish": textish, "colors": len(colors)}


def own_socket_or_die():
    """The leg daemon must own the socket it is about to be judged by.

    The lab's stop/start cycle can leave a stale socket file behind, which
    the helper reads as 'another daemon is running' — the leg would then
    quietly interview the packaged daemon instead of the synced tree's own
    helper (measured live). Prove ownership the direct way: say hello.
    """
    path = os.path.join(RUNTIME, "omarchy-osk/control.sock")
    wait_for(lambda: os.path.exists(path), 10, "the helper socket to appear")
    import socket as socket_mod

    def answers():
        try:
            client = socket_mod.socket(socket_mod.AF_UNIX, socket_mod.SOCK_STREAM)
            client.settimeout(3)
            client.connect(path)
            client.sendall(b"hello 5\n")
            reply = client.recv(200)
            client.close()
            return reply.startswith(b"hello")
        except OSError:
            return False
    wait_for(answers, 15, "the leg's own daemon to answer hello")


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    window_start = time.time()
    try:
        _run_leg(repo, window_start)
    finally:
        restore_service()


def _run_leg(repo, window_start):
    """The leg's window: every assertion runs inside this frame; the lab
    restore runs in the caller's finally, whatever the outcome."""
    with LiveSession() as lab:
        # The stop must be TRUE: a service that survived it would leave the
        # leg interviewing the packaged daemon (its keymap, its generation)
        # and the findings would be about the wrong tree. One observed
        # transient had a stop return 0 with the unit still running, so
        # verify and retry rather than trust the exit code.
        for attempt in range(4):
            subprocess.run(
                ["systemctl", "--user", "stop", "omarchy-osk.service"],
                capture_output=True, timeout=15,
            )
            try:
                wait_for(lambda: not service_active(), 5,
                         "the packaged service to stop")
                break
            except Failure:
                if attempt == 3:
                    state = subprocess.run(
                        ["systemctl", "--user", "show", "omarchy-osk.service",
                         "-p", "ActiveState,SubState,MainPID,NRestarts"],
                        capture_output=True, text=True).stdout
                    raise Failure("the packaged service would not stop: "
                                  + state.strip())
                continue
        # A stale socket file from the dying daemon reads as 'another
        # daemon owns the socket' to the fresh one. With the service
        # confirmed down, the path is ours to clear.
        socket_path = os.path.join(RUNTIME, "omarchy-osk/control.sock")
        if os.path.exists(socket_path):
            os.unlink(socket_path)
        daemon = CanaryDaemon(repo)
        panel = None
        try:
            own_socket_or_die()
            panel = Panel(repo)
            started = time.monotonic()
            wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                     120, "the hosted panel to start")
            print(f"ok    hosted panel started "
                  f"({time.monotonic() - started:.1f}s after launch)")

            # Open the keyboard the way the shell's toggle does and wait
            # for the full readiness chain: configure acked, caps facts
            # accepted, typing gate open.
            panel.command("open", "opened")
            wait_for(lambda: panel.state()["opened"] is True, 20,
                     "the panel window to open")
            wait_for(lambda: panel.state()["ready"] is True, 90,
                     "the keyboard to become ready to type")
            state = panel.state()
            if state["facts"] is not True:
                raise Failure(f"capsFacts never arrived: {state}")
            print(f"ok    keyboard open and ready, codes {state['codes']}, "
                  f"group {state['group']}, facts in hand")

            # ---- ticket 47's visibility tripwire (the H2 canary) ----
            # The install-from-zero stranger's panel read as
            # "near-invisible dark-on-dark", and no log line names a panel
            # that draws nothing at all (transparent tokens, a lost font).
            # This is the pixels' own assertion: the open band must carry
            # cap text and a colour spread, whatever the logs say. The
            # thresholds are calibrated live on this lab's 1280x800
            # output: a drawn keyboard measures ~900-1300 cap-text pixels
            # depending on group (US and Cyrillic differ), a flat slab
            # measures a handful; the typing gate itself is the ready
            # wait's business, not the pixels'.
            band = band_statistics()
            if band["textish"] < 600:
                raise Failure(f"the open panel band has only "
                              f"{band['textish']} cap-text pixels (a drawn "
                              f"keyboard measures 900+ on this output): "
                              f"the caps are blank or invisible — the "
                              f"ticket-47 symptom")
            if band["colors"] < 6:
                raise Failure(f"the open panel band carries only "
                              f"{band['colors']} sampled colours — a flat "
                              f"slab, not card/fill/border/accent")
            print(f"ok    panel band visible: {band['textish']} cap-text "
                  f"pixels, {band['colors']} sampled colours")

            # Baseline: the open's own warnings are pre-existing from here
            # on; everything after this line must be zero-growth.
            leg_base = our_warnings(panel.warnings())
            print(f"ok    baseline: {len(leg_base[0])} grandfathered "
                  f"Panel.qml anchor warnings, {len(leg_base[1])} new")

            codes = state["codes"]
            if "ua" not in codes:
                raise Failure(f"the seat's layout list {codes} carries no "
                              "ua group; the lab guest's configuration "
                              "changed under this leg")
            ua_group = codes.index("ua")

            # The product's §35 share: an accepted caps reply points the
            # compositor at the published keymap. The group toggle is only
            # meaningful once that share has landed — before it, the seat
            # may still compile a stale map whose group count cannot carry
            # the switch (measured live: `layout idx out of range`).
            published = os.path.join(RUNTIME, "omarchy-osk/keymap.xkb")
            wait_compositor_on_published(published, len(codes))
            print(f"ok    compositor kb_file on the published keymap "
                  f"({len(group_names_in_keymap(published))} groups)")

            # The session must hold facts for EVERY group of the install
            # (the helper answers them all at once) — AD01 present in each.
            by_group = state["byGroupAD01"]
            missing = [g for g in range(len(codes))
                       if by_group.get(str(g)) is None]
            if missing:
                raise Failure(f"session facts miss AD01 for groups {missing}: "
                              f"{by_group}")
            print(f"ok    session facts carry AD01 for all "
                  f"{len(codes)} groups: {by_group}")

            # Toggle to ua the way the chooser's row does — the absolute
            # group move — and read the drawn map. The move is issued
            # through a detached compositor call by the panel itself, so a
            # settle-and-retry is the honest driving rhythm.
            moved = False
            for attempt in range(5):
                panel.command(f"group {ua_group}", "grouped")
                try:
                    wait_for(lambda: (lambda s: s["codes"][s["group"]] == "ua")(
                        panel.state()), 12, f"the ua group (attempt {attempt})")
                    moved = True
                    break
                except Failure:
                    continue
            if not moved:
                raise Failure("the keyboard never reached the ua group "
                              "after 5 toggles")
            wait_for(lambda: panel.state()["ready"] is True, 30,
                     "the keyboard to be ready again after the switch")
            ua_state = panel.state()
            if ua_state["factsAD01"] != "\u0439":
                raise Failure(f"the ua group draws AD01 = "
                              f"{ua_state['factsAD01']!r}, expected "
                              f"\u0439 (the ticket-39 symptom)")
            print("ok    ua group drawn: AD01 = "
                  + ua_state["factsAD01"])

            # And back, with the same patience.
            for attempt in range(5):
                panel.command("group 0", "grouped")
                try:
                    wait_for(lambda: (lambda s: s["codes"][s["group"]] == "us")(
                        panel.state()), 12, f"the us group (attempt {attempt})")
                    break
                except Failure:
                    continue
            wait_for(lambda: panel.state()["ready"] is True, 30,
                     "the keyboard to be ready again after the return")
            us_state = panel.state()
            if us_state["factsAD01"] not in ("q", None):
                raise Failure(f"the us group draws AD01 = "
                              f"{us_state['factsAD01']!r}, expected q")
            if us_state["factsAD01"] != "q":
                raise Failure(f"us AD01 unreadable: {us_state}")
            print("ok    us group drawn again: AD01 = "
                  + us_state["factsAD01"])

            # ---- ticket 47's regression net: the daemon-bounce wedge ----
            # The stranger's BLOCKER, replayed: a GRACEFUL daemon stop under
            # a connected panel. Quickshell's socket can keep reporting
            # `connected: true` on the peer-closed transport (observed live
            # twice; see SocketWatch.js), and the old reconnect policy only
            # ever re-helloed an open-looking socket — wedging the panel at
            # "Starting omarchy-osk.service…" with every key click a silent
            # no-op until a shell restart. The hello watchdog must recover
            # it on its own; a panel that stays unready here is exactly
            # this ticket returning.
            daemon.process.terminate()
            daemon.process.wait(timeout=10)
            daemon.log.close()
            daemon = CanaryDaemon(repo)
            own_socket_or_die()
            bounced = time.monotonic()
            wait_for(lambda: panel.state()["ready"] is True, 45,
                     "the keyboard to become ready again after the "
                     "graceful daemon bounce (the ticket-47 wedge)")
            print(f"ok    recovered from the graceful daemon bounce in "
                  f"{time.monotonic() - bounced:.1f}s")
            facts = daemon.caps(0, ["AD01"])
            if not facts["AD01"] or facts["AD01"][0] != "q":
                raise Failure(f"the bounced-back helper answers us AD01 = "
                              f"{facts['AD01']!r}, expected ['q', …]")
            print("ok    bounced-back helper answers us AD01 = "
                  + repr(facts["AD01"]))

            panel.command("close", "closed")

            # ---- the window closes here: sweep everything ----
            window_end = time.time()

            # 1. The leg's own shell: zero fallback lines, zero new
            #    warnings, grandfathered count unchanged.
            leg_final = our_warnings(panel.warnings())
            assert_no_growth(leg_base, leg_final, "the leg's shell log")
            leg_fallbacks = sum(
                1 for line in panel.raw_lines() if FALLBACK in line)
            if leg_fallbacks:
                raise Failure(f"the leg's shell logged {leg_fallbacks} "
                              "keycap fallback line(s)")
            print(f"ok    leg shell: 0 keycap fallback lines; anchor "
                  f"warnings stable at {len(leg_final[0])}; no new kinds")

            # 2. The session journal across the leg's whole window: the
            #    packaged panel draws there while the service is stopped.
            journ = journal_lines(window_start, window_end)
            found = sweep(journ)
            if found["fallbacks"]:
                for line in journ:
                    if FALLBACK in line:
                        print("      journal: " + line.strip()[:200])
                        break
                raise Failure(f"the shell journal carries "
                              f"{found['fallbacks']} keycap fallback "
                              "line(s) in the leg's window")
            grand, new = our_warnings(found["ours"])
            if new:
                for line in new[:8]:
                    print("      journal warning: " + line[:200])
                raise Failure(f"the shell journal carries {len(new)} QML "
                              "warning(s) naming our files that are not "
                              "the grandfathered anchor warning")
            print(f"ok    shell journal ({len(journ)} lines in window): "
                  f"0 keycap fallback, {len(grand)} grandfathered anchor "
                  "warnings, no new kinds")

            # 3. The independent keymap truth: the helper's own caps reply
            #    names й at AD01 level 1 of the ua group — the panel's
            #    facts and the keymap agree from both ends.
            codes_now = us_state["codes"]
            facts = daemon.caps(ua_group, ["AD01"])
            if not facts["AD01"] or facts["AD01"][0] != "\u0439":
                raise Failure(f"the installed keymap answers ua AD01 = "
                              f"{facts['AD01']!r}, expected "
                              f"['\u0439', \u2026]")
            print(f"ok    helper caps reply: ua group {ua_group} AD01 = "
                  f"{facts['AD01']!r}")

            print("ok    CANARY GREEN: the real panel opened, both groups "
                  "drew their keymaps, the journal stayed clean")
        finally:
            if panel:
                panel.close()
            daemon.close()


def restore_service():
    # The lab is disposable, not abandoned: LiveSession started the
    # service again on exit, and one observed transient swallowed that
    # start — so verify it, retry the start, and only then leave.
    for attempt in range(3):
        if not service_active():
            subprocess.run(
                ["systemctl", "--user", "start", "omarchy-osk.service"],
                capture_output=True, timeout=15,
            )
        try:
            wait_for(service_active, 10, "the packaged service to come "
                     "back after the leg")
            break
        except Failure:
            if attempt == 2:
                raise
    print("ok    lab restored: omarchy-osk.service active")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  canary leg: {failure}")
        sys.exit(1)
