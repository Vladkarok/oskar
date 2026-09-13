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

        // Ticket 28's delivery transaction (audit 2026-09-13): one pick
        // owns the clipboard and the paste chord end to end. A pick while
        // another is unfinished queues in order — a queued payload must
        // never replace the clipboard owner an unfinished paste still
        // depends on, and usage/settle/close happen only at the chord's
        // real completion, never at its dispatch.

        T.test("a pick publishes; a rapid second pick queues in order", function () {
            var first = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            T.equal(first.action, "publish")
            T.equal(first.state.pending, "😀")
            var second = ClipboardPaste.txnPick(first.state, "🔥")
            T.equal(second.action, "queued")
            // The running pick keeps the clipboard and the sequence.
            T.equal(second.state.pending, "😀")
            T.equal(second.state.seq, first.state.seq)
            T.deepEqual(second.state.queue, ["🔥"])
        })

        T.test("an empty payload is refused, never wedging the queue", function () {
            // Nothing could verify against an empty pick, so accepting it
            // would strand the machine in a transaction that can neither
            // serve nor drop — and every later pick behind it (review
            // finding). Refusal is the only safe answer.
            var refused = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "")
            T.equal(refused.action, "refused")
            T.equal(refused.state.pending, "")
            T.deepEqual(refused.state.queue, [])
            var busy = ClipboardPaste.txnPick(
                ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀").state,
                "")
            T.equal(busy.action, "refused")
            T.deepEqual(busy.state.queue, [])
        })

        T.test("a queued pick publishes only after the running chord completes", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var served = ClipboardPaste.txnServed(started.state,
                started.state.seq, "😀")
            T.equal(served.action, "chord")
            // The chord is dispatching: nothing starts behind it, and a
            // third pick queues like the second did.
            var midChord = ClipboardPaste.txnPick(served.state, "🎉")
            T.equal(midChord.action, "queued")
            T.equal(ClipboardPaste.txnNext(midChord.state).action, "none")
            var done = ClipboardPaste.txnChordDone(midChord.state, true)
            T.equal(done.action, "completed")
            T.equal(done.emoji, "😀")
            var next = ClipboardPaste.txnNext(done.state)
            T.equal(next.action, "publish")
            T.equal(next.emoji, "🎉")
        })

        T.test("rapid A→B picks dispatch A once then B once, in order", function () {
            // The audit's race, at the machine seam: B must not publish
            // (replace the clipboard owner) between A's dispatch and A's
            // completion, and each pick earns exactly one completion.
            var publishes = []
            var completions = []
            var state = ClipboardPaste.txnInitial()
            var pick = function (emoji) {
                var picked = ClipboardPaste.txnPick(state, emoji)
                state = picked.state
                if (picked.action === "publish") publishes.push(emoji)
            }
            var settle = function (served, success) {
                var servedOut = ClipboardPaste.txnServed(state, state.seq, served)
                state = servedOut.state
                if (servedOut.action === "chord") {
                    var done = ClipboardPaste.txnChordDone(state, success)
                    state = done.state
                    if (done.action === "completed") completions.push(done.emoji)
                }
                var next = ClipboardPaste.txnNext(state)
                state = next.state
                if (next.action === "publish") publishes.push(next.emoji)
            }
            pick("😀")
            pick("🔥")
            T.deepEqual(publishes, ["😀"])
            settle("😀", true)
            T.deepEqual(publishes, ["😀", "🔥"])
            T.deepEqual(completions, ["😀"])
            settle("🔥", true)
            T.deepEqual(completions, ["😀", "🔥"])
            T.equal(state.pending, "")
            T.deepEqual(state.queue, [])
        })

        T.test("a second pick cannot replace the running pick's clipboard owner", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var queued = ClipboardPaste.txnPick(started.state, "🔥")
            // B was never published, so nothing of B's can satisfy A's
            // verify; a stray answer carrying B is a mismatch, never a
            // chord for A.
            T.equal(queued.state.pending, "😀")
            var stray = ClipboardPaste.txnServed(queued.state,
                queued.state.seq, "🔥")
            T.equal(stray.action, "retry")
            T.equal(stray.state.pending, "😀")
        })

        T.test("a three-pick queue drains in order without losing anyone", function () {
            var state = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀").state
            state = ClipboardPaste.txnPick(state, "🔥").state
            state = ClipboardPaste.txnPick(state, "🎉").state
            T.deepEqual(state.queue, ["🔥", "🎉"])
            state = ClipboardPaste.txnServed(state, state.seq, "😀").state
            state = ClipboardPaste.txnChordDone(state, true).state
            var b = ClipboardPaste.txnNext(state)
            T.equal(b.action, "publish")
            T.equal(b.emoji, "🔥")
            T.deepEqual(b.state.queue, ["🎉"])
            // The promoted pick's sequence is new, so answers from the
            // finished transaction cannot masquerade for it.
            T.equal(b.state.seq > state.seq, true)
            var c = ClipboardPaste.txnNext(
                ClipboardPaste.txnChordDone(
                    ClipboardPaste.txnServed(b.state, b.state.seq, "🔥").state,
                    true).state)
            T.equal(c.action, "publish")
            T.equal(c.emoji, "🎉")
            T.deepEqual(c.state.queue, [])
            T.equal(ClipboardPaste.txnNext(
                ClipboardPaste.txnChordDone(
                    ClipboardPaste.txnServed(c.state, c.state.seq, "🎉").state,
                    true).state).action, "none")
        })

        T.test("a refused or aborted chord is a cancellation, never a completion", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var served = ClipboardPaste.txnServed(started.state,
                started.state.seq, "😀")
            var refused = ClipboardPaste.txnChordDone(served.state, false)
            T.equal(refused.action, "cancelled")
            T.equal(refused.emoji, undefined)
            // The queue still gets its turn.
            var withB = ClipboardPaste.txnPick(served.state, "🔥")
            var after = ClipboardPaste.txnChordDone(withB.state, false)
            T.equal(after.action, "cancelled")
            var next = ClipboardPaste.txnNext(after.state)
            T.equal(next.action, "publish")
            T.equal(next.emoji, "🔥")
        })

        T.test("a retry moves the sequence so a killed verify cannot answer for it", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var retried = ClipboardPaste.txnServed(started.state,
                started.state.seq, "")
            T.equal(retried.action, "retry")
            T.equal(retried.state.attempts, 1)
            T.equal(retried.state.seq, started.state.seq + 1)
            var late = ClipboardPaste.txnServed(retried.state,
                started.state.seq, "")
            T.equal(late.action, "stale")
            T.equal(late.state.attempts, 1)
            var ok = ClipboardPaste.txnServed(retried.state,
                retried.state.seq, "😀")
            T.equal(ok.action, "chord")
        })

        T.test("a verify answer that lands after the chord is stale", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var served = ClipboardPaste.txnServed(started.state,
                started.state.seq, "😀")
            T.equal(served.action, "chord")
            // The paste is dispatching; a duplicate answer for the same
            // sequence must not start a second chord.
            var duplicate = ClipboardPaste.txnServed(served.state,
                served.state.seq, "😀")
            T.equal(duplicate.action, "stale")
        })

        T.test("five unanswered verifies drop the pick and publish the queued one", function () {
            var state = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀").state
            state = ClipboardPaste.txnPick(state, "🔥").state
            for (var i = 1; i <= 4; i++) {
                var retried = ClipboardPaste.txnServed(state, state.seq, "")
                T.equal(retried.action, "retry")
                state = retried.state
            }
            var dropped = ClipboardPaste.txnServed(state, state.seq, "")
            T.equal(dropped.action, "drop")
            T.equal(dropped.state.pending, "")
            // The queued pick inherits the machine, not the failure.
            var next = ClipboardPaste.txnNext(dropped.state)
            T.equal(next.action, "publish")
            T.equal(next.emoji, "🔥")
            T.equal(next.state.attempts, 0)
            // Nothing lingers to fire later.
            var late = ClipboardPaste.txnServed(next.state, state.seq, "😀")
            T.equal(late.action, "stale")
        })

        T.test("cancelling drops the queue and late answers count for nothing", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var withB = ClipboardPaste.txnPick(started.state, "🔥")
            var cancelled = ClipboardPaste.txnCancel(withB.state)
            T.equal(cancelled.action, "dropped")
            T.equal(cancelled.state.pending, "")
            T.deepEqual(cancelled.state.queue, [])
            T.equal(ClipboardPaste.txnCancel(cancelled.state).action, "ignore")
            var late = ClipboardPaste.txnServed(cancelled.state,
                started.state.seq, "😀")
            T.equal(late.action, "stale")
            T.equal(ClipboardPaste.txnNext(cancelled.state).action, "none")
        })

        T.test("a chord completing after a cancel records no usage", function () {
            // The mode flipped while the chord was mid-dispatch: the
            // transaction is dead, so its late completion — successful or
            // not — must land as nothing.
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var served = ClipboardPaste.txnServed(started.state,
                started.state.seq, "😀")
            var cancelled = ClipboardPaste.txnCancel(served.state)
            T.equal(cancelled.action, "dropped")
            var lateDone = ClipboardPaste.txnChordDone(cancelled.state, true)
            T.equal(lateDone.action, "ignore")
            T.equal(lateDone.emoji, undefined)
        })

        T.test("compensations: nothing owed when everything or nothing was sent", function () {
            var wine = ["down LCTL", "down AB04", "up AB04", "up LCTL"]
            T.deepEqual(ClipboardPaste.compensatingReleases(wine, wine.length), [])
            T.deepEqual(ClipboardPaste.compensatingReleases(wine, 0), [])
            // A prefix that fully closed what it opened owes nothing
            // beyond its still-held modifiers.
            var balanced = ["down LCTL", "down AB04", "up AB04"]
            T.deepEqual(ClipboardPaste.compensatingReleases(
                ["down LCTL", "down AB04", "up AB04", "up LCTL"], 3), ["up LCTL"])
        })

        T.test("compensations lift an interrupted chord in reverse press order", function () {
            var wine = ["down LCTL", "down AB04", "up AB04", "up LCTL"]
            // The paste key went down but never came up, and Ctrl is held.
            T.deepEqual(ClipboardPaste.compensatingReleases(wine, 2),
                ["up AB04", "up LCTL"])
            // Only Ctrl was pressed.
            T.deepEqual(ClipboardPaste.compensatingReleases(wine, 1), ["up LCTL"])
        })

        T.test("compensations never re-press a lock lift the abort will converge", function () {
            // A chord that lifted locked Shift around itself plans to
            // re-press it at the end. An abort after the lift owes only
            // the press-side lifts: re-pressing the lock is the surviving
            // chord's job, and an aborted transaction converges by
            // lifting, never by re-pressing.
            var lifted = ["up LFSH", "down LCTL", "down AB04", "up AB04",
                "up LCTL", "down LFSH"]
            T.deepEqual(ClipboardPaste.compensatingReleases(lifted, 2),
                ["up LCTL"])
            // Only the lift itself went out: no press, nothing owed.
            T.deepEqual(ClipboardPaste.compensatingReleases(lifted, 1), [])
            T.deepEqual(ClipboardPaste.compensatingReleases(lifted, 0), [])
            // Fully sent, the restore pairs with the lift: nothing owed.
            T.deepEqual(ClipboardPaste.compensatingReleases(lifted, lifted.length), [])
        })

        Qt.exit(T.report("clipboard-paste"))
    }
}
