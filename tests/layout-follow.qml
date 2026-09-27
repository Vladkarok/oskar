// Which group the panel follows as the seat moves under it: the helper's
// layout events and seat readings, through the reply dispatch, into the
// same three decisions Keyboard.ingestSeatFacts makes (LayoutDevices.select,
// the anchor it learns, the settle guard). Nothing on the host loads
// Keyboard.qml, so `ingest` below restates that wiring; the modules it
// calls are the real ones.
//
// The replay is the owner's seat as captured on 2026-09-27
// (.scratch/dev-ease/evidence/altshift-capture-2026-09-27.log): fcitx5's
// virtual keyboard holds `main` for good, the anchor was seeded as
// at-translated, and every Alt+Shift moved the ITE (8176) keyboard alone.
//
// Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../HelperReplies.js" as Replies
import "../ChordAcks.js" as ChordAcks
import "../KeyboardSession.js" as Session
import "../ModifierReducer.js" as Modifiers
import "../SettleGuard.js" as SettleGuard
import "../LayoutDevices.js" as LayoutDevices
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        var at = "at-translated-set-2-keyboard"
        var ite76 = "ite-tech.-inc.-ite-device(8176)-keyboard"
        var ite95 = "ite-tech.-inc.-ite-device(8295)-keyboard"
        var fcitx = "hl-virtual-keyboard-fcitx5"
        var ours = "hl-virtual-keyboard-oskar-daemon"
        var SAFE = [at, ite76, ite95]
        // Every keyboard the owner's `hyprctl devices` lists, in its order.
        var NAMES = ["video-bus", ite95,
            "ite-tech.-inc.-ite-device(8176)-wireless-radio-control", ite76,
            "ideapad-extra-buttons", "video-bus-1", "power-button",
            "power-button-1", at, "razer-razer-deathadder-v3-keyboard",
            "razer-razer-deathadder-v3", fcitx, ours]

        // 18:48:00.000 is zero; the capture's times are milliseconds past it.
        function seat(groups, main) {
            var all = {}
            for (var i = 0; i < NAMES.length; i++) all[NAMES[i]] = 0
            for (var name in groups) all[name] = groups[name]
            return { groups: all, main: main || fcitx }
        }

        function seatLine(s) {
            return "seat\t" + JSON.stringify({
                keyboards: NAMES.map(function (name) {
                    return { name: name, main: name === s.main,
                        active_layout_index: s.groups[name], layout: "us,ua",
                        variant: ",", rules: "evdev", model: "pc105",
                        options: "grp:alt_shift_toggle" }
                }),
                safe: SAFE, kb_file: "",
                titles: { us: "English (US)", ua: "Ukrainian" }
            })
        }

        // A panel mid-session: its reply state, the group it follows, the
        // remembered group (persisted from configure acks), and a log.
        function panel(s, anchor, remembered) {
            return {
                seat: s,
                state: {
                    chordAcks: ChordAcks.initial(), session: Session.initial(),
                    modifierState: Modifiers.initialState(),
                    settleGuard: SettleGuard.initial(), inputReady: true,
                    serviceIncompatible: false, capsFactsFailed: false,
                    socketReconnected: false, startupKeyboards: SAFE,
                    startupInventorySeen: true, startupKeyboardName: SAFE[0],
                    anchorKeyboardName: anchor, lastLayoutEventDevice: "",
                    lastLayoutEventCommanded: false, lastSeatDevices: null,
                    seatAsk: "idle"
                },
                remembered: remembered,
                acksLag: false,
                group: -1,
                switchSet: [],
                holds: 0,
                readings: []
            }
        }

        function ctx(now) {
            return { groupCount: 2, capsPositions: "AD01", now: now }
        }

        // Keyboard.ingestSeatFacts' decisions, in its order.
        function ingest(m, facts, now) {
            var picked = LayoutDevices.select(facts.devices,
                m.state.anchorKeyboardName, m.state.startupKeyboards,
                m.remembered, m.state.lastLayoutEventDevice,
                { previous: facts.previous,
                  commanded: m.state.lastLayoutEventCommanded })
            m.switchSet = picked.switchSet
            if (picked.typing) m.state.anchorKeyboardName = picked.typing
            if (!picked.reading) return
            var settle = SettleGuard.decide(m.state.settleGuard, picked.group, now)
            m.state.settleGuard = settle.state
            if (!settle.follow) m.holds += 1
            var group = settle.follow ? picked.group : settle.held
            m.readings.push(group)
            if (group === m.group) return
            m.group = group
            // The configure: the helper's virtual keyboard moves to the
            // group (fcitx5's follows it), and the compositor announces
            // both — neither asks anything.
            m.seat.groups[ours] = group
            m.seat.groups[fcitx] = group
            line(m, "event\tlayout\t" + ours + "\t" + group, now)
            line(m, "event\tlayout\t" + fcitx + "\t" + group, now)
            if (!m.acksLag) m.remembered = group
        }

        function line(m, text, now) {
            var r = Replies.dispatch(m.state, text, ctx(now))
            m.state = r.state
            var facts = r.actions.filter(function (a) { return a.op === "seatFacts" })
            for (var i = 0; i < facts.length; i++) ingest(m, facts[i], now)
            return r
        }

        // The helper answers every outstanding seat ask with the seat as
        // it stands.
        function drain(m, now) {
            var guard = 0
            while (m.state.seatAsk !== "idle" && guard++ < 10)
                line(m, seatLine(m.seat), now)
        }

        // The compositor moves one keyboard and announces it.
        function announce(m, name, group, now) {
            m.seat.groups[name] = group
            line(m, "event\tlayout\t" + name + "\t" + group, now)
        }

        function move(m, name, group, now) {
            announce(m, name, group, now)
            drain(m, now)
        }

        // The panel's language button: record the command, then the loop
        // moves each device of the switch set that is not already there,
        // one at a time, each announced and read before the next lands —
        // the worst case for telling the echo from a keyboard moving alone.
        function click(m, group, now) {
            m.state.settleGuard = SettleGuard.commanded(m.state.settleGuard,
                group, now, m.switchSet)
            var set = m.switchSet.slice()
            for (var i = 0; i < set.length; i++) {
                if (m.seat.groups[set[i]] !== group)
                    move(m, set[i], group, now + 5 + 40 * i)
            }
        }

        function establish(m, now) {
            m.state = Replies.seatWanted(m.state).state
            drain(m, now)
        }

        function safeGroups(m) {
            return SAFE.map(function (name) { return m.seat.groups[name] })
        }

        T.test("the capture, replayed: every lone Alt+Shift is followed, the click's echoes never re-anchor", function () {
            // 18:48:17.812: 8295 on 1, 8176 on 0, at-translated on 1; the
            // panel reads 1 (remembered) with at-translated as its anchor.
            var s = seat({})
            s.groups[ite95] = 1
            s.groups[at] = 1
            s.groups[ours] = 1
            var m = panel(s, at, 1)
            establish(m, 0)
            T.equal(m.group, 1, "the establishing reading")

            // Six toggles of the 8176 keyboard, each alone, each trailed by
            // fcitx5's virtual keyboard following it.
            var toggles = [[23540, 1], [23988, 0], [36866, 1], [38723, 0],
                [40366, 1], [42144, 0]]
            var followed = []
            for (var i = 0; i < toggles.length; i++) {
                move(m, ite76, toggles[i][1], toggles[i][0])
                announce(m, fcitx, toggles[i][1], toggles[i][0] + 3)
                followed.push(m.group)
            }
            T.deepEqual(followed, [1, 0, 1, 0, 1, 0])
            T.equal(m.state.anchorKeyboardName, ite76, "the toggled keyboard is the anchor")
            T.equal(m.holds, 0)

            // 18:48:47.475: a burst from outside moves everything that is
            // not on 1 yet — pseudo-devices included.
            var burst = [["video-bus", 47475], [fcitx, 47477],
                ["ite-tech.-inc.-ite-device(8176)-wireless-radio-control", 47483],
                [ite76, 47487], ["ideapad-extra-buttons", 47490],
                ["video-bus-1", 47498], ["power-button", 47502],
                ["power-button-1", 47505], ["razer-razer-deathadder-v3-keyboard", 47513],
                ["razer-razer-deathadder-v3", 47522]]
            for (var b = 0; b < burst.length; b++) move(m, burst[b][0], 1, burst[b][1])
            T.equal(m.group, 1, "the seat went to 1 and so did the panel")
            T.deepEqual(safeGroups(m), [1, 1, 1])

            // 18:48:48.121: the language button, to 0. Its loop moves the
            // three keyboards one by one, at-translated last, and the panel
            // reads the seat between every two moves.
            var anchorsDuring = []
            m.state.settleGuard = SettleGuard.commanded(m.state.settleGuard, 0,
                48100, m.switchSet)
            var loop = [[ite95, 48125], [ite76, 48134], [at, 48231]]
            for (var c = 0; c < loop.length; c++) {
                move(m, loop[c][0], 0, loop[c][1])
                anchorsDuring.push(m.state.anchorKeyboardName)
            }
            T.equal(m.group, 0, "the reading is the commanded group")
            T.deepEqual(anchorsDuring, [ite76, ite76, ite76],
                "no echo re-anchored — not even at-translated, which came alone and last")
            T.equal(m.holds, 0)

            // 18:49:08.308 onwards: the toggles resume, and are followed.
            var again = [[68308, 1], [68743, 0], [69103, 1], [69253, 0]]
            var after = []
            for (var j = 0; j < again.length; j++) {
                move(m, ite76, again[j][1], again[j][0])
                after.push(m.group)
            }
            T.deepEqual(after, [1, 0, 1, 0])
        })

        T.test("after a followed toggle the seat is diverged, and the next click reunites it", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, ite76, 1, 20000)
            T.equal(m.group, 1)
            // The panel follows; it issues no switch for the others.
            T.deepEqual(safeGroups(m), [0, 1, 0], "diverged: only the toggled keyboard moved")
            // The button's next group from 1 is 0 — every keyboard in the
            // set goes there, and the echo does not flip the panel.
            click(m, (m.group + 1) % 2, 25000)
            T.deepEqual(safeGroups(m), [0, 0, 0], "reunited")
            T.equal(m.group, 0)
            T.equal(m.state.anchorKeyboardName, ite76)
            // And a click the other way moves all three together.
            click(m, 1, 30000)
            T.deepEqual(safeGroups(m), [1, 1, 1])
            T.equal(m.group, 1)
            T.equal(m.state.anchorKeyboardName, ite76)
        })

        T.test("the helper's own virtual keyboard moving after a configure is never an anchor, never a flip", function () {
            // The configure's ack lags the reading here: a reading that
            // raced it once answered the remembered group from before the
            // follow, and the panel undid its own follow.
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            m.acksLag = true
            move(m, ite76, 1, 20000)
            T.equal(m.group, 1)
            T.equal(m.remembered, 0, "the ack has not landed")
            // The helper's virtual keyboard moved and holds `main` for a
            // moment; its own event asked nothing. A reading taken anyway
            // (hotplug, the settle re-read) must not move the panel.
            m.seat.main = ours
            var r = line(m, "event\tlayout\t" + ours + "\t1", 20050)
            T.equal(r.actions.filter(function (a) { return a.op === "send" }).length, 0,
                "the helper's own echo asks nothing")
            line(m, "event\tdevices", 20060)
            drain(m, 20060)
            T.equal(m.group, 1, "no flip back")
            T.equal(m.state.anchorKeyboardName, ite76, "the helper's device is never the anchor")
            T.equal(m.state.lastLayoutEventDevice, ite76)
        })

        T.test("a lone mover the helper did not identify is ignored", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            // A mouse's keyboard interface: typed by name, never identified.
            move(m, "razer-razer-deathadder-v3-keyboard", 1, 20000)
            T.equal(m.group, 0)
            T.equal(m.state.anchorKeyboardName, at)
            // Pseudo-devices and virtual keyboards ask nothing at all.
            var noise = ["power-button", "video-bus", fcitx, ours]
            for (var i = 0; i < noise.length; i++) {
                m.seat.groups[noise[i]] = 1
                var r = line(m, "event\tlayout\t" + noise[i] + "\t1", 21000 + i)
                T.equal(r.actions.filter(function (a) { return a.op === "send" }).length, 0,
                    noise[i] + " asked the seat")
            }
            T.equal(m.group, 0)
            T.equal(m.state.anchorKeyboardName, at)
        })

        T.test("a burst that moved a sleeping twin with the real keyboard is not re-anchored", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            // Both announced before the one reading that sees them.
            announce(m, ite95, 1, 20000)
            announce(m, ite76, 1, 20002)
            drain(m, 20002)
            T.equal(m.state.anchorKeyboardName, at, "not re-anchored")
            T.equal(m.group, 0, "the existing tiers answer: consensus + remembered")
        })

        T.test("a lone mover inside the settle window is held, then followed after the re-read", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, ite76, 1, 2000)
            T.equal(m.holds, 1, "held inside the post-reconnect window")
            T.equal(m.group, 0)
            T.equal(m.state.anchorKeyboardName, ite76, "the anchor is learned; the group waits")
            // The keyboard re-reads once after the quiesce interval.
            m.state = Replies.seatWanted(m.state).state
            drain(m, 2000 + SettleGuard.QUIESCE_MS + 100)
            T.equal(m.group, 1, "followed once the flip persisted")
            T.equal(m.holds, 1)
        })

        T.test("two keyboards toggled one after the other: the anchor moves with each", function () {
            var m = panel(seat({}), ite95, 0)
            establish(m, 0)
            var steps = [[ite76, 1], [at, 1], [at, 0], [ite76, 0], [ite95, 1]]
            var anchors = []
            var groups = []
            for (var i = 0; i < steps.length; i++) {
                move(m, steps[i][0], steps[i][1], 20000 + 1000 * i)
                anchors.push(m.state.anchorKeyboardName)
                groups.push(m.group)
            }
            T.deepEqual(anchors, [ite76, at, at, ite76, ite95])
            T.deepEqual(groups, [1, 1, 0, 0, 1])
        })

        Qt.exit(T.report("layout follow"))
    }
}
