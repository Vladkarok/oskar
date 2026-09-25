#!/usr/bin/env python3
"""The panel's transport under injected faults: the real Panel.qml against
a scripted helper (fake_helper.py) that drops, mutes, stalls and refuses on
command.

HelperLink.qml's recovery paths — the disconnect redial, the hello
watchdog's rebuild of a socket that reads `connected` but cannot deliver,
the repair re-hello of an unready connection, the chord guard — are pure
decisions (SocketWatch.js, ChordAcks.js) wired into QML that only the lab
can compose. This leg composes them against a peer that misbehaves on
purpose, and for each fault asserts the recovery the decisions promise:

  - the typing gate reopens within the watchdog's bound, measured from the
    moment the fault became visible to the panel (HELLO_STALE_MS, read from
    SocketWatch.js, plus two fast reconnect ticks, read from HelperLink.qml,
    plus a margin);
  - the fake saw a fresh `hello 7` on a new connection after every drop or
    rebuild, and a key tap after recovery reached the fake and was answered;
  - no paste chord stays armed, and none outlives the 8 s chord guard;
  - the hosted shell logged no `keycap fallback` and no new QML
    WARN/ERROR naming our files (the canary's sweep; the panel's own
    `[oskar]` journal lines are product messages, not engine warnings).

Isolation: the hosted panel and the fake run under a private
XDG_RUNTIME_DIR (restart_settle's PrivateRuntime, wayland and hypr sockets
symlinked through), so the lab session's packaged panel never meets the
fake and the packaged service keeps running untouched. The fake owns no
virtual keyboard and answers `share` without touching the compositor, so
nothing here moves the seat or its keymap. The panel's state file is
restored afterwards.

Run inside the VM's lab session (docs/vm-handoff.md):
  cd ~/oskar && OSK_TRANSPORT_LIVE=1 python3 tools/integration/transport_faults.py
"""

import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import ANSI, Failure, wait_for  # noqa: E402
from panel_canary import FALLBACK, our_warnings  # noqa: E402
from restart_settle import (PRIVATE, RUNTIME, STATE_FILE,  # noqa: E402
                            PrivateRuntime, read_state)

LAB_HOSTNAME = "testprod"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MARK = "[tfleg] "
CHORD_GUARD_S = 8.0
MARGIN_S = 3.0


def product_constant(path, pattern, what):
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        found = re.search(pattern, handle.read())
    if not found:
        raise Failure(f"cannot read {what} from {path}")
    return int(found.group(1)) / 1000.0


# The bound follows the product: the stale window SocketWatch judges by,
# and the reconnect timer's fast interval.
HELLO_STALE_S = product_constant("SocketWatch.js",
                                 r"var HELLO_STALE_MS = (\d+)",
                                 "HELLO_STALE_MS")
def fast_tick():
    with open(os.path.join(REPO, "HelperLink.qml"), encoding="utf-8") as h:
        found = re.search(r"\|\| !link\.sessionSettled\) \? (\d+) : (\d+)",
                          h.read())
    if not found:
        raise Failure("cannot read the reconnect timer's intervals from "
                      "HelperLink.qml")
    return int(found.group(1)) / 1000.0


FAST_TICK_S = fast_tick()
BOUND_S = HELLO_STALE_S + 2 * FAST_TICK_S + MARGIN_S


def guard():
    if os.environ.get("OSK_TRANSPORT_LIVE", "") != "1":
        raise Failure("this leg hosts a panel in the live session — run it "
                      "only in the omarchy-vm lab, with OSK_TRANSPORT_LIVE=1 "
                      "(docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"OSK_TRANSPORT_LIVE=1 is set, but this host is "
                      f"{os.uname().nodename!r}, not the lab "
                      f"({LAB_HOSTNAME!r}); refusing (docs/vm-handoff.md)")


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

    function log(line) { console.log("[tfleg] " + line) }

    function armed() {
        return !!(root.kb && root.kb.chordAcks && root.kb.chordAcks.chordDone)
    }

    // Every gate and chord transition, stamped: the leg times recovery
    // from these, so a blip shorter than a state poll is still seen.
    property bool lastArmed: false
    Connections {
        target: root.kb
        ignoreUnknownSignals: true
        function onInputReadyChanged() {
            root.log("gate " + root.kb.inputReady + " " + Date.now())
        }
        function onChordAcksChanged() {
            var now = root.armed()
            if (now !== root.lastArmed) {
                root.lastArmed = now
                root.log("armed " + now + " " + Date.now())
            }
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: root.kb === null
        onTriggered: {
            if (root.keyboard()) root.log("keyboard " + root.kb.inputReady
                + " " + Date.now())
        }
    }

    function state() {
        var kb = keyboard()
        if (!kb) { log("state no-keyboard"); return }
        log("state " + JSON.stringify({
            opened: panel.opened,
            ready: kb.inputReady,
            lifecycle: kb.lifecycleKind,
            armed: armed(),
            queue: kb.chordAcks ? kb.chordAcks.queue.length : -1,
            flow: kb.pasteFlow ? kb.pasteFlow.phase : null,
            sock: kb.daemonSocket ? kb.daemonSocket.connected : false,
            facts: kb.capsFacts !== null,
            codes: kb.layoutCodes,
            group: kb.groupCursor,
            now: Date.now()
        }))
    }

    FileView {
        id: commandFile
        path: "__RUNTIME__/osk-tf-cmd"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var command = String(text() || "").trim()
            if (command === "") return
            var parts = command.split(" ")
            var kb = keyboard()
            switch (parts[0]) {
            case "open":
                panel.opened = true
                log("opened")
                break
            case "close":
                panel.close()
                log("closed")
                break
            case "state":
                state()
                break
            case "tap": {
                // One cap click's two halves, on AD01 as the facts draw it.
                if (!kb) { log("no-keyboard"); break }
                var caps = kb.capsFacts
                var record = caps ? caps.AD01 : null
                if (!record || record.length < 1
                        || record[0].text === undefined) {
                    log("no-facts " + Date.now())
                    break
                }
                kb.typeCap({ xkb: "AD01", chr: record[0].text })
                kb.releaseKey()
                log("tapped " + Date.now())
                break
            }
            case "paste": {
                // The current-content paste's chord, the same entry the
                // header chip and the emoji transaction call; its verdict
                // arrives through the completion callback.
                if (!kb) { log("no-keyboard"); break }
                var started = Date.now()
                var dispatched = kb.pasteCurrent("", function (ok) {
                    root.log("paste-done " + ok + " " + Date.now())
                })
                log("paste-started " + dispatched + " " + started)
                break
            }
            }
        }
        onLoadFailed: function (error) {
            // The command file not existing yet is the starting state.
        }
    }

    Component.onCompleted: log("alive")
}
"""


class Fake:
    """fake_helper.py under the private runtime, driven by its control
    file; its log is the leg's record of the wire."""

    def __init__(self):
        self.socket_path = os.path.join(PRIVATE, "oskar/control.sock")
        self.control_path = os.path.join(PRIVATE, "osk-tf-fault")
        self.log_path = os.path.join(RUNTIME, "osk-tf-fake.log")
        for path in (self.control_path, self.log_path):
            if os.path.exists(path):
                os.unlink(path)
        open(self.control_path, "w").close()
        self.stderr = open(os.path.join(RUNTIME, "osk-tf-fake.err"), "w")
        self.process = subprocess.Popen(
            [sys.executable, os.path.join(HERE, "fake_helper.py"), "serve",
             "--socket", self.socket_path, "--control", self.control_path,
             "--log", self.log_path],
            stdout=self.stderr, stderr=subprocess.STDOUT)
        wait_for(lambda: os.path.exists(self.socket_path), 10,
                 "the fake helper's socket")

    def fault(self, *lines):
        now = time.time()
        with open(self.control_path, "a", encoding="utf-8") as handle:
            for line in lines:
                handle.write(line + "\n")
        wait_for(lambda: all(any(r[2] == "*" and r[3] == f"fault {line}"
                                 and r[0] >= now - 0.001
                                 for r in self.records())
                             for line in lines), 5,
                 f"the fake to take {lines}")
        return now

    def records(self):
        """(epoch, conn, mark, text) per logged line."""
        out = []
        try:
            with open(self.log_path, encoding="utf-8") as handle:
                for line in handle.read().splitlines():
                    parts = line.split(" ", 3)
                    if len(parts) == 4:
                        out.append((float(parts[0]), int(parts[1][1:]),
                                    parts[2], parts[3]))
        except OSError:
            pass
        return out

    def first(self, predicate, after=0.0):
        for record in self.records():
            if record[0] >= after and predicate(record):
                return record
        return None

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.stderr.close()


class Host:
    """The real panel, hosted by a minimal shell, driven by command file."""

    def __init__(self, env):
        self.seq = 0
        self.cfg = os.path.join(PRIVATE, "osk-tf-shell")
        os.makedirs(self.cfg, exist_ok=True)
        for name in ("Commons", "Ui"):
            target = os.path.join(self.cfg, name)
            if not os.path.exists(target):
                os.symlink(f"/usr/share/omarchy/shell/{name}", target)
        self.command_path = os.path.join(PRIVATE, "osk-tf-cmd")
        shell = os.path.join(self.cfg, "shell.qml")
        with open(shell, "w", encoding="utf-8") as handle:
            handle.write(SHELL_QML.replace("__TREE__", REPO)
                         .replace("__RUNTIME__", PRIVATE))
        self.log = open(os.path.join(RUNTIME, "osk-tf-shell.log"), "w+")
        self.process = subprocess.Popen(["quickshell", "-p", shell],
                                        stdout=self.log,
                                        stderr=subprocess.STDOUT, env=env)

    def raw_lines(self):
        self.log.flush()
        self.log.seek(0)
        return [ANSI.sub("", line) for line in self.log.read().splitlines()]

    def marker_lines(self):
        out = []
        for line in self.raw_lines():
            at = line.find(MARK)
            if at != -1:
                out.append(line[at + len(MARK):])
        return out

    def command(self, line, expect, timeout=20):
        self.seq += 1
        start = len(self.marker_lines())
        with open(self.command_path, "w", encoding="utf-8") as handle:
            handle.write(f"{line} {self.seq}\n")
        deadline = time.monotonic() + timeout
        lines = []
        while time.monotonic() < deadline:
            lines = self.marker_lines()
            for out in lines[start:]:
                if out.startswith(expect):
                    return out
            time.sleep(0.05)
        raise Failure(f"panel never answered {line!r} with {expect!r}; "
                      f"log tail: {lines[-12:]}")

    def state(self):
        return json.loads(self.command("state", "state ")[len("state "):])

    def stamped(self, word):
        """[(value, epoch)] for every `<word> <value> <ms>` marker."""
        out = []
        for line in self.marker_lines():
            parts = line.split()
            if len(parts) == 3 and parts[0] == word:
                out.append((parts[1], int(parts[2]) / 1000.0))
        return out

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


class Leg:
    def __init__(self, host, fake):
        self.host = host
        self.fake = fake
        self.counts = {}
        self.case = "setup"

    def ok(self, text):
        self.counts[self.case] = self.counts.get(self.case, 0) + 1
        print(f"ok    [{self.case}] {text}")

    # ---- the shared assertions ----

    def gate_reopened(self, anchor, since=None, must_drop=True,
                      bound=BOUND_S, timeout=None):
        """The gate closed after `since` (default: the anchor) and reopened
        inside `bound` of `anchor`, the moment the fault became visible."""
        since = anchor if since is None else since

        def reopened():
            events = [e for e in self.host.stamped("gate") if e[1] >= since]
            drop = next((e for e in events if e[0] == "false"), None)
            if must_drop and drop is None:
                return None
            after = max(drop[1] if drop else since, anchor)
            return next((e for e in events
                         if e[0] == "true" and e[1] >= after), None)
        wait_for(reopened, timeout or bound + 20,
                 f"the typing gate to reopen after the fault "
                 f"(gate events: {self.host.stamped('gate')[-6:]})")
        opened = reopened()[1]
        took = opened - anchor
        if took > bound:
            raise Failure(f"the gate reopened {took:.1f}s after the fault "
                          f"became visible; the watchdog's bound is "
                          f"{bound:.1f}s (HELLO_STALE {HELLO_STALE_S:.0f}s "
                          f"+ 2 ticks of {FAST_TICK_S:.0f}s + "
                          f"{MARGIN_S:.0f}s margin)")
        if self.host.stamped("gate")[-1][0] != "true":
            raise Failure("the gate closed again after reopening: "
                          f"{self.host.stamped('gate')[-6:]}")
        self.ok(f"typing gate reopened {took:.1f}s after the fault "
                f"(bound {bound:.1f}s)")
        return opened

    def fresh_hello(self, after):
        """A connection accepted after `after` said hello 7 and was
        answered hello 7; returns its number."""
        def found():
            accepted = [r[1] for r in self.fake.records()
                        if r[0] >= after and r[2] == "*"
                        and r[3].startswith("accept")]
            for conn in accepted:
                asked = self.fake.first(lambda r: r[1] == conn and r[2] == "<"
                                        and r[3] == "hello 7", after)
                answered = self.fake.first(lambda r: r[1] == conn
                                           and r[2] == ">"
                                           and r[3] == "hello 7", after)
                if asked and answered:
                    return conn
            return None
        conn = wait_for(found, BOUND_S + 20,
                        "a fresh connection's hello 7 at the fake")
        self.ok(f"fresh connection c{conn} said hello 7 and was answered")
        return conn

    def tap_reaches(self, conn=None):
        """A cap tap after recovery reaches the fake and is answered ok."""
        since = time.time()
        self.host.command("tap", "tapped")

        def answered():
            got = [r for r in self.fake.records() if r[0] >= since
                   and r[2] == "<" and r[3].split()[0] in ("down", "up", "tap")]
            if not got:
                return None
            line = got[0]
            reply = self.fake.first(lambda r: r[1] == line[1] and r[2] == ">",
                                    line[0])
            return (line, reply) if reply else None
        line, reply = wait_for(answered, 10, "the tap to reach the fake")
        if conn is not None and line[1] != conn:
            raise Failure(f"the tap went out on c{line[1]}, not the "
                          f"recovered connection c{conn}")
        if reply[3] != "ok":
            raise Failure(f"the tap was answered {reply[3]!r}")
        self.ok(f"a tap after recovery reached the fake on c{line[1]} "
                f"({line[3]!r}) and was answered ok")

    def settled(self, case_start):
        state = self.host.state()
        if state["armed"]:
            raise Failure(f"a chord is still armed: {state}")
        if not state["ready"]:
            raise Failure(f"the panel is not ready at the case's end: {state}")
        self.ok(f"no chord armed, gate open (queue {state['queue']}, "
                f"lifecycle {state['lifecycle']})")
        lines = [l for l in self.host.raw_lines()[case_start:]]
        fallbacks = [l for l in lines if FALLBACK in l]
        if fallbacks:
            raise Failure(f"{len(fallbacks)} keycap fallback line(s): "
                          f"{fallbacks[:2]}")
        grand, new = our_warnings(lines)
        # The panel's own `[oskar] …` journal lines (a refused command, an
        # unrecognized reply) are its product messages about the injected
        # fault; the sweep is for the engine's warnings about our code.
        engine = [l for l in grand + new if "[oskar]" not in l]
        if engine:
            for line in engine[:6]:
                print("      warning: " + line[:200])
            raise Failure(f"{len(engine)} QML warning(s) naming our files")
        self.ok("no keycap fallback, no QML warnings naming our files")

    def ready_before(self, timeout=60):
        wait_for(lambda: self.host.state()["ready"] is True, timeout,
                 "the panel to be ready before the next case")

    def begin(self, name):
        self.case = name
        self.ready_before()
        self.fake.fault("clear")
        return len(self.host.raw_lines())


def close_stamp(fake, conn):
    """When connection `conn` ended, and who ended it."""
    record = fake.first(lambda r: r[1] == conn and r[2] == "*" and (
        r[3] == "peer-closed" or r[3].startswith("closed-by-fake")))
    return record


def last_conn(fake):
    accepted = [r[1] for r in fake.records()
                if r[2] == "*" and r[3].startswith("accept")]
    return accepted[-1] if accepted else None


def run_cases(leg):
    host, fake = leg.host, leg.fake

    # ---- the positive control: a chord against a healthy peer ----
    start = leg.begin("control")
    leg.tap_reaches()
    host.command("paste", "paste-started true")
    done = wait_for(lambda: host.stamped("paste-done"), 10,
                    "the control chord's verdict")[-1]
    if done[0] != "true":
        raise Failure(f"the control chord failed against a healthy fake: "
                      f"{done}")
    leg.ok("a paste chord against the healthy fake succeeded")
    leg.settled(start)

    # ---- the peer closes mid-session ----
    start = leg.begin("drop")
    old = last_conn(fake)
    anchor = fake.fault("drop")
    leg.gate_reopened(anchor)
    conn = leg.fresh_hello(anchor)
    if conn == old:
        raise Failure("the recovery reused the dropped connection")
    leg.tap_reaches(conn)
    leg.settled(start)

    # ---- the socket that never answers: only the watchdog can see it ----
    start = leg.begin("mute")
    muted = last_conn(fake)
    since = fake.fault("mute")
    probe = wait_for(lambda: fake.first(
        lambda r: r[1] == muted and r[2] == "<"
        and r[3] in ("ping", "hello 7"), since), 30,
        "the panel's probe to reach the muted connection")
    leg.ok(f"the panel probed the muted c{muted} with {probe[3]!r} "
           f"{probe[0] - since:.1f}s after the mute")
    anchor = probe[0]
    leg.gate_reopened(anchor)
    closed = close_stamp(fake, muted)
    if not closed or closed[3] != "peer-closed":
        raise Failure(f"the muted c{muted} was not torn down by the panel: "
                      f"{closed}")
    waited = closed[0] - anchor
    if waited < HELLO_STALE_S - 0.5:
        raise Failure(f"the panel gave up on the probe after {waited:.1f}s, "
                      f"inside the {HELLO_STALE_S:.0f}s stale window")
    leg.ok(f"the watchdog tore the muted connection down {waited:.1f}s after "
           f"its unanswered probe")
    conn = leg.fresh_hello(anchor)
    leg.tap_reaches(conn)
    leg.settled(start)

    # ---- a hello answered only after the stale window ----
    start = leg.begin("slow-hello")
    slow_ms = int((HELLO_STALE_S + 3 * FAST_TICK_S + 5) * 1000)
    since = fake.fault(f"slow-hello {slow_ms}", "drop")
    slow = wait_for(lambda: fake.first(
        lambda r: r[2] == "<" and r[3] == "hello 7", since), 30,
        "the reconnect's hello to reach the fake")
    anchor = slow[0]
    leg.gate_reopened(anchor, since=since)
    closed = close_stamp(fake, slow[1])
    if not closed or closed[3] != "peer-closed" \
            or closed[0] >= anchor + slow_ms / 1000.0:
        raise Failure(f"the slow-hello c{slow[1]} was not torn down before "
                      f"its {slow_ms} ms reply: {closed}")
    leg.ok(f"the watchdog tore the slow-hello c{slow[1]} down "
           f"{closed[0] - anchor:.1f}s after its hello (reply due at "
           f"{slow_ms / 1000:.0f}s)")
    # The rebuilt socket dials before the old one's close lands, so the
    # search starts at the slow hello (its own connection predates it).
    conn = leg.fresh_hello(anchor)
    leg.tap_reaches(conn)
    leg.settled(start)

    # ---- `err not ready`, twice, then ready ----
    start = leg.begin("not-ready")
    since = fake.fault("not-ready 2", "drop")
    refused = wait_for(lambda: fake.first(
        lambda r: r[2] == ">" and r[3] == "err not ready", since), 30,
        "the fake to refuse a hello as not ready")
    anchor = refused[0]
    opened = leg.gate_reopened(anchor, must_drop=False)
    greeted = fake.first(lambda r: r[2] == ">" and r[3] == "hello 7", anchor)
    refusals = [r for r in fake.records() if r[0] >= since and r[2] == ">"
                and r[3] == "err not ready"]
    if not greeted or opened < greeted[0]:
        raise Failure(f"the gate opened at {opened:.3f} before any hello 7 "
                      f"was answered ({greeted})")
    if len(refusals) != 2:
        raise Failure(f"expected two not-ready refusals, saw {refusals}")
    leg.ok(f"two `err not ready` refusals, then hello 7 on c{greeted[1]}; "
           f"the gate opened only after it")
    leg.tap_reaches()
    leg.settled(start)

    # ---- the peer closes on the configure, before answering it ----
    start = leg.begin("drop-after-configure")
    since = fake.fault("drop-after configure", "drop")
    cut = wait_for(lambda: fake.first(
        lambda r: r[2] == "*" and r[3] == "closed-by-fake drop-after "
        "configure", since), 30, "the reconnect's configure to be cut")
    anchor = cut[0]
    leg.gate_reopened(anchor, must_drop=False)
    conn = leg.fresh_hello(anchor)
    answered = fake.first(lambda r: r[1] == conn and r[2] == ">"
                          and r[3].startswith("configured\t"), anchor)
    if not answered:
        raise Failure(f"the recovered c{conn} never had a configure "
                      "answered")
    leg.ok(f"c{conn} re-sent the cut configure and it was answered "
           f"({answered[3]!r})")
    leg.tap_reaches(conn)
    leg.settled(start)

    # ---- `err too many clients` on the reconnect, then a normal one ----
    start = leg.begin("too-many")
    since = fake.fault("too-many 1", "drop")
    refused = wait_for(lambda: fake.first(
        lambda r: r[2] == "*" and r[3] == "closed-by-fake too-many", since),
        30, "the reconnect to be refused as too many")
    anchor = refused[0]
    leg.gate_reopened(anchor, must_drop=False)
    conn = leg.fresh_hello(anchor)
    leg.tap_reaches(conn)
    leg.settled(start)

    # ---- an injected err on a key line: fail closed, then repair ----
    start = leg.begin("err-injected")
    fake.fault("err down")
    host.command("tap", "tapped")
    injected = wait_for(lambda: fake.first(
        lambda r: r[2] == ">" and r[3] == "err injected"), 10,
        "the injected err")
    leg.gate_reopened(injected[0])
    leg.tap_reaches()
    leg.settled(start)

    # ---- the peer closes with a chord armed ----
    start = leg.begin("drop-mid-chord")
    fake.fault("delay 3000")
    host.command("paste", "paste-started true")
    armed = wait_for(lambda: [a for a in host.stamped("armed")
                              if a[0] == "true"], 5, "the chord to arm")[-1]
    anchor = fake.fault("delay 0", "drop")
    done = wait_for(lambda: [d for d in host.stamped("paste-done")
                             if d[1] >= armed[1]], CHORD_GUARD_S + 3,
                    "the armed chord's verdict after the drop")[-1]
    if done[0] != "false":
        raise Failure(f"a chord whose peer closed reported {done}")
    if done[1] - armed[1] > CHORD_GUARD_S + 1:
        raise Failure(f"the chord's verdict took {done[1] - armed[1]:.1f}s, "
                      f"past the {CHORD_GUARD_S:.0f}s guard")
    leg.ok(f"the armed chord settled failed {done[1] - anchor:.1f}s after "
           f"the drop")
    leg.gate_reopened(anchor, must_drop=False)
    leg.fresh_hello(anchor)
    leg.tap_reaches()
    leg.settled(start)

    # ---- a reply slower than the chord guard ----
    start = leg.begin("chord-guard")
    delay_ms = int((CHORD_GUARD_S + 2) * 1000)
    fake.fault(f"delay {delay_ms}")
    host.command("paste", "paste-started true")
    armed = wait_for(lambda: [a for a in host.stamped("armed")
                              if a[0] == "true"], 5, "the chord to arm")[-1]
    done = wait_for(lambda: [d for d in host.stamped("paste-done")
                             if d[1] >= armed[1]], CHORD_GUARD_S + 4,
                    "the guard's verdict")[-1]
    took = done[1] - armed[1]
    if done[0] != "false":
        raise Failure(f"a chord answered after {delay_ms} ms reported {done}")
    if not CHORD_GUARD_S - 0.5 <= took <= CHORD_GUARD_S + 1.5:
        raise Failure(f"the chord guard fired after {took:.1f}s, not "
                      f"{CHORD_GUARD_S:.0f}s")
    disarmed = [a for a in host.stamped("armed")
                if a[0] == "false" and a[1] >= armed[1]]
    if not disarmed or disarmed[0][1] - armed[1] > CHORD_GUARD_S + 1.5:
        raise Failure(f"the chord stayed armed past the guard: {disarmed}")
    leg.ok(f"the chord guard failed the slow chord after {took:.1f}s and "
           f"disarmed it")
    since = fake.fault("delay 0")
    # The late replies still arrive (and pop their slots) after the guard;
    # whatever the watchdog makes of the slow peer meanwhile, the panel
    # must end ready.
    late = wait_for(lambda: fake.first(
        lambda r: r[2] == ">" and r[3] == "ok", armed[1] + CHORD_GUARD_S),
        delay_ms / 1000 + 5, "the late chord replies to go out")
    leg.ok(f"the late chord replies went out {late[0] - armed[1]:.1f}s after "
           f"the chord armed")
    wait_for(lambda: host.state()["ready"] is True, BOUND_S + delay_ms / 1000,
             "the panel to be ready after the slow replies")
    leg.tap_reaches()
    leg.settled(start)


def main():
    guard()
    state_backup = read_state()
    fake = None
    host = None
    with PrivateRuntime() as runtime:
        try:
            fake = Fake()
            host = Host(runtime.env)
            leg = Leg(host, fake)
            wait_for(lambda: "alive" in host.marker_lines(), 120,
                     "the hosted panel to start")
            host.command("open", "opened")
            wait_for(lambda: host.state()["ready"] is True, 90,
                     "the keyboard to become ready against the fake")
            state = host.state()
            if not state["facts"]:
                raise Failure(f"no keycap facts from the fake: {state}")
            leg.ok(f"the real panel is ready against the fake helper "
                   f"(codes {state['codes']}, facts in hand); bound "
                   f"{BOUND_S:.0f}s")
            baseline = our_warnings(host.raw_lines())
            engine = [l for l in baseline[0] + baseline[1]
                      if "[oskar]" not in l]
            if engine:
                raise Failure(f"QML warnings naming our files at open: "
                              f"{engine[:4]}")
            run_cases(leg)
            host.command("close", "closed")
            total = sum(leg.counts.values())
            print("ok    TRANSPORT FAULTS GREEN: "
                  + ", ".join(f"{k} {v}" for k, v in leg.counts.items())
                  + f" ({total} assertions)")
        finally:
            if host:
                host.close()
            if fake:
                fake.close()
            if state_backup is not None:
                with open(STATE_FILE, "w", encoding="utf-8") as handle:
                    json.dump(state_backup, handle, indent=2)
            elif os.path.exists(STATE_FILE):
                os.unlink(STATE_FILE)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  transport-faults leg: {failure}")
        sys.exit(1)
