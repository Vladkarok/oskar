// Who moved on the seat, over time: a keyboard toggled alone told from a
// burst, from the panel's own click, and from the followers that mirror
// it. Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../SeatMotion.js" as Motion
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        var SAFE = ["kbd-a", "kbd-b", "kbd-c"]
        var Q = Motion.QUIET_MS
        var BASE = [{ name: "kbd-a", active_layout_index: 0 }]

        function withPrevious() {
            var s = Motion.initial()
            s.previous = BASE
            return s
        }

        T.test("a safe keyboard moving alone is a candidate, judged after the quiet", function () {
            var e = Motion.event(withPrevious(), "kbd-a", false, 1000, SAFE)
            T.equal(e.confirmAt, 1000 + Q)
            T.equal(e.state.candidate, "kbd-a")
            T.equal(e.state.candidateBase, BASE, "judged against the reading before it moved")
            T.equal(e.state.mover, "kbd-a")
            // A tick that fires early asks again at the right time.
            var early = Motion.quiet(e.state, 1000 + Q - 5)
            T.equal(early.ask, false)
            T.equal(early.confirmAt, 1000 + Q)
            var due = Motion.quiet(early.state, 1000 + Q)
            T.equal(due.ask, true)
            // The next reading carries the question once.
            var r = Motion.reading(due.state, [{ name: "kbd-a", active_layout_index: 1 }])
            T.deepEqual(r.motion, { base: BASE, candidate: "kbd-a", gap: false })
            T.equal(Motion.reading(r.state, []).motion, null)
        })

        T.test("the reading the move itself triggers asks nothing", function () {
            var e = Motion.event(withPrevious(), "kbd-a", false, 1000, SAFE)
            var r = Motion.reading(e.state, BASE)
            T.equal(r.motion, null)
            // And the candidate still stands, against the older reading.
            T.equal(r.state.candidate, "kbd-a")
            T.equal(r.state.candidateBase, BASE)
        })

        T.test("any other device moving within the quiet makes it a burst", function () {
            var others = ["kbd-b", "power-button", "video-bus", "razer-razer-deathadder-v3-keyboard"]
            for (var i = 0; i < others.length; i++) {
                // After it.
                var e = Motion.event(withPrevious(), "kbd-a", false, 1000, SAFE)
                e = Motion.event(e.state, others[i], false, 1000 + Q - 1, SAFE)
                var q = Motion.quiet(e.state, 1000 + 2 * Q)
                T.equal(q.ask && q.state.confirming === "kbd-a", false,
                    others[i] + " after it left the candidate standing")
                // Before it.
                var b = Motion.event(withPrevious(), others[i], false, 1000, SAFE)
                b = Motion.event(b.state, "kbd-a", false, 1000 + Q - 1, SAFE)
                T.equal(b.confirmAt, -1, others[i] + " before it left it a candidate")
                T.equal(b.state.candidate, "", others[i] + " before it")
            }
            // A move a full quiet away is not part of it.
            var apart = Motion.event(withPrevious(), "power-button", false, 1000, SAFE)
            apart = Motion.event(apart.state, "kbd-a", false, 1000 + Q, SAFE)
            T.equal(apart.state.candidate, "kbd-a")
        })

        T.test("virtual keyboards are followers, never evidence", function () {
            var e = Motion.event(withPrevious(), "kbd-a", false, 1000, SAFE)
            e = Motion.event(e.state, "hl-virtual-keyboard-fcitx5", false, 1003, SAFE)
            e = Motion.event(e.state, "hl-virtual-keyboard-oskar-daemon", false, 1010, SAFE)
            T.equal(e.state.candidate, "kbd-a")
            T.equal(e.state.mover, "kbd-a")
            T.equal(Motion.quiet(e.state, 1000 + Q).ask, true)
        })

        T.test("the same keyboard moving again restarts the wait, from the first base", function () {
            var e = Motion.event(withPrevious(), "kbd-a", false, 1000, SAFE)
            var mid = Motion.reading(e.state, [{ name: "kbd-a", active_layout_index: 1 }])
            e = Motion.event(mid.state, "kbd-a", false, 1100, SAFE)
            T.equal(e.confirmAt, 1100 + Q)
            T.equal(e.state.candidateBase, BASE)
            T.equal(Motion.quiet(e.state, 1000 + Q).ask, false)
            T.equal(Motion.quiet(e.state, 1100 + Q).ask, true)
        })

        T.test("the panel's echo, an unidentified keyboard and a pseudo-device are never candidates", function () {
            T.equal(Motion.event(withPrevious(), "kbd-a", true, 1000, SAFE).state.candidate, "")
            T.equal(Motion.event(withPrevious(), "kbd-a", true, 1000, SAFE).state.commanded, true)
            T.equal(Motion.event(withPrevious(), "razer-razer-deathadder-v3-keyboard",
                false, 1000, SAFE).state.candidate, "")
            var pb = Motion.event(withPrevious(), "power-button", false, 1000, SAFE)
            T.equal(pb.state.candidate, "")
            T.equal(pb.state.mover, "", "a pseudo-device is never the mover")
            // A candidate's own echo ends it.
            var e = Motion.event(withPrevious(), "kbd-a", false, 1000, SAFE)
            e = Motion.event(e.state, "kbd-a", true, 1050, SAFE)
            T.equal(e.state.candidate, "")
        })

        T.test("a reconnect forgets every event and keeps the last reading for one comparison", function () {
            var e = Motion.event(withPrevious(), "kbd-a", true, 1000, SAFE)
            var gone = Motion.reconnected(e.state)
            T.equal(gone.mover, "")
            T.equal(gone.commanded, false)
            T.equal(gone.candidate, "")
            T.equal(gone.lastEventDevice, "")
            T.equal(gone.gap, true)
            var first = Motion.reading(gone, [{ name: "kbd-a", active_layout_index: 1 }])
            T.deepEqual(first.motion, { base: BASE, candidate: "", gap: true })
            T.equal(Motion.reading(first.state, BASE).motion, null, "used once")
            // A panel with no reading before the gap has nothing to compare.
            var fresh = Motion.reconnected(Motion.initial())
            T.equal(fresh.gap, false)
            T.equal(Motion.reading(fresh, BASE).motion, null)
        })

        Qt.exit(T.report("seat motion"))
    }
}
