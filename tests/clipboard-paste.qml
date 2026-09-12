import QtQml
import "../ClipboardPaste.js" as ClipboardPaste
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("a paste with the emoji page open targets its search, not the client (R2)", function () {
            // The page owns the panel's input while it is open — every key
            // types into the search — so the chip's paste must land there
            // too. On the old code this determination did not exist and the
            // chord went to the focused external client.
            T.equal(ClipboardPaste.pasteTarget(false, true), "emoji-search")
        })

        T.test("target precedence: colour field, then search, then client", function () {
            T.equal(ClipboardPaste.pasteTarget(true, false), "colour-field")
            T.equal(ClipboardPaste.pasteTarget(true, true), "colour-field")
            T.equal(ClipboardPaste.pasteTarget(false, false), "external-client")
        })

        T.test("a local read inserts while its target still stands", function () {
            var started = ClipboardPaste.readStart(ClipboardPaste.readInitial(),
                "emoji-search")
            T.equal(started.action, "read")
            var done = ClipboardPaste.readExited(started.state, started.state.seq,
                "emoji-search")
            T.equal(done.action, "insert")
            T.equal(done.state.pending, false)
        })

        T.test("a local read outliving its target inserts nothing", function () {
            // The page closes (or the field replaces it) while wl-paste is
            // reading: the arrival's determination no longer matches the
            // target the read started for.
            var started = ClipboardPaste.readStart(ClipboardPaste.readInitial(),
                "emoji-search")
            var closed = ClipboardPaste.readExited(started.state, started.state.seq,
                "external-client")
            T.equal(closed.action, "target-changed")
            T.equal(closed.state.pending, false)
            var swapped = ClipboardPaste.readExited(
                ClipboardPaste.readStart(ClipboardPaste.readInitial(),
                    "colour-field").state,
                1, "emoji-search")
            T.equal(swapped.action, "target-changed")
        })

        T.test("a timed-out local read is force-killed and its late answer refused", function () {
            var started = ClipboardPaste.readStart(ClipboardPaste.readInitial(),
                "colour-field")
            var timedOut = ClipboardPaste.readTimedOut(started.state,
                started.state.seq, "colour-field")
            T.equal(timedOut.action, "gone")
            T.equal(timedOut.kill, true)
            var late = ClipboardPaste.readExited(timedOut.state,
                started.state.seq, "colour-field")
            T.equal(late.action, "ignore")
        })

        T.test("a timeout under a changed target retires without the gone hint", function () {
            // The page closed while the dead owner was blocking the read:
            // retiring the kill is still mandatory, but this is not
            // "content gone" — the panel simply has no local target any more.
            var started = ClipboardPaste.readStart(ClipboardPaste.readInitial(),
                "emoji-search")
            var done = ClipboardPaste.readTimedOut(started.state,
                started.state.seq, "external-client")
            T.equal(done.action, "target-changed")
            T.equal(done.kill, true)
        })

        T.test("a second local read cannot replace an in-flight one", function () {
            var first = ClipboardPaste.readStart(ClipboardPaste.readInitial(),
                "colour-field")
            var second = ClipboardPaste.readStart(first.state, "emoji-search")
            T.equal(second.action, "ignore")
            T.equal(second.state.target, "colour-field")
            T.equal(second.state.seq, first.state.seq)
            // Once settled, a new read takes the next sequence — and an
            // answer from the old one is then refused.
            var settled = ClipboardPaste.readExited(first.state, first.state.seq,
                "colour-field")
            T.equal(settled.action, "insert")
            var restart = ClipboardPaste.readStart(settled.state, "emoji-search")
            T.equal(restart.action, "read")
            T.equal(restart.state.seq, first.state.seq + 1)
            var stale = ClipboardPaste.readExited(restart.state, first.state.seq,
                "colour-field")
            T.equal(stale.action, "ignore")
            T.equal(stale.state.pending, true)
        })

        T.test("a publish serves its verified emoji a chord", function () {
            var started = ClipboardPaste.publishStart(ClipboardPaste.publishInitial(), "😀")
            T.equal(started.action, "publish")
            var served = ClipboardPaste.publishServed(started.state,
                started.state.seq, "😀")
            T.equal(served.action, "chord")
            T.equal(served.state.pending, "😀")
        })

        T.test("a superseded publish says so and restarts clean", function () {
            var first = ClipboardPaste.publishStart(ClipboardPaste.publishInitial(), "😀")
            var second = ClipboardPaste.publishStart(first.state, "🔥")
            T.equal(second.action, "publish-superseding")
            T.equal(second.state.pending, "🔥")
            T.equal(second.state.attempts, 0)
            // The first pick's late answer arrives against the CURRENT
            // state (the second pick's) carrying the old sequence: stale.
            var late = ClipboardPaste.publishServed(second.state,
                first.state.seq, "😀")
            T.equal(late.action, "stale")
            T.equal(late.state.pending, "🔥")
        })

        T.test("a retry moves the sequence so a killed verify cannot answer for it", function () {
            var started = ClipboardPaste.publishStart(ClipboardPaste.publishInitial(), "😀")
            var retried = ClipboardPaste.publishServed(started.state,
                started.state.seq, "")
            T.equal(retried.action, "retry")
            T.equal(retried.state.attempts, 1)
            T.equal(retried.state.seq, started.state.seq + 1)
            // The killed run's late EMPTY answer arrives against the
            // current (retried) state with the old sequence: stale, and
            // it does not burn another attempt.
            var late = ClipboardPaste.publishServed(retried.state,
                started.state.seq, "")
            T.equal(late.action, "stale")
            T.equal(late.state.attempts, 1)
            // The new run's answer — with the new sequence — is heard.
            var ok = ClipboardPaste.publishServed(retried.state,
                retried.state.seq, "😀")
            T.equal(ok.action, "chord")
        })

        T.test("five unanswered verifies drop the pick with no chord", function () {
            var state = ClipboardPaste.publishStart(ClipboardPaste.publishInitial(), "😀").state
            for (var i = 1; i <= 4; i++) {
                var retried = ClipboardPaste.publishServed(state, state.seq, "")
                T.equal(retried.action, "retry")
                state = retried.state
            }
            var dropped = ClipboardPaste.publishServed(state, state.seq, "")
            T.equal(dropped.action, "drop")
            T.equal(dropped.state.pending, "")
            T.equal(dropped.state.attempts, 0)
            // Nothing lingers to fire later.
            var late = ClipboardPaste.publishServed(dropped.state,
                dropped.state.seq, "😀")
            T.equal(late.action, "stale")
        })

        T.test("cancelling a publish clears it and ignores empties", function () {
            var started = ClipboardPaste.publishStart(ClipboardPaste.publishInitial(), "😀")
            var cancelled = ClipboardPaste.publishCancel(started.state)
            T.equal(cancelled.action, "dropped")
            T.equal(cancelled.state.pending, "")
            T.equal(ClipboardPaste.publishCancel(cancelled.state).action, "ignore")
            var late = ClipboardPaste.publishServed(cancelled.state,
                started.state.seq, "😀")
            T.equal(late.action, "stale")
        })

        Qt.exit(T.report("clipboard-paste"))
    }
}
