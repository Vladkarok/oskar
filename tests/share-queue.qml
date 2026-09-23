// The keymap-share scheduler: one run at a time, launched for a
// generation, the wish consumed on success. Run with tools/run-tests.sh
// — no compositor, no display.
import QtQml
import "../ShareQueue.js" as ShareQueue
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("an acknowledged generation launches a run for itself", function () {
            var out = ShareQueue.acked(ShareQueue.initial(), 3)
            T.equal(out.start, true)
            T.equal(out.state.running, true)
            T.equal(out.state.launched, 3)
            T.equal(out.state.wished, 3)
        })

        T.test("zero, negative and already-shared generations launch nothing", function () {
            T.equal(ShareQueue.acked(ShareQueue.initial(), 0).start, false)
            T.equal(ShareQueue.acked(ShareQueue.initial(), -1).start, false)
            var shared = ShareQueue.runFinished(
                ShareQueue.acked(ShareQueue.initial(), 3).state, true).state
            T.equal(ShareQueue.acked(shared, 3).start, false)
        })

        T.test("a newer generation mid-run only updates the wish", function () {
            var state = ShareQueue.acked(ShareQueue.initial(), 1).state
            var mid = ShareQueue.acked(state, 2)
            T.equal(mid.start, false, "no second run while one is in flight")
            T.equal(mid.state.running, true)
            T.equal(mid.state.launched, 1, "the running run keeps its own target")
            T.equal(mid.state.wished, 2)
        })

        T.test("success shares what the run launched, and consumes the wish", function () {
            // Success must leave: shared 1, helper at 2, nothing running,
            // nothing retrying.
            var state = ShareQueue.acked(ShareQueue.initial(), 1).state
            state = ShareQueue.acked(state, 2).state
            var done = ShareQueue.runFinished(state, true)
            T.equal(done.state.shared, 1, "only what this run launched is shared")
            T.equal(done.start, true, "the pending generation is scheduled now")
            T.equal(done.state.running, true)
            T.equal(done.state.launched, 2)
            // And the scheduled run completes the sequence.
            var second = ShareQueue.runFinished(done.state, true)
            T.equal(second.state.shared, 2)
            T.equal(second.start, false)
            T.equal(second.state.running, false)
        })

        T.test("a failed run keeps its generation and the wish for the retry", function () {
            var state = ShareQueue.acked(ShareQueue.initial(), 1).state
            state = ShareQueue.acked(state, 2).state
            var failed = ShareQueue.runFinished(state, false)
            T.equal(failed.start, false)
            T.equal(failed.state.running, true, "the caller's retry still owns the run")
            T.equal(failed.state.launched, 1)
            T.equal(failed.state.wished, 2)
            T.equal(failed.state.shared, 0)
        })

        T.test("a wish older than what is shared never launches", function () {
            // The panel's fallback paths can replay stale acks: a
            // generation at or below what is already shared is no work.
            var state = ShareQueue.initial()
            state = ShareQueue.runFinished(ShareQueue.acked(state, 5).state, true).state
            T.equal(state.shared, 5)
            var stale = ShareQueue.acked(state, 3)
            T.equal(stale.start, false)
            T.equal(stale.state.wished, 5, "the wish never regresses")
        })

        Qt.exit(T.report("share queue"))
    }
}
