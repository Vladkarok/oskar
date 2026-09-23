// The paste lifecycle: one paste at a time, the busy-gate and the
// ordered cancellation as data. Run with tools/run-tests.sh — no
// compositor, no display.
import QtQml
import "../PasteFlow.js" as PasteFlow
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("a paste while another owns the lifecycle bounces untouched", function () {
            // Round nine, head on: the paste chip clicked mid-chord used
            // to reset the running chord's tracking. The begin answer is
            // a refusal that changes nothing.
            var idle = PasteFlow.initial()
            var dispatching = PasteFlow.begin(idle)
            T.equal(dispatching.refuse, false)
            var second = PasteFlow.begin(dispatching.state)
            T.equal(second.refuse, true)
            T.equal(second.state.phase, "dispatching", "the running paste's state is untouched")
            var paced = PasteFlow.paced(dispatching.state, 4)
            T.equal(PasteFlow.begin(paced).refuse, true)
            var wait = PasteFlow.awaiting(paced)
            T.equal(PasteFlow.begin(wait).refuse, true,
                "an awaiting verdict refuses a second paste too")
        })

        T.test("the paced path: zero lines is the reducer's refusal", function () {
            var state = PasteFlow.begin(PasteFlow.initial()).state
            T.equal(PasteFlow.paced(state, 0).phase, "idle")
            T.equal(PasteFlow.paced(state, 4).phase, "paced")
            T.equal(PasteFlow.paced(PasteFlow.initial(), 4).phase, "idle",
                "lines without a dispatch are ignored")
        })

        T.test("dispatch to awaiting to idle, and a racing second verdict", function () {
            var state = PasteFlow.begin(PasteFlow.initial()).state
            state = PasteFlow.awaiting(state)
            T.equal(state.phase, "awaiting")
            state = PasteFlow.verdictDone(state)
            T.equal(state.phase, "idle")
            // The guard timer racing the drain: the second verdict is a
            // no-op, not an error.
            T.equal(PasteFlow.verdictDone(state).phase, "idle")
            T.equal(PasteFlow.begin(state).refuse, false, "idle accepts the next paste")
        })

        T.test("cancellation answers an ordered program per phase", function () {
            // Cancel mid-PACE aborts the pacer (the V-press-onto-held-Ctrl
            // hole); cancel while AWAITING clears the armed verdict
            // (a late reply must not land); cancel on idle touches nothing.
            var idle = PasteFlow.initial()
            var c0 = PasteFlow.cancel(idle)
            T.equal(c0.abortPacer, false)
            T.equal(c0.clearWait, false)
            T.equal(c0.state.phase, "idle")

            var paced = PasteFlow.paced(PasteFlow.begin(idle).state, 4)
            var c1 = PasteFlow.cancel(paced)
            T.equal(c1.abortPacer, true, "mid-pace: the tick timer dies first")
            T.equal(c1.clearWait, false, "nothing is armed yet")
            T.equal(c1.state.phase, "idle")

            var wait = PasteFlow.awaiting(paced)
            var c2 = PasteFlow.cancel(wait)
            T.equal(c2.abortPacer, false)
            T.equal(c2.clearWait, true, "awaiting: the armed verdict dies")
            T.equal(c2.state.phase, "idle")
        })

        T.test("failure paths return to idle", function () {
            var state = PasteFlow.begin(PasteFlow.initial()).state
            T.equal(PasteFlow.failed(state).phase, "idle")
            T.equal(PasteFlow.begin(PasteFlow.failed(state)).refuse, false)
        })

        Qt.exit(T.report("paste flow"))
    }
}
