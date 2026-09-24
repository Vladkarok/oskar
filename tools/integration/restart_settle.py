#!/usr/bin/env python3
"""Ticket 38's live-lab leg: the restart-settle race, end to end.

The incident (journal in the ticket): the daemon restarted under a live
panel, the first configure after the reconnect re-established the world,
one language click three seconds later moved all three keyboards to group
1 — and a devices read that returned the reading keyboard at 0 (Hyprland
re-applying keymaps around the fresh vkb registration) was FOLLOWED by the
panel, splitting the seat and dragging `remembered` onto the churn. The
settle guard (SettleGuard.js, pure, tests/settle-guard.qml) now holds
uncommanded flips inside a short post-reconnect window; the click's own
hyprctl loop is untouched.

This leg proves the live behaviour on the packaged-shaped lab session
(docs/vm-handoff.md — the nested polygon cannot host the panel, ticket 37's
venue finding, so this runs live only):

1. THE RACE LEG: with the real Panel.qml hosted (the FileView command-file
   technique), the leg daemon is RESTARTED under the live panel and a
   language click is issued the moment the panel is ready again — inside
   the guard's window. Asserts, for a click each way:
   - the seat converges on the CLICKED group: every switch-set device at
     the same absolute group in `hyprctl devices -j`, no split, 2 s after;
   - the panel issued exactly ONE group-moving command for the click: the
     daemon's own `group -> <n>` log (the same line the incident's journal
     carried) shows exactly the clicked group and nothing else — the
     bounce that once added a second, churn-following move is gone;
   - `remembered` (persisted from configure acks) matches the clicked
     group after the settle, and typing readiness is true at the leg's
     end (asserted at settle, not continuously through the click).
2. THE COLD-START CONTROL (decisions §47): a genuinely diverged seat
   (majority 0, one sleeper 1), no safe device holding `main`, no named
   typist — the remembered group must still be the tie-breaker a FRESH
   panel follows on its establishing configure, and the settle guard must
   never engage on that path: zero hold lines, group == remembered.

Isolation: the hosted panel and the leg daemon run under a PRIVATE
XDG_RUNTIME_DIR (with the session's wayland + hypr sockets symlinked in),
so the lab session's own packaged panel cannot reconnect to the leg
daemon, move its virtual keyboard, or pollute the `group ->` count. The
packaged service is stopped for the leg and restarted after; per-device
groups, the panel's state.json and the compositor's kb_file are snapshotted
before and restored after.

Run inside the VM's lab session:

  cd ~/oskar && OSK_RESTART_SETTLE_LIVE=1 \
      python3 tools/integration/restart_settle.py
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import ANSI, Failure, wait_for


class LabSession:
    """Owns the lab session's OSK service socket for the leg's daemon.

    hold_column's LiveSession asks systemd to stop and trusts the exit
    code; the ticket-40 canary measured a stop that returned 0 with the
    unit still running, and that exact transient hit this leg — the
    packaged daemon ran THROUGH the leg, its panel kept reconfiguring it
    and republishing a stale one-group keymap over the compositor's
    kb_file, and every establishing configure compiled one group. So this
    leg stops the service the canary's way: verified inactive, with
    retries, and the packaged daemon's process actually gone.

    The seat's per-keyboard groups are remembered on the way in and put
    back on the way out, next to the service restart.
    """

    def __init__(self):
        self.group_was = {}

    def __enter__(self):
        for attempt in range(4):
            subprocess.run(
                ["systemctl", "--user", "stop", "oskar.service"],
                capture_output=True, timeout=15,
            )
            try:
                wait_for(lambda: not service_active(), 5,
                         "the packaged service to stop "
                         f"(attempt {attempt})")
                break
            except Failure:
                if attempt == 3:
                    state = subprocess.run(
                        ["systemctl", "--user", "show", "oskar.service",
                         "-p", "ActiveState,SubState,MainPID,NRestarts"],
                        capture_output=True, text=True).stdout
                    raise Failure("the packaged service would not stop: "
                                  + state.strip())
                continue
        # A stale socket file from the dying daemon reads as "another
        # daemon owns the socket" to the next one (measured live, canary).
        stale = os.path.join(RUNTIME, "oskar/control.sock")
        if os.path.exists(stale):
            os.unlink(stale)
        try:
            keyboards = json.loads(hyprctl("devices", "-j"))["keyboards"]
        except (json.JSONDecodeError, KeyError):
            keyboards = []
        for keyboard in keyboards:
            name = keyboard.get("name", "")
            if name:
                self.group_was[name] = keyboard.get("active_layout_index", 0)
        return self

    def __exit__(self, *exc):
        for name, group in self.group_was.items():
            hyprctl("switchxkblayout", name, str(group))
        subprocess.run(
            ["systemctl", "--user", "start", "oskar.service"],
            capture_output=True, timeout=15,
        )
        return False

LAB_HOSTNAME = "testprod"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
# Deliberately short: quickshell builds "<runtime>/hypr/<sig>/.socket.sock"
# and a unix socket address must fit 108 bytes, so a longer runtime dir
# name makes quickshell's Hyprland IPC fail with ServerNotFoundError while
# plain hyprctl (using a shorter env) still works.
PRIVATE = os.path.join(RUNTIME, "osk-sl-rt")
STATE_FILE = os.path.expanduser("~/.local/state/oskar/state.json")


def guard():
    # The two-gate pattern from panel_canary.py: live-only by explicit
    # human opt-in, and the lab's documented hostname as positive proof —
    # this leg stops the osk service and drives the live session, so a
    # wrong machine must refuse before it can.
    if os.environ.get("OSK_RESTART_SETTLE_LIVE", "") != "1":
        raise Failure("this leg stops the osk service and drives the live "
                      "session — run it only in the omarchy-vm lab, with "
                      "OSK_RESTART_SETTLE_LIVE=1 (docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"OSK_RESTART_SETTLE_LIVE=1 is set, but this host is "
                      f"{os.uname().nodename!r}, not the lab "
                      f"({LAB_HOSTNAME!r}); refusing (docs/vm-handoff.md)")


def hyprctl(*args, env=None):
    out = subprocess.run(["hyprctl", *args], capture_output=True, text=True,
                         env=env)
    return out.stdout


def kb_file_option(env=None):
    out = hyprctl("getoption", "input:kb_file", "-j", env=env)
    try:
        return json.loads(out).get("str", "")
    except json.JSONDecodeError:
        return out.strip()


def sane_restore_target(pre_leg):
    """What the teardown may point the compositor back at (ticket 57).

    Empty unless the pre-leg value is a file this leg has no business
    undoing: a path under THIS leg's private runtime (a previous run's
    residue — restoring it would re-point the compositor at a file that
    is about to die) and a path that no longer exists are refused, and
    so is the lab's own PUBLISHED keymap path — a running panel that
    live-adopted the leg's private map during the run keeps feeding its
    dead memory on every snapshot while the compositor sits on the
    published path (that panel's published branch is sticky; measured
    live, the two-second compile-spam loop). Empty lets every panel
    re-observe the seat from RMLVO on its next snapshot — the packaged
    panel's reconnect pull or the next event — and re-share from a
    clean ack, which is the state a compositor that never met this leg
    converges to anyway."""
    if not pre_leg:
        return ""
    if pre_leg.startswith(PRIVATE):
        return ""
    if pre_leg == os.path.join(RUNTIME, "oskar", "keymap.xkb"):
        return ""
    if not os.path.exists(pre_leg):
        return ""
    return pre_leg


def restore_compositor_kb_file(target, where):
    """Leave the compositor compiling something that exists (ticket 57).

    The leg's panel points input:kb_file at the private runtime's
    published keymap; tearing that runtime down without restoring left
    every later panel feeding the compositor's dead setting to the
    daemon — the wall's §47 wedge, the two-second compile-spam loop.
    Cleared and set (assigning the same path again is a no-op, and the
    compositor must re-read whatever file it keeps), then verified by
    read-back: an unchecked failure here is exactly the wedge this
    exists to prevent, so it fails the leg loudly."""
    for attempt in range(3):
        hyprctl("eval", "hl.config({input = {kb_file = ''}})")
        if target:
            hyprctl("eval",
                    f"hl.config({{input = {{kb_file = '{target}'}}}})")
        if kb_file_option() == target:
            return
    raise Failure(f"{where}: the compositor's kb_file would not settle "
                  f"on {target!r} (now {kb_file_option()!r}) — refusing "
                  "to leave the lab a deleted keymap to compile")


def group_names_in_keymap(path):
    """The group display names compiled into one xkb keymap file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return re.findall(r'name\[\d+\]="[^"]*"', handle.read())
    except OSError:
        return []


def wait_seat_carries_groups(group_count, note):
    """The precondition that makes a group CLICK meaningful: whatever
    kb_file the compositor points at (the leg's private share, or the lab
    session's own packaged panel re-asserting ITS file — two panels share
    this compositor's global setting), the map the seat compiles must
    carry every declared group. Before that, `switchxkblayout <clicked>`
    answers `layout idx out of range` and the click evaporates (measured
    live — the canary's §35 wait, loosened to the file actually named)."""
    def seat_ready():
        kb_file = kb_file_option()
        if kb_file == "":
            return True  # per-device kb_layout: the lab's own 4-layout list
        return len(group_names_in_keymap(kb_file)) >= group_count
    wait_for(seat_ready, 45,
             f"the seat's keymap ({kb_file_option()!r}) to carry "
             f"{group_count} groups ({note})")


def keyboard_groups(env=None):
    """name -> active_layout_index, for every keyboard on the seat."""
    try:
        keyboards = json.loads(hyprctl("devices", "-j", env=env))["keyboards"]
    except (json.JSONDecodeError, KeyError):
        return {}
    return {k.get("name", ""): k.get("active_layout_index", 0)
            for k in keyboards}


def service_active():
    out = subprocess.run(
        ["systemctl", "--user", "is-active", "oskar.service"],
        capture_output=True, text=True).stdout.strip()
    return out == "active"


class PrivateRuntime:
    """The hosted panel and the leg daemon under one private runtime dir.

    The panel dials `$XDG_RUNTIME_DIR/oskar/control.sock`; pointing
    that at a private directory keeps the lab session's own packaged panel
    (which reconnects to whatever owns the public path — measured live in
    the ticket-40 canary) out of the leg daemon's client list, so every
    `group ->` line in its log is this leg's panel's. The wayland and
    hypr sockets are symlinked through so quickshell still reaches the
    real session compositor.
    """

    def __init__(self):
        self.wayland = os.environ.get("WAYLAND_DISPLAY", "wayland-1")
        self.env = dict(os.environ)
        self.env["XDG_RUNTIME_DIR"] = PRIVATE

    def __enter__(self):
        shutil.rmtree(PRIVATE, ignore_errors=True)
        os.makedirs(PRIVATE, exist_ok=True)
        os.symlink(os.path.join(RUNTIME, self.wayland),
                   os.path.join(PRIVATE, self.wayland))
        os.symlink(os.path.join(RUNTIME, "hypr"), os.path.join(PRIVATE, "hypr"))
        return self

    def __exit__(self, *exc):
        shutil.rmtree(PRIVATE, ignore_errors=True)
        return False


class LegDaemon:
    """The helper under the private runtime; one instance per lifetime.

    Its stderr carries the same `group -> <n>` line the incident's journal
    did (daemon/src/state.rs logs every same-keymap group move), which is
    the leg's independent count of group-moving commands.
    """

    def __init__(self, repo, tag, env):
        self.env = env
        self.tag = tag
        self.log_path = os.path.join(RUNTIME, f"osk-settle-leg-daemon-{tag}.log")
        self.log = open(self.log_path, "w+")
        self.process = subprocess.Popen(
            [os.path.join(repo, "daemon/target/release/oskar-daemon")],
            stdout=self.log, stderr=subprocess.STDOUT, env=env,
        )
        self.socket_path = os.path.join(PRIVATE, "oskar/control.sock")

    def wait_socket(self):
        wait_for(lambda: os.path.exists(self.socket_path), 10,
                 f"the leg daemon ({self.tag}) socket to appear")

    def group_moves(self):
        """Every `group -> <n>` line so far, in order."""
        self.log.flush()
        self.log.seek(0)
        return re.findall(r"group -> (\d+)", self.log.read())

    def close(self):
        # Idempotent: the leg's error paths can hand the same daemon to
        # two close() calls (race_cycle's guard and the caller's finally).
        if self.log.closed:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()
        # A stale socket file from the dying daemon reads as "another
        # daemon owns the socket" to the next one (measured live, canary).
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)


SHELL_QML = """\
import Quickshell
import Quickshell.Io
import QtQuick
import "file:__TREE__" as Plugin

Item {
    id: root

    // The real panel — the component the omarchy shell loads — bringing
    // its own PanelWindows, config/state files and socket client, but
    // dialled at the private runtime the leg owns.
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
        if (obj.contentItem !== undefined) return walkItem(obj.contentItem)
        var kids = obj.data !== undefined ? obj.data : obj.children
        if (!kids) return null
        for (var i = 0; i < kids.length; i++) {
            var found = walkObject(kids[i], depth + 1)
            if (found) return found
        }
        return null
    }

    function keyboard() {
        if (!root.kb) root.kb = walkObject(panel, 0)
        return root.kb
    }

    function log(line) { console.log("[settleleg] " + line) }

    function state() {
        var kb = keyboard()
        if (!kb) { log("state no-keyboard"); return }
        log("state " + JSON.stringify({
            opened: panel.opened,
            ready: kb.inputReady,
            codes: kb.layoutCodes,
            group: kb.groupCursor,
            remembered: kb.rememberedLayoutGroup,
            switchSet: kb.switchKeyboards,
            anchor: kb.anchorKeyboardName,
            sharedGen: kb.sharedKeymapGen,
            sock: kb.daemonSocket ? kb.daemonSocket.connected : false,
            lifecycle: kb.lifecycleKind,
            xkbFile: kb.xkbFile,
            userKeymap: kb.userKeymapFile,
            rmlvo: [kb.xkbRules, kb.xkbModel, kb.xkbLayouts,
                    kb.xkbVariants, kb.xkbOptions],
            lastConfigure: kb.session.queue.length > 0
                ? kb.session.queue[kb.session.queue.length - 1].payload : null
        }))
    }

    FileView {
        id: commandFile
        path: "__RUNTIME__/osk-settle-leg-cmd-__TAG__"
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
            case "tap": {
                // One OSK keystroke — the same path a cap click takes —
                // and its two halves, split. A key HELD DOWN through the
                // helper's virtual keyboard keeps the seat's `main` flag
                // on that (pseudo, safe-refused) device, which is where
                // the §47 control needs it: the branch answers only when
                // no live evidence exists.
                var kb = keyboard()
                if (!kb) { log("no-keyboard"); break }
                var caps = kb.capsFacts
                var position = caps ? Object.keys(caps)[0] : null
                var record = position ? caps[position] : null
                if (!record || record.length < 1
                        || record[0].text === undefined) {
                    log("no-facts")
                    break
                }
                if (parts[1] === "down") {
                    kb.typeCap({ xkb: position, chr: record[0].text })
                    log("down " + position)
                } else if (parts[1] === "up") {
                    kb.releaseKey()
                    log("up")
                } else {
                    kb.typeCap({ xkb: position, chr: record[0].text })
                    kb.releaseKey()
                    log("tapped " + position)
                }
                break
            }
            }
        }
        onLoadFailed: function (error) {
            // The command file not existing yet is the starting state.
        }
    }

    Component.onCompleted: {
        log("env sig=" + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
            + " rt=" + Quickshell.env("XDG_RUNTIME_DIR")
            + " wl=" + Quickshell.env("WAYLAND_DISPLAY"))
        log("alive")
    }
}
"""


class Panel:
    """The real panel, hosted by a minimal shell and driven by command file.

    `tag` gives each concurrent instance its own config dir, command file
    and log: quickshell identifies a shell by its config path, and two
    processes on ONE path fight (the first cut of the §47 control had the
    fresh panel's world reset to defaults under the holder — measured
    live)."""

    def __init__(self, repo, env, tag="main"):
        self.seq = 0
        self.env = env
        self.cfg = os.path.join(PRIVATE, f"osk-settle-shell-{tag}")
        os.makedirs(self.cfg, exist_ok=True)
        for name in ("Commons", "Ui"):
            target = os.path.join(self.cfg, name)
            if not os.path.exists(target):
                os.symlink(f"/usr/share/omarchy/shell/{name}", target)
        self.command_path = os.path.join(PRIVATE, f"osk-settle-leg-cmd-{tag}")
        if os.path.exists(self.command_path):
            os.unlink(self.command_path)
        shell = os.path.join(self.cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML
                         .replace("__TREE__", repo)
                         .replace("__RUNTIME__", PRIVATE)
                         .replace("__TAG__", tag))
        self.log = open(os.path.join(RUNTIME,
                                     f"osk-settle-leg-shell-{tag}.log"), "w+")
        self.process = subprocess.Popen(
            ["quickshell", "-p", shell],
            stdout=self.log, stderr=subprocess.STDOUT, env=env,
        )

    def marker_lines(self):
        self.log.flush()
        self.log.seek(0)
        out = []
        for line in self.log.read().splitlines():
            clean = ANSI.sub("", line)
            marker = clean.find("[settleleg] ")
            if marker != -1:
                out.append(clean[marker + len("[settleleg] "):])
        return out

    def holds(self):
        """The settle guard's own hold lines — churn caught, if any."""
        self.log.flush()
        self.log.seek(0)
        return [l for l in self.log.read().splitlines()
                if "settle guard: holding" in l]

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


def race_cycle(panel, daemon, repo, env, clicked, group_count, label):
    """Restart the daemon under the live panel, click inside the window,
    and assert the click wins: converged seat, one group command, the
    remembered group on the clicked value, readiness held."""
    daemon.close()
    time.sleep(0.3)
    daemon = LegDaemon(repo, label, env)
    try:
        daemon.wait_socket()

        # The panel reconnects on its own (the loader rebuilds the socket
        # every 2 s while the handshake is unanswered); ready again means
        # the hello, the ESTABLISHING configure and its caps facts have
        # all landed — the establishing configure is the moment the
        # guard's window opened.
        wait_for(lambda: panel.state()["sock"] is True, 30,
                 f"the panel to reconnect after the {label} daemon restart")
        wait_for(lambda: panel.state()["ready"] is True, 90,
                 f"the panel to be ready again after the {label} restart")
        # The share must land before the click is meaningful: the toggle
        # moves devices by absolute index against whatever keymap the
        # compositor compiles for them. Still comfortably inside the
        # guard's ten-second window — the share lands within ~1 s of
        # ready.
        wait_seat_carries_groups(group_count, label)
        reconnect_state = panel.state()
        print(f"ok    reconnected and ready after {label} restart: "
              f"group {reconnect_state['group']}, remembered "
              f"{reconnect_state['remembered']}")

        # THE CLICK, immediately: inside the guard's window.
        panel.command(f"group {clicked}", "grouped")

        # The click's echo must be followed at once — a guard that held
        # its own click would break switching for the window's length.
        wait_for(lambda: panel.state()["group"] == clicked, 12,
                 f"the panel to reach the clicked group {clicked} ({label})")
        wait_for(lambda: panel.state()["ready"] is True, 30,
                 f"typing readiness to hold through the click ({label})")

        # Settle, then judge the seat: every switch-set device converged
        # on the clicked absolute group, no split.
        time.sleep(2.0)
        state = panel.state()
        groups = keyboard_groups()
        seat = {name: groups.get(name) for name in state["switchSet"]}
        split = {n: g for n, g in seat.items() if g != clicked}
        if split:
            raise Failure(f"the seat stayed split after the {label} click: "
                          f"{seat}, expected every switch-set device at "
                          f"{clicked}")
        # The remembered group is persisted from configure acks; the
        # click's ack is the last word.
        wait_for(lambda: panel.state()["remembered"] == clicked, 10,
                 f"remembered to settle on the clicked group {clicked} "
                 f"({label})")

        # The independent count: the daemon saw exactly ONE group-moving
        # command — the click's echo. The incident's bounce was a second
        # `group ->` back onto the churn's group.
        moves = daemon.group_moves()
        if moves != [str(clicked)]:
            raise Failure(f"the daemon logged group moves {moves} after "
                          f"the {label} click, expected exactly "
                          f"['{clicked}'] — the follow bounced")
        holds = len(panel.holds())
        print(f"ok    {label} click: seat converged {seat}, one daemon "
              f"group command (-> {clicked}), remembered {clicked}, "
              f"{holds} churn hold(s) by the guard")
        return daemon
    except Exception:
        daemon.close()
        raise


def seeded_anchor_name(socket_path):
    """The device a FRESH panel will name as its anchor: the helper's
    `keyboards` reply is the daemon's sorted physical inventory, and the
    panel seeds `anchorKeyboardName` from its FIRST name at hello — before
    the first snapshot can run. The §47 control's diverged seat is only
    deterministic when the sleeper IS that device (ticket 57's rerun: the
    race left the holder's anchor elsewhere, the fresh panel's seeded
    anchor sat in the majority, and the control answered 0)."""
    import socket as socket_mod
    try:
        client = socket_mod.socket(socket_mod.AF_UNIX,
                                   socket_mod.SOCK_STREAM)
        client.settimeout(3)
        client.connect(socket_path)
        client.sendall(b"keyboards\n")
        reply = client.recv(4096).decode("utf-8", "replace")
        client.close()
    except OSError:
        return ""
    names = [name for name in reply.strip().split("\t")[1:] if name]
    return names[0] if names else ""


def control_cold_start(repo, env, switch_set, holder, anchor,
                       daemon_socket):
    """Decisions §47, unchanged in its claim: a genuinely diverged seat
    (majority 0, one sleeper 1), no safe device holding `main` — a FRESH
    panel's establishing configure must land on group 1 (the remembered
    group agrees with the sleeper), and the settle guard must never
    engage on that path: zero hold lines.

    `holder` is the race phase's panel, holding one OSK key DOWN so the
    seat's `main` stays on the leg daemon's (pseudo) virtual keyboard
    across the fresh panel's establishing snapshot; it is closed once the
    assertion is home. The sleeper is the device a fresh panel SEEDS as
    its anchor (the daemon's first `keyboards` name) when the switch set
    has it — every fresh panel names that device at hello, so the seat
    must diverge around IT or the control measures the majority's answer
    instead of the remembered one (ticket 57's rerun)."""
    if len(switch_set) < 3:
        raise Failure(f"the panel's switch set is {switch_set}; the control "
                      "needs at least three devices to diverge")
    # The sleeper must be the device the FRESH panel will seed as its
    # anchor (the daemon's first `keyboards` name) when the switch set
    # has it — the holder's own anchor only keeps the HOLDER's configures
    # at 1, and a fresh panel that seeds a majority device answers the
    # majority instead.
    seeded = seeded_anchor_name(daemon_socket)
    if seeded in switch_set:
        sleeper = seeded
    elif anchor in switch_set:
        sleeper = anchor
    else:
        sleeper = switch_set[0]
    majority = [n for n in switch_set if n != sleeper]
    # Majority at 0, one sleeper at 1, remembered 1: the sleepers' majority
    # must NOT outvote the remembered group.
    for name in majority:
        hyprctl("switchxkblayout", name, "0")
    hyprctl("switchxkblayout", sleeper, "1")
    # Let the holder's split-triggered churn drain BEFORE the state is
    # written: the split is an uncommanded flip from the holder's side,
    # its settle guard holds the follow, and every held re-configure's
    # ACK persists the held group back into the state file — clobbering
    # any remembered value written too early. SettleGuard's window is
    # 10 s; a wait past it plus a stability check makes the write the
    # last word.
    time.sleep(12)
    # `main` held on the leg daemon's virtual keyboard by the holder's
    # key — a device every safe set refuses. The key goes down AFTER the
    # split: `switchxkblayout` takes `main` for its own target, so an
    # earlier hold would be stolen right back.
    holder.command("tap down", "down ")
    wait_for(vkb_holds_main, 10,
             "the held OSK key to take main onto the leg vkb")
    mains = [n for n in switch_set if is_main(n)]
    if mains:
        raise Failure(f"safe keyboard(s) {mains} hold main; the §47 branch "
                      "needs no live evidence — rerun the control")
    # The remembered world, written LAST and verified stable: the
    # persisted device cleared (the named tier must not answer for the
    # fresh panel), the remembered group 1.
    for attempt in range(4):
        write_state({"layout_group": 1, "layout_device": ""})
        time.sleep(1.5)
        state_now = read_state() or {}
        if state_now.get("layout_group") == 1 \
                and state_now.get("layout_device") == "":
            break
    else:
        raise Failure("the state file would not hold the §47 control's "
                      f"remembered world (now {read_state()}) — the holder's "
                      "acks keep clobbering it; rerun the control")

    panel = Panel(repo, env, tag="control")
    try:
        wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                 120, "the control panel to start")
        wait_for(lambda: panel.state()["ready"] is True, 90,
                 "the control panel to become ready")
        state = panel.state()
        if state["group"] != 1:
            raise Failure(f"the fresh panel answered group {state['group']} "
                          "on a diverged cold start; §47 says the "
                          "remembered group 1 is the tie-breaker "
                          f"(state: {state})")
        wait_for(lambda: panel.state()["remembered"] == 1, 10,
                 "the control panel's remembered group to stay on 1")
        holds = panel.holds()
        if holds:
            raise Failure(f"the settle guard engaged on the §47 cold-start "
                          f"path: {holds[:3]} — the establishing configure "
                          "and the remembered answer must never be held")
        print(f"ok    §47 cold-start control: diverged seat "
              f"(0: {sorted(majority)}, 1: ['{sleeper}' — the fresh "
              "panel's seeded anchor]), main on the leg vkb — fresh panel "
              "landed on group 1, guard silent")
        panel.command("close", "closed")
    finally:
        panel.close()
        holder.close()


def is_main(name):
    try:
        keyboards = json.loads(hyprctl("devices", "-j"))["keyboards"]
    except (json.JSONDecodeError, KeyError):
        return False
    return any(k.get("name") == name and k.get("main") for k in keyboards)


def vkb_holds_main():
    """The leg daemon's virtual keyboard holds the seat's `main` flag."""
    try:
        keyboards = json.loads(hyprctl("devices", "-j"))["keyboards"]
    except (json.JSONDecodeError, KeyError):
        return False
    return any(k.get("main") and "hl-virtual-keyboard" in k.get("name", "")
               for k in keyboards)


def read_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def write_state(overrides):
    state = read_state() or {}
    state.update(overrides)
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2)


def restore_service():
    for attempt in range(3):
        if not service_active():
            subprocess.run(
                ["systemctl", "--user", "start", "oskar.service"],
                capture_output=True, timeout=15)
        try:
            wait_for(service_active, 10,
                     "the packaged service to come back after the leg")
            break
        except Failure:
            if attempt == 2:
                raise
    print("ok    lab restored: oskar.service active")


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    state_backup = read_state()
    kb_file_was = kb_file_option()
    daemon = None
    panel = None
    with LabSession() as lab, PrivateRuntime() as rt:
        packaged_keymap = os.path.join(RUNTIME, "oskar/keymap.xkb")
        packaged_backup = None
        try:
            # The lab session's own packaged panel is ALIVE while this leg
            # runs, and it re-asserts the compositor's global kb_file at
            # ITS runtime's published file whenever it observes a change —
            # including a one-group default left by a daemon restart its
            # panel never reconfigured. A hosted panel whose runtime
            # differs cannot recognize that file as OSK-published (needs
            # exact identity), adopts it as the user's own, and the whole
            # leg then compiles one group: caps for the other groups
            # refused, the toggle out of range. The deterministic fix is
            # to heal THAT file for the leg's lifetime — the seat's own
            # four-layout list — with the found bytes backed up and
            # restored at the end (the packaged daemon also rewrites it
            # at its next install).
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
            daemon = LegDaemon(repo, "first", rt.env)
            daemon.wait_socket()
            panel = Panel(repo, rt.env)
            wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                     120, "the hosted panel to start")
            panel.command("open", "opened")
            wait_for(lambda: panel.state()["opened"] is True, 20,
                     "the panel window to open")
            wait_for(lambda: panel.state()["ready"] is True, 90,
                     "the keyboard to become ready to type")

            state = panel.state()
            codes = state["codes"]
            if "ua" not in codes:
                raise Failure(f"the seat's layout list {codes} carries no "
                              "ua group; the lab guest's configuration "
                              "changed under this leg")
            if len(state["switchSet"]) < 2:
                raise Failure(f"the switch set is {state['switchSet']}; the "
                              "leg needs the lab's real multi-keyboard seat")
            ua_group = codes.index("ua")
            print(f"ok    hosted panel ready: codes {codes}, switch set "
                  f"{state['switchSet']}, starting group {state['group']}")

            # The race, both directions: restart + immediate click inside
            # the window, to ua and back to us.
            if state["group"] == ua_group:
                daemon = race_cycle(panel, daemon, repo, rt.env, 0,
                                    len(codes), "restart-2")
            else:
                daemon = race_cycle(panel, daemon, repo, rt.env, ua_group,
                                    len(codes), "restart-2")
            final = panel.state()["group"]
            daemon = race_cycle(panel, daemon, repo, rt.env,
                                0 if final != 0 else ua_group, len(codes),
                                "restart-3")

            # The cold-start control: fresh panel, pre-split seat. One OSK
            # key HELD DOWN (inside the control, after the split) keeps
            # the seat's `main` flag on the leg daemon's own virtual
            # keyboard — pseudo, refused by every safe set — because that
            # branch answers only when no live evidence exists. A plain
            # tap is not enough: the flag returns to the last real
            # keyboard within the moment.
            switch_set = panel.state()["switchSet"]
            anchor = panel.state()["anchor"]
            control_cold_start(repo, rt.env, switch_set, panel, anchor,
                               daemon.socket_path)
            panel = None

            print("ok    SETTLE LEG GREEN: restart+click converged on the "
                  "clicked group both ways with one group command each, "
                  "and the §47 cold-start answer is unchanged")
        finally:
            if panel:
                panel.close()
            if daemon:
                daemon.close()
            # The lab back exactly as found: the panel's persisted state,
            # the packaged panel's published file, the compositor's
            # kb_file, the service, the per-device groups (LabSession's
            # exit). The kb_file restore runs before the service restart
            # so the republished packaged keymap cannot race it, and it
            # always runs: skipping an empty pre-leg value or never
            # verifying the eval landed lets the compositor keep compiling
            # the leg's private keymap after the private runtime died.
            # The helper's sidecar under the private runtime dies with it
            # too — the record must not outlive what it names.
            if state_backup is not None:
                with open(STATE_FILE, "w", encoding="utf-8") as handle:
                    json.dump(state_backup, handle, indent=2)
            if packaged_backup is not None:
                with open(packaged_keymap, "wb") as handle:
                    handle.write(packaged_backup)
            sidecar = os.path.join(PRIVATE, "oskar",
                                   "user-keymap-source")
            if os.path.exists(sidecar):
                os.unlink(sidecar)
            restore_compositor_kb_file(sane_restore_target(kb_file_was),
                                       "the settle leg's teardown")
    restore_service()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  settle leg: {failure}")
        sys.exit(1)
