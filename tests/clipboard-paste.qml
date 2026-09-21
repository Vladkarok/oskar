import QtQml
import "../ClipboardPaste.js" as ClipboardPaste
import "../ModifierReducer.js" as Modifiers
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("a paste with the emoji page open targets its search, not the client (R2)", function () {
            // The page owns the panel's input while it is open — every key
            // types into the search — so the chip's paste must land there
            // too. On the old code this determination did not exist and the
            // chord went to the focused external client.
            T.equal(ClipboardPaste.pasteTargetFor(true, false, "", false), "emoji-search")
        })

        T.test("target precedence: armed search, then a field with its whole identity", function () {
            T.equal(ClipboardPaste.pasteTargetFor(false, true, "textColor", false),
                "colour:popover:textColor")
            // The surface rides with the field: the custom editor and the
            // popover can both edit textColor, and a read started in one
            // must not land in the other (rounds 13-14).
            T.equal(ClipboardPaste.pasteTargetFor(false, true, "textColor", true),
                "colour:editor:textColor")
            T.equal(ClipboardPaste.pasteTargetFor(false, false, "", false),
                "external-client")
            // The armed search wins over a live field (opening a field
            // disarms the search, so both-active is not a real state —
            // stated rather than assumed).
            T.equal(ClipboardPaste.pasteTargetFor(true, true, "textColor", false),
                "emoji-search")
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
            // The running pick keeps the clipboard, the sequence and its
            // own click-time class (ticket 56); the queued pick is a
            // {emoji, clientClass} pair awaiting promotion.
            T.equal(second.state.pending, "😀")
            T.equal(second.state.seq, first.state.seq)
            T.deepEqual(second.state.queue,
                [{ emoji: "🔥", clientClass: "" }])
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
            var done = ClipboardPaste.txnChordDone(midChord.state, midChord.state.seq, true)
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
                    var done = ClipboardPaste.txnChordDone(state, state.seq, success)
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
            T.deepEqual(state.queue,
                [{ emoji: "🔥", clientClass: "" }, { emoji: "🎉", clientClass: "" }])
            state = ClipboardPaste.txnServed(state, state.seq, "😀").state
            state = ClipboardPaste.txnChordDone(state, state.seq, true).state
            var b = ClipboardPaste.txnNext(state)
            T.equal(b.action, "publish")
            T.equal(b.emoji, "🔥")
            T.deepEqual(b.state.queue, [{ emoji: "🎉", clientClass: "" }])
            // The promoted pick's sequence is new, so answers from the
            // finished transaction cannot masquerade for it.
            T.equal(b.state.seq > state.seq, true)
            var c = ClipboardPaste.txnNext(
                ClipboardPaste.txnChordDone(
                    ClipboardPaste.txnServed(b.state, b.state.seq, "🔥").state,
                    b.state.seq, true).state)
            T.equal(c.action, "publish")
            T.equal(c.emoji, "🎉")
            T.deepEqual(c.state.queue, [])
            T.equal(ClipboardPaste.txnNext(
                ClipboardPaste.txnChordDone(
                    ClipboardPaste.txnServed(c.state, c.state.seq, "🎉").state,
                    c.state.seq, true).state).action, "none")
        })

        T.test("a refused or aborted chord is a cancellation, never a completion", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(), "😀")
            var served = ClipboardPaste.txnServed(started.state,
                started.state.seq, "😀")
            var refused = ClipboardPaste.txnChordDone(served.state, served.state.seq, false)
            T.equal(refused.action, "cancelled")
            T.equal(refused.emoji, undefined)
            // The queue still gets its turn.
            var withB = ClipboardPaste.txnPick(served.state, "🔥")
            var after = ClipboardPaste.txnChordDone(withB.state, withB.state.seq, false)
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
            var lateDone = ClipboardPaste.txnChordDone(cancelled.state, cancelled.state.seq, true)
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

        // Ticket 56 (the IME matrix's kitty cell): the pick's target class
        // is derived ONCE, at the click, and travels with the payload
        // through publish, verify and chord. The old shape re-derived the
        // class at the chord's arrival, and the second derivation could
        // disagree with the first — the matrix measured a kitty pick
        // landing wine-shaped (bare Ctrl+V, no Shift, no "paste chord for
        // kitty" line). One derivation, one table (§44): whatever the
        // ambient focus read says by the time the clipboard transaction
        // lands, the chord answers for the class the pick was clicked for.

        T.test("a pick remembers the client class it was clicked for, through verify to the chord", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty")
            T.equal(started.action, "publish")
            T.equal(started.state.clientClass, "kitty")
            // Verify rounds and retries never lose it.
            var retried = ClipboardPaste.txnServed(started.state,
                started.state.seq, "")
            T.equal(retried.action, "retry")
            T.equal(retried.state.clientClass, "kitty")
            var served = ClipboardPaste.txnServed(retried.state,
                retried.state.seq, "😀")
            T.equal(served.action, "chord")
            T.equal(served.state.clientClass, "kitty")
        })

        T.test("the chord answers for the pick's own class — a kitty pick never turns wine at arrival", function () {
            // The disagreement the old arrival-time re-derivation allowed:
            // between the click and the chord, focus and the fallback
            // memory both move. With the class carried, the routing table
            // sees exactly what the pick saw, so the shapes cannot diverge.
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty")
            var served = ClipboardPaste.txnServed(started.state,
                started.state.seq, "😀")
            var chord = Modifiers.pasteChordForClass(served.state.clientClass)
            T.equal(chord.ctrl, true)
            T.equal(chord.shift, true)
            T.equal(chord.position, "AB04")
            // ...and the wine shape the matrix measured is what a wine
            // class pick still earns — the table itself was never wrong.
            var winePick = ClipboardPaste.txnPick(
                ClipboardPaste.txnInitial(), "😀", "steam_proton")
            var wineChord = Modifiers.pasteChordForClass(
                winePick.state.clientClass)
            T.equal(wineChord.ctrl, true)
            T.equal(wineChord.shift, false)
        })

        T.test("queued picks keep their own click-time classes through promotion", function () {
            // Two rapid picks can be for different clients (the first
            // click's chat, then the user switched and clicked again): the
            // queue entry is the pick, class and all — promotion is not a
            // re-derivation.
            var a = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty")
            var b = ClipboardPaste.txnPick(a.state, "🔥", "steam_proton")
            T.equal(b.action, "queued")
            var done = ClipboardPaste.txnChordDone(
                ClipboardPaste.txnServed(b.state, b.state.seq, "😀").state,
                b.state.seq, true)
            T.equal(done.action, "completed")
            var next = ClipboardPaste.txnNext(done.state)
            T.equal(next.action, "publish")
            T.equal(next.emoji, "🔥")
            T.equal(next.state.clientClass, "steam_proton")
        })

        T.test("a pick whose class did not resolve carries the empty class, never a guess", function () {
            // focusedClientClass() could not name the client: the empty
            // class rides the transaction so the routing table applies its
            // own empty rule (the terminal-safe chord), rather than an
            // arrival-time read inventing a different answer.
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "")
            T.equal(started.state.clientClass, "")
            var chord = Modifiers.pasteChordForClass(
                ClipboardPaste.txnServed(started.state, started.state.seq,
                    "😀").state.clientClass)
            T.equal(chord.shift, true)
            T.equal(chord.position, "AB04")
        })

        T.test("terminal outcomes leave the machine with no carried class", function () {
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty")
            var cancelled = ClipboardPaste.txnChordDone(
                ClipboardPaste.txnServed(started.state, started.state.seq,
                    "😀").state, started.state.seq, false)
            T.equal(cancelled.state.clientClass, "")
            var dropped = ClipboardPaste.txnPick(
                ClipboardPaste.txnInitial(), "😀", "kitty")
            var dead = ClipboardPaste.txnCancel(dropped.state)
            T.equal(dead.state.clientClass, "")
        })

        // ---- the review's third round: a stalled verify and a full queue ----

        T.test("a stalled verify drops the pick and hands the queue over", function () {
            // A clipboard owner that never finishes its read can stall the
            // verify forever (finding 2): the watchdog's timeout is a
            // terminal drop — the same shape the five-mismatch limit
            // already made — loud, no chord, and the next queued pick
            // proceeds.
            var started = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty")
            var queued = ClipboardPaste.txnPick(started.state, "🔥", "kitty")
            T.equal(queued.action, "queued")
            var timedOut = ClipboardPaste.txnVerifyTimedOut(
                queued.state, queued.state.seq)
            T.equal(timedOut.action, "drop")
            T.equal(timedOut.state.phase, "idle")
            T.equal(timedOut.state.queue.length, 1)
            var next = ClipboardPaste.txnNext(timedOut.state)
            T.equal(next.action, "publish")
            T.equal(next.emoji, "🔥")
            // A stale sequence — the verify this timeout describes is not
            // the one the machine holds — changes nothing.
            var stale = ClipboardPaste.txnVerifyTimedOut(queued.state, 0)
            T.equal(stale.action, "ignore")
            T.equal(stale.state, queued.state)
        })

        T.test("the queue refuses to grow without bound", function () {
            // Picks accumulate behind a stalled transaction (finding 2's
            // second half): three may wait, the fourth is refused at the
            // door and the queue stays at three.
            var state = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty").state
            for (var i = 0; i < 3; i++) {
                var queued = ClipboardPaste.txnPick(state, "🔥", "kitty")
                T.equal(queued.action, "queued")
                state = queued.state
            }
            T.equal(state.queue.length, 3)
            var fourth = ClipboardPaste.txnPick(state, "😅", "kitty")
            T.equal(fourth.action, "refused-full")
            T.equal(fourth.state.queue.length, 3)
        })

        T.test("a cancelled chord's late verdict cannot complete the next pick", function () {
            // Round seven's reproduction: A's chord dispatched, was
            // cancelled mid-flight, B started and reached ITS pasting — and
            // A's delayed reply still said "pasting" and recorded B as
            // successful mid-dispatch. The verdict now carries the seq it
            // was armed for; a verdict that names another transaction is
            // stale, whatever the phase says.
            var a = ClipboardPaste.txnPick(ClipboardPaste.txnInitial(),
                "😀", "kitty")
            var aChord = ClipboardPaste.txnServed(a.state, a.state.seq, "😀")
            var aSeq = aChord.state.seq
            var gone = ClipboardPaste.txnCancel(aChord.state)
            T.equal(gone.action, "dropped")
            // B runs the whole way to its own chord.
            var b = ClipboardPaste.txnPick(gone.state, "🔥", "kitty")
            T.equal(b.action, "publish")
            var bChord = ClipboardPaste.txnServed(b.state, b.state.seq, "🔥")
            T.equal(bChord.action, "chord")
            T.equal(bChord.state.phase, "pasting")
            // A's late success lands on B's machine: stale, nothing
            // recorded, B still owns its own verdict.
            var late = ClipboardPaste.txnChordDone(bChord.state, aSeq, true)
            T.equal(late.action, "stale", "the phase alone must not answer")
            T.equal(late.state.phase, "pasting")
            T.equal(late.state.pending, "🔥")
            // B's own verdict still completes B.
            var own = ClipboardPaste.txnChordDone(
                bChord.state, bChord.state.seq, true)
            T.equal(own.action, "completed")
            T.equal(own.emoji, "🔥")
        })

        Qt.exit(T.report("clipboard-paste"))
    }
}
