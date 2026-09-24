// The helper reply dispatch, driven by scripted line streams: what the
// panel writes and the state it ends in for each reply the helper can
// send. Run with tools/run-tests.sh — no compositor, no display, no
// socket; the lines are the helper's, the writes are read off the
// returned programs.
import QtQml
import "../HelperReplies.js" as Replies
import "../ChordAcks.js" as ChordAcks
import "../KeyboardSession.js" as Session
import "../ModifierReducer.js" as Modifiers
import "../SettleGuard.js" as SettleGuard
import "../LayoutDevices.js" as LayoutDevices
import "harness.js" as T

QtObject {
    // A configure line: rules, model, layouts, variants, options, kb_file,
    // then the group (KeyboardSession.identityOf reads the first seven
    // fields as the keymap identity).
    function configureLine(layouts, group) {
        return ["configure", "evdev", "pc105", layouts, "", "", "",
            String(group)].join("\t")
    }

    function capsLine(gen, group) {
        return "caps\t" + gen + "\t" + group + "\tAD01\u001Ftq\u001FtQ"
    }

    // One keyboard as the helper's `seat` reply carries it: the
    // compositor's own field names.
    function kbd(name, main, group, layout) {
        return { name: name, main: main, active_layout_index: group,
            layout: layout || "us,ua", variant: ",", rules: "evdev",
            model: "pc105", options: "grp:alt_shift_toggle" }
    }

    // The `seat` reply: keyboards, the helper's physical list, kb_file,
    // titles — built with the helper's shape, never by hand-written JSON.
    function seatLine(keyboards, safe, kbFile, titles) {
        return "seat\t" + JSON.stringify({ keyboards: keyboards,
            safe: safe, kb_file: kbFile || "",
            titles: titles || { us: "English (US)", ua: "Ukrainian" } })
    }

    function initialState() {
        return {
            chordAcks: ChordAcks.initial(),
            session: Session.initial(),
            modifierState: Modifiers.initialState(),
            settleGuard: SettleGuard.initial(),
            inputReady: false,
            serviceIncompatible: false,
            capsFactsFailed: false,
            socketReconnected: false,
            startupKeyboards: [],
            startupInventorySeen: false,
            startupKeyboardName: "",
            anchorKeyboardName: "",
            lastLayoutEventDevice: "",
            seatAsk: "idle"
        }
    }

    function with_(state, fields) {
        var out = {}
        for (var k in state) out[k] = state[k]
        for (var f in fields) out[f] = fields[f]
        return out
    }

    // A write the panel makes outside the dispatch (HelperLink's hello and
    // ping, a chord line): it occupies its slot through the choke point.
    function panelSends(state, line) {
        return with_(state, { chordAcks: ChordAcks.sent(state.chordAcks, line) })
    }

    // Keyboard.sendConfigure: the session queues the transaction, then the
    // line goes through the choke point.
    function sendConfigure(state, line) {
        var next = with_(state, {
            session: Session.reduce(state.session,
                { type: "configureSent", payload: line })
        })
        return panelSends(next, line)
    }

    function withLocked(state, names) {
        var mods = Modifiers.initialState()
        for (var i = 0; i < names.length; i++) mods[names[i]] = "locked"
        return with_(state, { modifierState: mods })
    }

    property var ctx: ({ groupCount: 1, capsPositions: "AD01 AD02" })
    property var allActions: []

    // Feeds a line stream, returns the end state and every action in order.
    function feed(state, lines, context) {
        var actions = []
        for (var i = 0; i < lines.length; i++) {
            var step = Replies.dispatch(state, lines[i], context || ctx)
            state = step.state
            actions = actions.concat(step.actions)
        }
        allActions = allActions.concat(actions)
        return { state: state, actions: actions }
    }

    function sends(actions) {
        return actions.filter(function (a) { return a.op === "send" })
            .map(function (a) { return a.line })
    }

    function opsNamed(actions, op) {
        return actions.filter(function (a) { return a.op === op })
    }

    // A panel mid-session: hello answered on a new connection, one
    // configure acked at `gen`, the drawn group's facts in hand, typing on.
    function readyAt(gen) {
        var s = with_(initialState(), { socketReconnected: true })
        s = panelSends(s, "hello " + Session.PROTOCOL_VERSION)
        s = feed(s, ["hello " + Session.PROTOCOL_VERSION, "ok", "ok",
            seatLine([kbd("kbd", true, 0, "us")], ["kbd"])]).state
        s = sendConfigure(s, configureLine("us", 0))
        s = feed(s, ["configured\t" + gen, capsLine(gen, 0)]).state
        return s
    }

    Component.onCompleted: {
        T.test("hello on a new connection resets device-held state, subscribes and reads the seat", function () {
            var s = withLocked(initialState(), ["shift"])
            s.modifierState.caps = true
            s = with_(s, {
                socketReconnected: true,
                capsFactsFailed: true,
                serviceIncompatible: true,
                settleGuard: SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            })
            s = panelSends(s, "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s, ["hello " + Session.PROTOCOL_VERSION])
            // The releases are NOT emitted: the helper already let go
            // when the old socket closed.
            T.deepEqual(sends(r.actions), ["mods 0", "events on", "seat"])
            T.equal(r.state.modifierState.shift, "idle")
            T.equal(r.state.modifierState.caps, true, "Caps is a panel control")
            T.equal(r.state.socketReconnected, false, "the flag is consumed")
            T.equal(r.state.capsFactsFailed, false)
            T.equal(r.state.serviceIncompatible, false)
            T.equal(r.state.settleGuard.armed, false, "the guard's world restarts")
            T.equal(r.state.session.helloOk, true)
            T.equal(r.state.inputReady, false, "hello alone never opens the gate")
            T.deepEqual(r.state.chordAcks.queue.map(function (q) { return q.verb }),
                ["mods", "events", "seat"])
            T.equal(r.state.seatAsk, "asked")
        })

        T.test("the repair timer's re-hello of a live socket resets nothing", function () {
            var s = readyAt(3)
            s = withLocked(s, ["shift"])
            s = sendConfigure(s, configureLine("us,de", 0))
            s = panelSends(s, "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s, ["hello " + Session.PROTOCOL_VERSION])
            T.deepEqual(sends(r.actions), ["seat"],
                "no mods 0 over a live hold, and the subscription holds")
            T.equal(r.state.modifierState.shift, "locked")
            T.equal(r.state.session.queue.length, 1, "the queued configure survives")
            T.equal(r.state.session.ackedGen, 3)
            T.equal(r.state.inputReady, false, "the re-hello still drops the gate")
        })

        T.test("the gate opens only once configured AND the drawn group's facts are in", function () {
            var s = with_(initialState(), { socketReconnected: true })
            s = panelSends(s, "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s, ["hello " + Session.PROTOCOL_VERSION, "ok", "ok"])
            T.equal(r.state.inputReady, false)
            r = feed(r.state, [seatLine([kbd("kbd-a", false, 1), kbd("kbd-b", false, 1)],
                ["kbd-a", "kbd-b"])])
            T.deepEqual(r.state.startupKeyboards, ["kbd-a", "kbd-b"])
            T.equal(r.state.startupKeyboardName, "kbd-a")
            T.equal(r.state.anchorKeyboardName, "kbd-a")
            T.equal(opsNamed(r.actions, "seatFacts").length, 1,
                "the reading reaches the layout ingest")
            T.equal(r.state.seatAsk, "idle")
            T.equal(r.state.inputReady, false)
            s = sendConfigure(r.state, configureLine("us,de", 1))
            r = feed(s, ["configured\t4"], { groupCount: 2, capsPositions: "AD01 AD02" })
            T.deepEqual(sends(r.actions), ["caps 0 AD01 AD02", "caps 1 AD01 AD02"],
                "every group of the install is asked for")
            T.deepEqual(opsNamed(r.actions, "groupConfirmed").map(function (a) {
                return a.group }), [1])
            T.equal(r.state.session.ackedGen, 4)
            T.equal(r.state.inputReady, false, "configured without facts keeps it shut")
            // A pre-fetched group's facts do not answer the drawn group.
            r = feed(r.state, [capsLine(4, 0)])
            T.equal(r.state.inputReady, false)
            T.equal(opsNamed(r.actions, "shareKeymap").length, 1)
            r = feed(r.state, [capsLine(4, 1)])
            T.equal(r.state.inputReady, true, "the drawn group's facts open it")
            // The opening is judged when the action runs, against the live
            // session — a plain set would open a gate the session write
            // itself may have shut (a released key's up dropping the
            // connection). And it only opens: facts never close a gate.
            T.equal(opsNamed(r.actions, "gateOpenIfReady").length, 1)
            T.equal(opsNamed(r.actions, "set").filter(function (x) {
                return x.key === "inputReady" && x.value === true
            }).length, 0, "no unconditional open rides a caps reply")
        })

        T.test("a second inventory keeps the startup keyboard and the anchor", function () {
            var s = with_(initialState(), { anchorKeyboardName: "remembered" })
            var r = feed(s, [seatLine([], ["kbd-a"]), seatLine([], ["kbd-b"])])
            T.deepEqual(r.state.startupKeyboards, ["kbd-b"])
            T.equal(r.state.startupKeyboardName, "kbd-a")
            T.equal(r.state.anchorKeyboardName, "remembered")
        })

        T.test("err not ready reads the seat now and leaves the gate shut", function () {
            var s = with_(initialState(), { socketReconnected: true })
            s = panelSends(s, "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s, ["err not ready"])
            T.deepEqual(r.actions.map(function (a) { return a.op }),
                ["set", "set", "send"])
            T.deepEqual(sends(r.actions), ["seat"])
            T.equal(r.state.inputReady, false)
            T.equal(r.state.serviceIncompatible, false, "not ready is not incompatible")
            T.equal(r.state.session.helloOk, false)
            T.equal(r.state.socketReconnected, true,
                "the flag waits for the hello that answers")
            // The seat answers (a configure follows from the ingest), then
            // the repair timer's next hello is answered: the new-connection
            // reset runs then.
            r = feed(r.state, [seatLine([kbd("kbd", true, 0)], ["kbd"])])
            T.equal(r.state.seatAsk, "idle")
            s = panelSends(r.state, "hello " + Session.PROTOCOL_VERSION)
            r = feed(s, ["hello " + Session.PROTOCOL_VERSION])
            T.deepEqual(sends(r.actions), ["mods 0", "events on", "seat"])
        })

        T.test("err protocol marks the service incompatible until a good hello", function () {
            var s = panelSends(with_(initialState(), { inputReady: true }),
                "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s, ["err protocol 7"])
            T.equal(r.state.serviceIncompatible, true)
            T.equal(r.state.inputReady, false)
            T.deepEqual(sends(r.actions), [])
            // A hello naming another version is the same mismatch.
            var other = feed(initialState(), ["hello 5"])
            T.equal(other.state.serviceIncompatible, true)
            // A configured reply without a generation predates the wire.
            var bare = feed(initialState(), ["configured"])
            T.equal(bare.state.serviceIncompatible, true)
            r = feed(r.state, ["hello " + Session.PROTOCOL_VERSION])
            T.equal(r.state.serviceIncompatible, false)
        })

        T.test("a same-identity ack whose generation jumped is a drain", function () {
            var s = withLocked(readyAt(3), ["shift"])
            s = sendConfigure(s, configureLine("us", 0))
            T.equal(s.session.queue[0].changed, false, "same identity: promised no drain")
            var r = feed(s, ["configured\t5"])
            T.equal(r.state.modifierState.shift, "idle",
                "another client's install drained the lock")
            T.deepEqual(opsNamed(r.actions, "modifiers").map(function (a) {
                return a.event.type }), ["configureDrain"])
            T.deepEqual(sends(r.actions), ["caps 0 AD01 AD02"])
            // Emitted nothing for the drain: the device holds nothing.
            T.equal(sends(r.actions).filter(function (l) {
                return l.indexOf("up ") === 0 }).length, 0)
        })

        T.test("a same-identity ack at the same generation keeps the lock", function () {
            var s = withLocked(readyAt(3), ["shift"])
            s = sendConfigure(s, configureLine("us", 0))
            var r = feed(s, ["configured\t3"])
            T.equal(r.state.modifierState.shift, "locked")
            T.equal(opsNamed(r.actions, "modifiers").length, 0)
            T.equal(r.state.inputReady, true, "facts for gen 3 still answer")
        })

        T.test("a changed-keymap ack drains whatever the generation says", function () {
            var s = withLocked(readyAt(3), ["ctrl"])
            s = sendConfigure(s, configureLine("de", 0))
            var r = feed(s, ["configured\t4"])
            T.equal(r.state.modifierState.ctrl, "idle")
            T.equal(r.state.inputReady, false, "gen 4 has no facts yet")
        })

        T.test("connection lost mid-chord fails the chord exactly once", function () {
            var s = readyAt(3)
            var verdicts = []
            var done = function (ok) { verdicts.push(ok) }
            var acks = ChordAcks.chordStart(s.chordAcks)
            var chord = ["down LCTL", "tap AB04", "up LCTL"]
            for (var i = 0; i < chord.length; i++) acks = ChordAcks.sent(acks, chord[i])
            s = with_(s, { chordAcks: ChordAcks.chordArmed(acks, done) })
            var ok = feed(s, ["ok"])
            T.equal(opsNamed(ok.actions, "chordVerdict").length, 0,
                "the Ctrl press's ok is not the verdict")
            var lost = Replies.connectionLost(ok.state)
            T.deepEqual(lost.actions.map(function (a) { return a.op }),
                ["chordTimedOut", "set", "set"])
            T.deepEqual(lost.state.chordAcks, ChordAcks.initial(), "the ledger is drained")
            // The new connection's traffic — and a straggler — settle nothing.
            var s2 = with_(lost.state, { socketReconnected: true })
            s2 = panelSends(s2, "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s2, ["hello " + Session.PROTOCOL_VERSION, "ok", "ok", "ok", "ok"])
            T.equal(opsNamed(r.actions, "chordVerdict").length, 0)
            T.equal(opsNamed(r.actions, "chordTimedOut").length, 0)
            // No chord armed: a drop has nothing to fail.
            var idle = Replies.connectionLost(readyAt(3))
            T.deepEqual(idle.actions.map(function (a) { return a.op }), ["set", "set"])
        })

        T.test("a pong popped inside a chord region poisons the chord", function () {
            function chordAfter(state, pingInsideRegion) {
                var acks = state.chordAcks
                if (!pingInsideRegion) acks = ChordAcks.sent(acks, "ping")
                acks = ChordAcks.chordStart(acks)
                if (pingInsideRegion) acks = ChordAcks.sent(acks, "ping")
                acks = ChordAcks.sent(acks, "down LCTL")
                acks = ChordAcks.sent(acks, "tap AB04")
                acks = ChordAcks.sent(acks, "up LCTL")
                return with_(state, { chordAcks: ChordAcks.chordArmed(acks, function () {}) })
            }
            var inside = feed(chordAfter(readyAt(3), true), ["pong", "ok", "ok", "ok"])
            var verdict = opsNamed(inside.actions, "chordVerdict")
            T.equal(verdict.length, 1)
            T.equal(verdict[0].success, false, "a non-ok inside the region poisons")
            T.equal(inside.state.inputReady, true, "pong itself is not drift")
            T.equal(opsNamed(inside.actions, "warn").length, 0)
            var before = feed(chordAfter(readyAt(3), false), ["pong", "ok", "ok", "ok"])
            verdict = opsNamed(before.actions, "chordVerdict")
            T.equal(verdict.length, 1)
            T.equal(verdict[0].success, true, "pre-chord traffic is not the chord's")
        })

        T.test("the verdict is the first action, ahead of the route", function () {
            // The executor runs pop before route so the completion
            // callback sees the world before the reply's own effects.
            var s = readyAt(3)
            var acks = ChordAcks.chordStart(s.chordAcks)
            acks = ChordAcks.sent(acks, "tap AB04")
            s = with_(s, { chordAcks: ChordAcks.chordArmed(acks, function () {}) })
            var r = feed(s, ["err not ready"])
            T.deepEqual(r.actions.map(function (a) { return a.op }),
                ["set", "chordVerdict", "set", "send"])
            var popped = Replies.pop(s, "err not ready")
            T.equal(popped.verb, "tap")
            T.equal(popped.reply, "err not ready")
        })

        T.test("err too many clients fails closed as an unrecognized err", function () {
            // The helper writes it unsolicited on accept and closes; there
            // is no dedicated arm, so it takes the fail-closed default.
            var r = feed(with_(initialState(), { inputReady: true }),
                ["err too many clients"])
            T.equal(r.state.inputReady, false)
            T.equal(r.state.serviceIncompatible, false, "a full helper is not incompatible")
            T.deepEqual(opsNamed(r.actions, "warn").map(function (a) { return a.args }),
                [["[oskar] unrecognized reply:", "err too many clients"]])
            T.deepEqual(sends(r.actions), [])
        })

        T.test("err bad group settles the verb the FIFO names", function () {
            var s = readyAt(3)
            s = panelSends(s, "caps 1 AD01 AD02")
            s = sendConfigure(s, configureLine("us", 2))
            // First pop: the pre-fetch. The drawn group's facts are current,
            // so the gate stays open and the configure stays queued.
            var r = feed(s, ["err bad group"])
            T.equal(r.state.session.queue.length, 1, "the configure is not the one refused")
            T.equal(r.state.capsFactsFailed, false)
            T.equal(r.state.inputReady, true)
            T.equal(opsNamed(r.actions, "error").length, 1)
            // Second pop: the configure. Its entry settles, nothing lifts.
            var locked = withLocked(r.state, ["shift"])
            r = feed(locked, ["err bad group"])
            T.equal(r.state.session.queue.length, 0, "the configure settles failed")
            T.equal(r.state.modifierState.shift, "locked", "no drain before install")
            T.equal(r.state.capsFactsFailed, false)
            T.deepEqual(sends(r.actions), [])
        })

        T.test("err bad group for a caps request of the drawn world gates", function () {
            var s = readyAt(3)
            s = sendConfigure(s, configureLine("us", 0))
            s = feed(s, ["configured\t4"]).state
            // gen 4 has no facts; the caps request for group 0 is refused.
            var r = feed(s, ["err bad group"])
            T.equal(r.state.capsFactsFailed, true)
            T.equal(r.state.inputReady, false)
            T.equal(opsNamed(r.actions, "error").length, 0)
        })

        T.test("an unattributable err bad group takes the caps-shaped reading", function () {
            var s = sendConfigure(readyAt(3), configureLine("us", 0))
            // The configure's slot is gone (a bypassed write): the reply pops
            // nothing and must not drop the queued configure.
            s = with_(s, { chordAcks: ChordAcks.initial() })
            var r = feed(s, ["err bad group"])
            T.equal(r.state.session.queue.length, 1)
            T.equal(r.state.capsFactsFailed, false)
            T.equal(r.state.inputReady, true)
        })

        T.test("err cannot configure keymap lifts every lock and settles drained", function () {
            var s = withLocked(readyAt(3), ["ctrl", "shift"])
            s.modifierState.caps = true
            s = sendConfigure(s, configureLine("de", 0))
            var r = feed(s, ["err cannot configure keymap"])
            T.deepEqual(sends(r.actions), ["up LCTL", "up LFSH", "mods 0"])
            T.equal(r.state.modifierState.ctrl, "idle")
            T.equal(r.state.modifierState.shift, "idle")
            T.equal(r.state.modifierState.caps, true)
            T.equal(r.state.session.queue.length, 0)
            T.equal(r.state.inputReady, false)
        })

        T.test("caps replies: unreadable refuses the world, stale is dropped", function () {
            var s = readyAt(3)
            var bad = feed(s, ["caps\t3\t0\tAD01\u001Fzq"])
            T.equal(bad.state.capsFactsFailed, true)
            T.equal(bad.state.inputReady, false)
            T.equal(opsNamed(bad.actions, "error").length, 1)
            var stale = feed(with_(s, { capsFactsFailed: true }), [capsLine(2, 0)])
            T.equal(stale.state.capsFactsFailed, true, "a dropped reply clears nothing")
            T.equal(opsNamed(stale.actions, "shareKeymap").length, 0)
        })

        T.test("status-only errs and bare oks leave the gate alone", function () {
            var s = readyAt(3)
            var r = feed(s, ["err key held", "err not holding", "err unknown command", "ok"])
            T.equal(r.state.inputReady, true)
            T.equal(opsNamed(r.actions, "warn").length, 3)
            var drift = feed(s, ["err something new"])
            T.equal(drift.state.inputReady, false, "unknown errs fail closed")
        })

        T.test("event lines never pop a slot, in or out of a chord", function () {
            var s = readyAt(3)
            s = sendConfigure(s, configureLine("us", 0))
            var before = JSON.stringify(s.chordAcks)
            var r = feed(s, ["event\tlayout\tkbd\t1", "event\tdevices",
                "event\tsomething-newer\tx"])
            // The ledger moved only by the seat ask the events made.
            T.deepEqual(r.state.chordAcks.queue.map(function (q) { return q.verb }),
                ["configure", "seat"])
            T.equal(r.state.session.queue.length, 1, "the configure is still owed")
            T.equal(r.state.inputReady, true, "an event is never drift")
            T.equal(opsNamed(r.actions, "warn").length, 0)
            // The configure's reply still settles the configure.
            r = feed(r.state, ["configured\t3"])
            T.equal(r.state.session.queue.length, 0)
            // Popping an event in isolation touches nothing.
            var popped = Replies.pop(s, "event\tdevices")
            T.equal(JSON.stringify(popped.state.chordAcks), before)
            T.deepEqual(popped.actions, [])
            T.equal(popped.verb, "")
            // Inside a chord region an event is neither the verdict nor
            // a poison: the chord's own oks decide.
            var acks = ChordAcks.chordStart(readyAt(3).chordAcks)
            acks = ChordAcks.sent(acks, "down LCTL")
            acks = ChordAcks.sent(acks, "up LCTL")
            var chord = with_(readyAt(3), { chordAcks: ChordAcks.chordArmed(acks, function () {}) })
            var c = feed(chord, ["ok", "event\tlayout\tkbd\t0", "ok"])
            var verdict = opsNamed(c.actions, "chordVerdict")
            T.equal(verdict.length, 1)
            T.equal(verdict[0].success, true, "an event is not a non-ok reply")
            // An event after `events off` is legal and routed the same way:
            // by its prefix, never by the panel's own subscription state.
            T.equal(Replies.isEvent("event\tdevices"), true)
            T.equal(Replies.isEvent("seat\t{}"), false)
        })

        T.test("event layout records who moved and asks the seat, coalesced", function () {
            var s = readyAt(3)
            var r = feed(s, ["event\tlayout\tkbd-b\t1"])
            T.equal(r.state.lastLayoutEventDevice, "kbd-b",
                "recorded before the reading it triggers")
            T.deepEqual(sends(r.actions), ["seat"])
            T.equal(r.state.seatAsk, "asked")
            // A burst while the ask is out: no second line, one repeat owed.
            r = feed(r.state, ["event\tlayout\tkbd-a\t1", "event\tdevices"])
            T.deepEqual(sends(r.actions), [])
            T.equal(r.state.seatAsk, "again")
            T.equal(r.state.lastLayoutEventDevice, "kbd-a", "the newest mover")
            // The answer lands and the owed ask goes out once.
            r = feed(r.state, [seatLine([kbd("kbd-a", false, 1)], ["kbd-a"])])
            T.deepEqual(sends(r.actions), ["seat"])
            T.equal(r.state.seatAsk, "asked")
            r = feed(r.state, [seatLine([kbd("kbd-a", false, 1)], ["kbd-a"])])
            T.deepEqual(sends(r.actions), [])
            T.equal(r.state.seatAsk, "idle")
            // A device-less layout event still asks; it names nobody.
            r = feed(r.state, ["event\tlayout"])
            T.equal(r.state.lastLayoutEventDevice, "kbd-a")
            T.deepEqual(sends(r.actions), ["seat"])
            // The panel's own wish rides the same coalescer.
            var wanted = Replies.seatWanted(r.state)
            T.deepEqual(sends(wanted.actions), [])
            T.equal(wanted.state.seatAsk, "again")
        })

        T.test("event devices asks the seat, and the facts reach the ingest", function () {
            var r = feed(readyAt(3), ["event\tdevices"])
            T.deepEqual(sends(r.actions), ["seat"])
            T.equal(r.state.lastLayoutEventDevice, "", "hotplug names no mover")
            r = feed(r.state, [seatLine([kbd("kbd-a", false, 0), kbd("kbd-b", true, 1)],
                ["kbd-a", "kbd-b"], "/home/u/my.xkb")])
            T.deepEqual(r.state.startupKeyboards, ["kbd-a", "kbd-b"], "hotplug refreshes the list")
            var facts = opsNamed(r.actions, "seatFacts")
            T.equal(facts.length, 1)
            T.equal(facts[0].kbFile, "/home/u/my.xkb")
            T.deepEqual(facts[0].titles, { us: "English (US)", ua: "Ukrainian" })
        })

        T.test("a seat reply parses into the inventory the ingest consumed", function () {
            // The eight keys the jq projection kept, in the compositor's
            // names; anything else the helper adds stays out.
            var extra = kbd("at-translated-set-2-keyboard", true, 1)
            extra.address = "0x1"
            var seat = Replies.parseSeat(seatLine([extra], ["at-translated-set-2-keyboard"],
                "", { us: "English (US)" }))
            T.deepEqual(Object.keys(seat.devices[0]).sort(), ["active_layout_index",
                "layout", "main", "model", "name", "options", "rules", "variant"])
            T.equal(seat.devices[0].active_layout_index, 1)
            T.equal(seat.devices[0].main, true)
            T.equal(seat.kbFile, "", "an unset kb_file is empty")
            T.deepEqual(seat.safe, ["at-translated-set-2-keyboard"])
            // Unreadable documents are refused, never read as empty: an
            // empty kb_file would forget the user's own keymap.
            T.equal(Replies.parseSeat("seat\t{not json"), null)
            T.equal(Replies.parseSeat("seat\t{\"keyboards\":[]}"), null)
            T.equal(Replies.parseSeat("seatx\t{}"), null)
            var bad = feed(panelSends(with_(readyAt(3), { seatAsk: "asked" }), "seat"),
                ["seat\t{not json"])
            T.equal(opsNamed(bad.actions, "seatFacts").length, 0)
            T.equal(opsNamed(bad.actions, "warn").length, 1)
            T.equal(bad.state.inputReady, true, "the gate is not the seat's")
            T.equal(bad.state.seatAsk, "idle")
        })

        T.test("an event-layout reading is judged by the same tiers and settle guard", function () {
            // The raw compositor event fed two things: who moved (to
            // LayoutDevices.select) and a re-read (whose group the settle
            // guard judges). The helper's event feeds both, through the
            // dispatch, into the same calls the ingest makes.
            var s = readyAt(3)
            // A diverged seat: the vkb holds main, the typist moved to 1,
            // its sibling sleeps on 0; the anchor is the typist.
            s = with_(s, { anchorKeyboardName: "kbd-a",
                settleGuard: SettleGuard.decide(SettleGuard.initial(), 0, 1000).state })
            var r = feed(s, ["event\tlayout\tkbd-a\t1"])
            r = feed(r.state, [seatLine([kbd("kbd-a", false, 1), kbd("kbd-b", false, 0),
                kbd("hl-virtual-keyboard", true, 0)], ["kbd-a", "kbd-b"])])
            var facts = opsNamed(r.actions, "seatFacts")[0]
            var picked = LayoutDevices.select(facts.devices, r.state.anchorKeyboardName,
                r.state.startupKeyboards, 0, r.state.lastLayoutEventDevice)
            T.equal(picked.reading.name, "kbd-a", "the mover answers, not the vote")
            T.equal(picked.group, 1)
            // Inside the post-reconnect window an uncommanded flip is held;
            // the same reading a quiesce later is followed.
            var held = SettleGuard.decide(r.state.settleGuard, picked.group, 2000)
            T.equal(held.follow, false)
            T.equal(held.held, 0)
            var later = SettleGuard.decide(held.state, picked.group,
                2000 + SettleGuard.QUIESCE_MS)
            T.equal(later.follow, true)
            // Without the event the sleeper-majority tie-break answers.
            var unmoved = LayoutDevices.select(facts.devices, "kbd-a",
                ["kbd-a", "kbd-b"], 0, "")
            T.equal(unmoved.group, 0)
        })

        T.test("err no seat backend is inert: a warn, no gate, one fallback configure", function () {
            var s = with_(initialState(), { socketReconnected: true })
            s = panelSends(s, "hello " + Session.PROTOCOL_VERSION)
            var r = feed(s, ["hello " + Session.PROTOCOL_VERSION, "ok", "ok",
                "err no seat backend"])
            T.equal(opsNamed(r.actions, "warn").length, 1)
            T.equal(opsNamed(r.actions, "configureUnseated").length, 1,
                "typing still needs one configure")
            T.equal(opsNamed(r.actions, "seatFacts").length, 0)
            T.equal(r.state.serviceIncompatible, false)
            T.equal(r.state.seatAsk, "idle")
            // A seat-verb refusal the FIFO cannot attribute (a bypassed
            // write) is still the seat's, never typing drift.
            r = feed(readyAt(3), ["err no seat backend", "err seat refused no such device",
                "err share not applied"])
            T.equal(r.state.inputReady, true)
            T.equal(opsNamed(r.actions, "warn").length, 3)
            // Mid-session (a configure already acked) there is no second one.
            var ready = panelSends(with_(readyAt(3), { seatAsk: "asked" }), "seat")
            r = feed(ready, ["err no seat backend"])
            T.equal(opsNamed(r.actions, "configureUnseated").length, 0)
            T.equal(r.state.inputReady, true, "typing is not the seat's")
            // A switch refused the same way: one warn, the gate stands.
            var sw = panelSends(readyAt(3), "switch\tkbd\t1")
            r = feed(sw, ["err no seat backend"])
            T.equal(r.state.inputReady, true)
            T.deepEqual(opsNamed(r.actions, "warn").map(function (a) { return a.args[0] }),
                ["[oskar] the helper refused `switch`:"])
            T.equal(opsNamed(r.actions, "configureUnseated").length, 0)
            // Any other seat refusal: a warn, no reading, no gate.
            r = feed(panelSends(with_(readyAt(3), { seatAsk: "asked" }), "seat"),
                ["err seat unreachable"])
            T.equal(r.state.inputReady, true)
            T.equal(opsNamed(r.actions, "warn").length, 1)
            T.equal(opsNamed(r.actions, "configureUnseated").length, 0)
            // A share refused for want of a backend: the verdict, no gate.
            var sh = panelSends(readyAt(3), "share\t/run/user/1000/oskar/keymap.xkb")
            r = feed(sh, ["err no seat backend"])
            T.equal(r.state.inputReady, true)
            T.deepEqual(opsNamed(r.actions, "shareFinished"),
                [{ op: "shareFinished", ok: false, reply: "err no seat backend" }])
        })

        T.test("a share verdict is the run's, ok or the refusal it reports", function () {
            var sh = panelSends(readyAt(3), "share\t/run/user/1000/oskar/keymap.xkb")
            var ok = feed(sh, ["ok"])
            T.deepEqual(opsNamed(ok.actions, "shareFinished"),
                [{ op: "shareFinished", ok: true, reply: "" }])
            var timedOut = feed(sh, ["err share timed out"])
            T.deepEqual(opsNamed(timedOut.actions, "shareFinished"),
                [{ op: "shareFinished", ok: false, reply: "err share timed out" }])
            T.equal(timedOut.state.inputReady, true, "a share failure never gates typing")
            T.equal(opsNamed(timedOut.actions, "warn").length, 0,
                "the ladder, not the dispatch, says it")
            // A bare ok that answers anything else is not a share verdict.
            var other = feed(panelSends(readyAt(3), "tap AB04"), ["ok"])
            T.equal(opsNamed(other.actions, "shareFinished").length, 0)
        })

        T.test("the steps never mutate the state they are given", function () {
            var s = withLocked(readyAt(3), ["shift"])
            s = sendConfigure(s, configureLine("de", 0))
            var before = JSON.stringify(s)
            Replies.dispatch(s, "err cannot configure keymap", ctx)
            Replies.dispatch(s, "configured\t4", ctx)
            Replies.dispatch(s, "hello " + Session.PROTOCOL_VERSION, ctx)
            Replies.connectionLost(s)
            T.equal(JSON.stringify(s), before)
        })

        T.test("every action the suite saw is one the executor knows", function () {
            var known = ["set", "session", "modifiers", "settleGuardConnected",
                "gateFromSession", "gateOpenIfReady", "send", "chordVerdict", "chordTimedOut",
                "groupConfirmed", "seatFacts", "configureUnseated", "shareKeymap",
                "shareFinished", "log", "warn", "error"]
            for (var i = 0; i < allActions.length; i++) {
                var a = allActions[i]
                if (known.indexOf(a.op) === -1) T.fail("unknown op " + a.op)
                if (a.op === "set" && Replies.STATE_KEYS.indexOf(a.key) === -1)
                    T.fail("unknown state key " + a.key)
            }
            T.equal(allActions.length > 0, true)
        })

        Qt.exit(T.report("helper replies"))
    }
}
