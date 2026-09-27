// Which group the panel follows as the seat moves under it: the helper's
// layout events and seat readings, through the reply dispatch and the quiet
// timer, into the same decisions Keyboard.ingestSeatFacts makes
// (LayoutDevices.select, the settle guard, LayoutDevices.anchorAfter).
// Nothing on the host loads Keyboard.qml, so `ingest` below restates that
// wiring; the modules it calls are the real ones.
//
// The replay is the owner's seat as captured on 2026-09-27
// (.scratch/dev-ease/evidence/altshift-capture-2026-09-27.log): every
// layout event the helper pushed, in order, at its time (milliseconds past
// 18:48:00). fcitx5's virtual keyboard holds `main` for good, the anchor
// was seeded as at-translated, and every Alt+Shift moved the ITE (8176)
// keyboard alone. The two bursts at 18:48:47 and 18:48:48 moved every
// device in enumeration order, pseudo-devices included — not the panel's
// click, which moves only its switch set; nothing in the capture was
// commanded by the panel.
//
// Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../HelperReplies.js" as Replies
import "../ChordAcks.js" as ChordAcks
import "../KeyboardSession.js" as Session
import "../ModifierReducer.js" as Modifiers
import "../SettleGuard.js" as SettleGuard
import "../SeatMotion.js" as SeatMotion
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
        // Every keyboard, in the compositor's enumeration order: the order
        // both bursts in the capture announced them in.
        var NAMES = ["video-bus", fcitx, ite95,
            "ite-tech.-inc.-ite-device(8176)-wireless-radio-control", ite76,
            "ideapad-extra-buttons", "video-bus-1", "power-button",
            "power-button-1", at, "razer-razer-deathadder-v3-keyboard",
            "razer-razer-deathadder-v3", ours]

        // Every `event\tlayout` the helper pushed, [ms past 18:48:00, device, group].
        var CAPTURE = [
            [23540, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [23543, "hl-virtual-keyboard-fcitx5", 1],
            [23988, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [23992, "hl-virtual-keyboard-fcitx5", 0],
            [36866, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [36869, "hl-virtual-keyboard-fcitx5", 1],
            [38723, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [38725, "hl-virtual-keyboard-fcitx5", 0],
            [40366, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [40371, "hl-virtual-keyboard-fcitx5", 1],
            [42144, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [42149, "hl-virtual-keyboard-fcitx5", 0],
            [47475, "video-bus", 1],
            [47477, "hl-virtual-keyboard-fcitx5", 1],
            [47483, "ite-tech.-inc.-ite-device(8176)-wireless-radio-control", 1],
            [47487, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [47490, "ideapad-extra-buttons", 1],
            [47498, "video-bus-1", 1],
            [47502, "power-button", 1],
            [47505, "power-button-1", 1],
            [47513, "razer-razer-deathadder-v3-keyboard", 1],
            [47522, "razer-razer-deathadder-v3", 1],
            [48121, "video-bus", 0],
            [48123, "hl-virtual-keyboard-fcitx5", 0],
            [48125, "ite-tech.-inc.-ite-device(8295)-keyboard", 0],
            [48129, "ite-tech.-inc.-ite-device(8176)-wireless-radio-control", 0],
            [48134, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [48143, "ideapad-extra-buttons", 0],
            [48148, "video-bus-1", 0],
            [48154, "power-button", 0],
            [48226, "power-button-1", 0],
            [48231, "at-translated-set-2-keyboard", 0],
            [48236, "razer-razer-deathadder-v3-keyboard", 0],
            [48241, "razer-razer-deathadder-v3", 0],
            [48244, "hl-virtual-keyboard-oskar-daemon", 0],
            [68308, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [68311, "hl-virtual-keyboard-fcitx5", 1],
            [68743, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [68747, "hl-virtual-keyboard-fcitx5", 0],
            [69103, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [69108, "hl-virtual-keyboard-fcitx5", 1],
            [69253, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [69256, "hl-virtual-keyboard-fcitx5", 0],
            [69515, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [69520, "hl-virtual-keyboard-fcitx5", 1],
            [69671, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [69676, "hl-virtual-keyboard-fcitx5", 0],
            [69903, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [69907, "hl-virtual-keyboard-fcitx5", 1],
            [70070, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [70077, "hl-virtual-keyboard-fcitx5", 0],
            [70264, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [70271, "hl-virtual-keyboard-fcitx5", 1],
            [70423, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [70425, "hl-virtual-keyboard-fcitx5", 0],
            [70587, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [70592, "hl-virtual-keyboard-fcitx5", 1],
            [70749, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [70754, "hl-virtual-keyboard-fcitx5", 0],
            [70911, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [70916, "hl-virtual-keyboard-fcitx5", 1],
            [75137, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [75141, "hl-virtual-keyboard-fcitx5", 0],
            [75496, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [75499, "hl-virtual-keyboard-fcitx5", 1],
            [75656, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [75660, "hl-virtual-keyboard-fcitx5", 0],
            [75947, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [75952, "hl-virtual-keyboard-fcitx5", 1],
            [76107, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [76111, "hl-virtual-keyboard-fcitx5", 0],
            [76387, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [76392, "hl-virtual-keyboard-fcitx5", 1],
            [76536, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [76537, "hl-virtual-keyboard-fcitx5", 0],
            [76816, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [76819, "hl-virtual-keyboard-fcitx5", 1],
            [76984, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [76988, "hl-virtual-keyboard-fcitx5", 0],
            [77236, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [77240, "hl-virtual-keyboard-fcitx5", 1],
            [77396, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [77399, "hl-virtual-keyboard-fcitx5", 0],
            [77630, "ite-tech.-inc.-ite-device(8176)-keyboard", 1],
            [77635, "hl-virtual-keyboard-fcitx5", 1],
            [77777, "ite-tech.-inc.-ite-device(8176)-keyboard", 0],
            [77782, "hl-virtual-keyboard-fcitx5", 0]
        ]

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
        // remembered group (persisted from configure acks), its timers.
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
                    anchorKeyboardName: anchor, seatMotion: SeatMotion.initial(),
                    seatAsk: "idle"
                },
                remembered: remembered,
                group: -1,
                switchSet: [],
                holds: 0,
                quietAt: [],
                recheckAt: -1,
                anchors: []
            }
        }

        function ctx(now) {
            return { groupCount: 2, capsPositions: "AD01", now: now }
        }

        // Keyboard.ingestSeatFacts' decisions, in its order.
        function ingest(m, facts, now) {
            var picked = LayoutDevices.select(facts.devices,
                m.state.anchorKeyboardName, m.state.startupKeyboards,
                m.remembered, facts.moved, facts.motion)
            m.switchSet = picked.switchSet
            if (!picked.reading) return
            var settle = SettleGuard.decide(m.state.settleGuard, picked.group, now,
                LayoutDevices.loneAnchor(picked, m.state.anchorKeyboardName))
            m.state.settleGuard = settle.state
            if (!settle.follow) {
                m.holds += 1
                m.recheckAt = now + SettleGuard.QUIESCE_MS + 100
            }
            var learned = LayoutDevices.anchorAfter(picked, settle.follow)
            if (learned) m.state.anchorKeyboardName = learned
            m.anchors.push(m.state.anchorKeyboardName)
            var group = settle.follow ? picked.group : settle.held
            if (group === m.group) return
            m.group = group
            m.remembered = group
            // The configure moves the helper's virtual keyboard, and
            // fcitx5's follows; both are announced, neither is evidence.
            m.seat.groups[ours] = group
            m.seat.groups[fcitx] = group
            run(m, Replies.dispatch(m.state, "event\tlayout\t" + ours + "\t" + group,
                ctx(now)), now)
        }

        function run(m, r, now) {
            m.state = r.state
            for (var i = 0; i < r.actions.length; i++) {
                var a = r.actions[i]
                if (a.op === "seatFacts") ingest(m, a, now)
                else if (a.op === "quietAt") m.quietAt.push(a.at)
            }
            return r
        }

        function line(m, text, now) {
            return run(m, Replies.dispatch(m.state, text, ctx(now)), now)
        }

        // The helper answers every outstanding seat ask with the seat as
        // it stands.
        function drain(m, now) {
            var guard = 0
            while (m.state.seatAsk !== "idle" && guard++ < 10)
                line(m, seatLine(m.seat), now)
        }

        // The keyboard's timers up to `now`: the quiet ticks and the settle
        // guard's one re-read, each answered at its own time.
        function advance(m, now) {
            for (;;) {
                m.quietAt.sort(function (x, y) { return x - y })
                var next = m.quietAt.length > 0 ? m.quietAt[0] : Infinity
                var recheck = m.recheckAt >= 0 ? m.recheckAt : Infinity
                var t = Math.min(next, recheck)
                if (t > now) return
                if (t === next) {
                    m.quietAt.shift()
                    run(m, Replies.motionQuiet(m.state, t), t)
                } else {
                    m.recheckAt = -1
                    run(m, Replies.seatWanted(m.state), t)
                }
                drain(m, t + 1)
            }
        }

        // The compositor moves one keyboard and announces it; the helper
        // answers the reading it asks for a millisecond later.
        function move(m, name, group, now) {
            advance(m, now)
            m.seat.groups[name] = group
            line(m, "event\tlayout\t" + name + "\t" + group, now)
            drain(m, now + 1)
        }

        // The panel's language button: record the command, then the loop
        // moves each keyboard of the switch set that is not already there,
        // 40 ms apart, each announced and read before the next lands.
        function click(m, group, now) {
            advance(m, now)
            m.state.settleGuard = SettleGuard.commanded(m.state.settleGuard,
                group, now, m.switchSet)
            var set = m.switchSet.slice()
            for (var i = 0; i < set.length; i++) {
                if (m.seat.groups[set[i]] !== group)
                    move(m, set[i], group, now + 5 + 40 * i)
            }
        }

        function establish(m, now) {
            run(m, Replies.seatWanted(m.state), now)
            drain(m, now)
        }

        // The helper goes away and a new one answers: the connection's
        // hello, its two oks, then the seat reading it asked for.
        function lose(m) {
            m.state = Replies.connectionLost(m.state).state
        }
        function reconnect(m, now, before) {
            advance(m, now)
            m.state.socketReconnected = true
            var hello = "hello " + Session.PROTOCOL_VERSION
            m.state.chordAcks = ChordAcks.sent(m.state.chordAcks, hello)
            line(m, hello, now)
            line(m, "ok", now)
            line(m, "ok", now)
            if (before) before()
            drain(m, now + 2)
        }

        function safeGroups(m) {
            return SAFE.map(function (name) { return m.seat.groups[name] })
        }

        T.test("the capture, replayed faithfully: every lone Alt+Shift is followed, neither burst re-anchors", function () {
            // 18:48:17.812: 8295 on 1, 8176 on 0, at-translated on 1; the
            // panel reads 1 (remembered) with at-translated as its anchor.
            var s = seat({})
            s.groups[ite95] = 1
            s.groups[at] = 1
            s.groups[ours] = 1
            var m = panel(s, at, 1)
            // Connected long before: the settle window is closed by 23.540.
            establish(m, 0)
            T.equal(m.group, 1, "the establishing reading")

            var followed = []
            var anchorsInBursts = []
            for (var i = 0; i < CAPTURE.length; i++) {
                var e = CAPTURE[i]
                move(m, e[1], e[2], e[0])
                if (e[1] === ite76 && e[0] < 47000) {
                    advance(m, e[0] + SeatMotion.QUIET_MS + 5)
                    followed.push(m.group)
                }
                if (e[0] >= 47475 && e[0] <= 48244)
                    anchorsInBursts.push(m.state.anchorKeyboardName)
            }
            advance(m, 90000)
            T.deepEqual(followed, [1, 0, 1, 0, 1, 0], "the six toggles before the bursts")
            T.deepEqual(anchorsInBursts.filter(function (name) { return name !== ite76 }), [],
                "a burst re-anchored the panel — mid-burst readings see one keyboard changed")
            T.equal(m.state.anchorKeyboardName, ite76, "the toggled keyboard is the anchor")
            T.equal(m.group, 0, "the last toggle (18:49:17.777) put the keyboard on 0")
            T.equal(m.holds, 0)
        })

        T.test("the capture's toggles after the bursts are followed one by one", function () {
            var s = seat({})
            var m = panel(s, at, 0)
            establish(m, 0)
            var groups = []
            for (var i = 0; i < CAPTURE.length; i++) {
                var e = CAPTURE[i]
                if (e[0] < 68000) { m.seat.groups[e[1]] = e[2]; continue }
                move(m, e[1], e[2], e[0])
                if (e[1] === ite76) {
                    advance(m, e[0] + SeatMotion.QUIET_MS + 5)
                    groups.push(m.group)
                }
            }
            var expected = CAPTURE.filter(function (e) {
                return e[0] >= 68000 && e[1] === ite76
            }).map(function (e) { return e[2] })
            T.deepEqual(groups, expected)
        })

        T.test("after a followed toggle the seat is diverged, and the next click reunites it", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, ite76, 1, 20000)
            advance(m, 20500)
            T.equal(m.group, 1)
            T.equal(m.state.anchorKeyboardName, ite76)
            // The panel follows; it issues no switch for the others.
            T.deepEqual(safeGroups(m), [0, 1, 0], "diverged: only the toggled keyboard moved")
            click(m, (m.group + 1) % 2, 25000)
            advance(m, 26000)
            T.deepEqual(safeGroups(m), [0, 0, 0], "reunited")
            T.equal(m.group, 0)
            T.equal(m.state.anchorKeyboardName, ite76)
            click(m, 1, 30000)
            advance(m, 31000)
            T.deepEqual(safeGroups(m), [1, 1, 1])
            T.equal(m.group, 1)
            T.equal(m.state.anchorKeyboardName, ite76, "no echo re-anchored")
        })

        T.test("the helper's own virtual keyboard moving after a configure is never an anchor, never a flip", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, ite76, 1, 20000)
            advance(m, 20500)
            T.equal(m.group, 1)
            // The helper's virtual keyboard holds `main` for a moment; a
            // reading taken anyway (hotplug, the settle re-read) must not
            // move the panel.
            m.seat.main = ours
            var r = line(m, "event\tlayout\t" + ours + "\t1", 20550)
            T.equal(r.actions.filter(function (a) { return a.op === "send" }).length, 0,
                "the helper's own echo asks nothing")
            line(m, "event\tdevices", 20560)
            drain(m, 20560)
            advance(m, 21000)
            T.equal(m.group, 1, "no flip back")
            T.equal(m.state.anchorKeyboardName, ite76)
        })

        T.test("a lone mover the helper did not identify is ignored", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, "razer-razer-deathadder-v3-keyboard", 1, 20000)
            move(m, "power-button", 1, 21000)
            move(m, fcitx, 1, 22000)
            advance(m, 23000)
            T.equal(m.group, 0)
            T.equal(m.state.anchorKeyboardName, at)
        })

        T.test("two keyboards moved within the quiet are a burst, never an anchor", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, ite95, 1, 20000)
            move(m, ite76, 1, 20030)
            advance(m, 21000)
            T.equal(m.state.anchorKeyboardName, at, "not re-anchored")
            T.equal(m.group, 0, "the older tiers answer: consensus device, remembered group")
        })

        T.test("the settle incident: a keyboard reset alone after a click inside the window is churn, and the anchor stays", function () {
            // The shape decisions §53 recorded: a click moves every
            // keyboard to 1 shortly after the helper reconnected, then the
            // compositor puts at-translated alone back on 0. The owner types
            // on 8176, which stays on 1.
            var m = panel(seat({}), ite76, 0)
            establish(m, 0)
            lose(m)
            reconnect(m, 10000)
            T.equal(m.group, 0, "the establishing reading after the reconnect")
            click(m, 1, 12000)
            advance(m, 12300)
            T.equal(m.group, 1, "the click is followed")
            move(m, at, 0, 12400)
            advance(m, 16000)
            T.equal(m.holds, 1, "the lone reset was held")
            T.equal(m.state.anchorKeyboardName, ite76, "a held move teaches no anchor")
            T.equal(m.group, 1, "the re-read answers from the anchor the panel had")
        })

        T.test("a toggle of the anchor itself inside the window is followed after the quiet", function () {
            var m = panel(seat({}), ite76, 0)
            establish(m, 0)
            move(m, ite76, 1, 2000)
            T.equal(m.group, 0, "not before the seat stayed quiet around it")
            advance(m, 2200)
            T.equal(m.group, 1, "followed inside the post-reconnect window")
            T.equal(m.state.settleGuard.armed, true, "and the window stands")
            move(m, ite76, 0, 2500)
            advance(m, 2700)
            T.equal(m.group, 0, "and back")
        })

        T.test("with the seat's flag on the typed keyboard, its toggle inside the window is followed", function () {
            // A seat without an input method: `main` sits on the keyboard
            // the user types on, and that keyboard is the anchor.
            var m = panel(seat({}, ite76), ite76, 0)
            establish(m, 0)
            lose(m)
            reconnect(m, 7330)
            T.equal(m.group, 0)
            move(m, ite76, 1, 10223)
            advance(m, 10700)
            T.equal(m.group, 1, "followed after the quiet")
            T.equal(m.state.settleGuard.armed, true)
            T.equal(m.state.anchorKeyboardName, ite76)
        })

        T.test("with the flag on the typed keyboard, a burst over it inside the window is held", function () {
            var m = panel(seat({}, ite76), ite76, 0)
            establish(m, 0)
            lose(m)
            reconnect(m, 7330)
            move(m, ite95, 1, 10000)
            move(m, ite76, 1, 10004)
            move(m, at, 1, 10009)
            advance(m, 10700)
            T.equal(m.group, 0, "held: nothing moved alone")
            T.equal(m.holds >= 1, true)
        })

        T.test("a toggle of another keyboard inside the window is held", function () {
            var m = panel(seat({}), ite76, 0)
            establish(m, 0)
            move(m, at, 1, 2000)
            advance(m, 2200)
            T.equal(m.holds >= 1, true, "held: the panel does not read that keyboard")
            T.equal(m.group, 0)
            advance(m, 5000)
            T.equal(m.state.anchorKeyboardName, ite76, "a held move teaches no anchor")
            T.equal(m.group, 0, "the re-read answers from the keyboard the panel reads")
        })

        T.test("the owner's desk after install and a shell restart: every Alt+Shift is followed", function () {
            // .scratch/dev-ease/evidence/settle-window-after-restart-2026-09-27.log,
            // ms past 21:37:00. The helper restarted at 5058 and the panel
            // established at 7330; the owner then toggled 8176, the keyboard
            // the panel reads, every 140-500 ms. fcitx5 mirrors each toggle
            // 3 ms later, as in the capture above. The toggles are the
            // log's, to the millisecond. The start is approximated: on the
            // desk a new shell took the first reading, here a live panel
            // meets a new helper. The guard starts from the same state
            // either way (nothing followed, then the establishing reading).
            var TOGGLES = [[10223, 1], [10715, 0], [10940, 1], [11340, 0],
                [11531, 1], [11930, 0], [12135, 1], [12274, 0], [12441, 1],
                [12631, 0], [12791, 1]]
            var m = panel(seat({}), ite76, 0)
            establish(m, 0)
            lose(m)
            reconnect(m, 7330)
            T.equal(m.group, 0, "the establishing reading")
            var followed = 0
            for (var i = 0; i < TOGGLES.length; i++) {
                var t = TOGGLES[i][0], g = TOGGLES[i][1]
                move(m, ite76, g, t)
                m.seat.groups[fcitx] = g
                line(m, "event\tlayout\t" + fcitx + "\t" + g, t + 3)
                var until = i + 1 < TOGGLES.length ? TOGGLES[i + 1][0] - 1 : t + 1000
                advance(m, until)
                // A toggle the next one follows inside the quiet is not
                // judged alone; every other one is drawn before the next.
                if (until - t >= SeatMotion.QUIET_MS + 10) {
                    T.equal(m.group, g, "toggle at " + t)
                    followed += 1
                }
            }
            T.equal(followed, 9, "two of the eleven had the next one inside the quiet")
            T.equal(m.group, 1, "the caps end where the keyboard is")
            T.equal(m.state.anchorKeyboardName, ite76)
        })

        T.test("after a click inside the window a lone toggle is held: the click's churn looks the same", function () {
            var m = panel(seat({}), ite76, 0)
            establish(m, 0)
            click(m, 1, 2000)
            advance(m, 2300)
            T.equal(m.group, 1)
            move(m, ite76, 0, 3000)
            advance(m, 3300)
            T.equal(m.group, 1, "held")
            advance(m, 6000)
            T.equal(m.group, 0, "followed once it persisted")
        })

        T.test("a keyboard toggled while the helper was away is found by the first reading after it", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            move(m, ite95, 0, 1000) // an event on the old connection
            lose(m)
            m.seat.groups[ite76] = 1   // Alt+Shift with nobody listening
            reconnect(m, 21000)
            T.equal(m.group, 1, "the toggle across the gap is followed")
            T.equal(m.state.anchorKeyboardName, ite76)
        })

        T.test("a keyboard toggled between `events on` and the first seat reply is found", function () {
            var m = panel(seat({}), at, 0)
            establish(m, 0)
            lose(m)
            reconnect(m, 21000, function () {
                m.seat.groups[ite76] = 1
                line(m, "event\tlayout\t" + ite76 + "\t1", 21001)
            })
            advance(m, 22000)
            T.equal(m.group, 1)
            T.equal(m.state.anchorKeyboardName, ite76)
        })

        T.test("two keyboards toggled one after the other: the anchor moves with each", function () {
            var m = panel(seat({}), ite95, 0)
            establish(m, 0)
            var steps = [[ite76, 1], [at, 1], [at, 0], [ite76, 0], [ite95, 1]]
            var anchors = []
            var groups = []
            for (var i = 0; i < steps.length; i++) {
                move(m, steps[i][0], steps[i][1], 20000 + 1000 * i)
                advance(m, 20500 + 1000 * i)
                anchors.push(m.state.anchorKeyboardName)
                groups.push(m.group)
            }
            T.deepEqual(anchors, [ite76, at, at, ite76, ite95])
            T.deepEqual(groups, [1, 1, 0, 0, 1])
        })

        Qt.exit(T.report("layout follow"))
    }
}
