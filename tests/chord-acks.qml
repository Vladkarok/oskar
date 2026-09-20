// Correlating the helper's replies with the commands they answer, so a
// paste chord waits for the acknowledgement of its own final line. Run
// with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../ChordAcks.js" as ChordAcks
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("every sent command occupies a slot, every reply pops one", function () {
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.sent(state, "text 👍")
            T.equal(state.queue.length, 2)
            var first = ChordAcks.replyReceived(state, true)
            T.equal(first.state.queue.length, 1)
            T.equal(first.done, null)
            var second = ChordAcks.replyReceived(first.state, false)
            T.equal(second.state.queue.length, 0)
            T.equal(second.done, null)
            // A reply on an empty queue answers one of the bypassed
            // writes; it settles nothing and owes nothing.
            var stray = ChordAcks.replyReceived(second.state, true)
            T.equal(stray.state.queue.length, 0)
        })

        T.test("the chord settles on the drain, not the first ok", function () {
            // The review's fourth round, head on: a chord of three lines
            // arms its wait after dispatch, and the FIRST ok — the Ctrl
            // press's — must not settle it.
            var state = ChordAcks.initial()
            for (var i = 0; i < 3; i++)
                state = ChordAcks.sent(state, "down ctrl")
            var chordDone = function () {}
            state = ChordAcks.chordArmed(state, chordDone)
            var first = ChordAcks.replyReceived(state, true)
            T.equal(first.done, null, "the Ctrl press's ok settles nothing")
            T.equal(first.state.queue.length, 2)
            var second = ChordAcks.replyReceived(first.state, true)
            T.equal(second.done, null)
            var third = ChordAcks.replyReceived(second.state, true)
            T.equal(third.done, chordDone, "the FINAL line's ack settles the chord")
            T.equal(third.success, true)
            T.equal(third.state.chordDone, null)
        })

        T.test("an err on the chord's final line settles it failed", function () {
            // Round five's blocker: an err'd command used to sit in the
            // ledger forever, failing every later chord by timeout. Now
            // the err spends the slot AND carries the verdict.
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.sent(state, "up ctrl")
            var chordDone = function () {}
            state = ChordAcks.chordArmed(state, chordDone)
            var ok = ChordAcks.replyReceived(state, true)
            T.equal(ok.done, null)
            var err = ChordAcks.replyReceived(ok.state, false)
            T.equal(err.done, chordDone)
            T.equal(err.success, false, "an err'd final line is a failed chord")
            // The queue is clean: the NEXT chord starts from zero.
            T.equal(err.state.queue.length, 0)
        })

        T.test("an err on an unrelated command drains without settling", function () {
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "group 9")  // will err, pre-chord
            state = ChordAcks.chordStart(state)
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.chordArmed(state, function () {})
            var err = ChordAcks.replyReceived(state, false)
            T.equal(err.done, null, "the group's err is not the chord's verdict")
            T.equal(err.state.queue.length, 1)
            var ack = ChordAcks.replyReceived(err.state, true)
            T.equal(ack.done !== null, true, "the final line's ack settles it")
            T.equal(ack.success, true)
        })

        T.test("a connection that dies resets the ledger and the wait", function () {
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.chordArmed(state, function () {})
            var gone = ChordAcks.connectionLost(state)
            T.equal(gone.queue.length, 0, "no reply is coming for the dead socket")
            T.equal(gone.chordDone, null)
            T.equal(ChordAcks.replyReceived(gone, true).done, null)
        })

        T.test("the guard timeout clears the wait, the queue keeps draining", function () {
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.sent(state, "up ctrl")
            state = ChordAcks.chordArmed(state, function () {})
            var after = ChordAcks.chordSettled(state)
            T.equal(after.chordDone, null)
            T.equal(after.queue.length, 2)
            var late = ChordAcks.replyReceived(after, true)
            T.equal(late.done, null, "nothing waits any more")
            T.equal(late.state.queue.length, 1)
        })

        T.test("arming on an empty queue leaves the wait to the guard", function () {
            var state = ChordAcks.initial()
            var armed = ChordAcks.chordArmed(state, function () {})
            T.equal(armed.queue.length, 0)
            T.equal(armed.chordDone !== null, true)
        })

        T.test("a late reply to a timed-out chord settles nothing", function () {
            // The reviewer's live reproduction: the old chord times out
            // with two commands unanswered, a new chord arms, and the OLD
            // replies start arriving — the new chord must not be declared
            // complete while its own commands are still unacked.
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.sent(state, "down AB04")
            state = ChordAcks.chordArmed(state, function () {})
            // The guard timer fires: the wait dies, the marker dies with it.
            state = ChordAcks.chordSettled(state)
            T.equal(state.chordDone, null)
            // The new chord: one line out, armed.
            state = ChordAcks.sent(state, "down ctrl")
            var secondDone = function () {}
            state = ChordAcks.chordArmed(state, secondDone)
            // The OLD chord's late replies arrive first: both pop, neither
            // settles anything.
            var late1 = ChordAcks.replyReceived(state, true)
            T.equal(late1.done, null, "the first late reply settles nothing")
            var late2 = ChordAcks.replyReceived(late1.state, true)
            T.equal(late2.done, null, "the second late reply settles nothing")
            T.equal(late2.state.queue.length, 1, "the new chord's line still waits")
            // Only ITS own ack completes it.
            var own = ChordAcks.replyReceived(late2.state, true)
            T.equal(own.done, secondDone)
            T.equal(own.success, true)
        })

        T.test("an err inside the chord poisons the verdict, final ok or not", function () {
            // Round eight's reproduction: a custom keymap without Insert
            // errors both Insert commands while the last Shift release
            // answers ok — the old logic saw only the final ok and
            // recorded success for a paste that delivered nothing.
            var state = ChordAcks.initial()
            state = ChordAcks.chordStart(state)
            state = ChordAcks.sent(state, "down shift")
            state = ChordAcks.sent(state, "down Insert")
            state = ChordAcks.sent(state, "up Insert")
            state = ChordAcks.sent(state, "up shift")
            var chordDone = function () {}
            state = ChordAcks.chordArmed(state, chordDone)
            var ok1 = ChordAcks.replyReceived(state, true)
            T.equal(ok1.done, null)
            var err1 = ChordAcks.replyReceived(ok1.state, false)
            T.equal(err1.done, null)
            var err2 = ChordAcks.replyReceived(err1.state, false)
            T.equal(err2.done, null)
            var final = ChordAcks.replyReceived(err2.state, true)
            T.equal(final.done, chordDone, "the final line still settles it")
            T.equal(final.success, false, "but the region's errs poisoned it")
        })

        T.test("a clean chord still succeeds, and pre-chord errs do not count", function () {
            var state = ChordAcks.initial()
            // An unrelated command errs BEFORE the chord starts: its pop
            // is pre-region and must not poison anything.
            state = ChordAcks.sent(state, "group 9")
            state = ChordAcks.chordStart(state)
            state = ChordAcks.sent(state, "down ctrl")
            state = ChordAcks.sent(state, "up ctrl")
            state = ChordAcks.chordArmed(state, function () {})
            var pre = ChordAcks.replyReceived(state, false)
            T.equal(pre.done, null, "the pre-chord err settles nothing")
            var a = ChordAcks.replyReceived(pre.state, true)
            T.equal(a.done, null)
            var b = ChordAcks.replyReceived(a.state, true)
            T.equal(b.done !== null, true, "the final line settles it")
            T.equal(b.success, true)
        })

        Qt.exit(T.report("chord acks"))
    }
}
