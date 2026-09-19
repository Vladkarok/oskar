// Correlating bare `ok` replies with the plain commands they answer, so a
// paste chord waits for the acknowledgement of its own final line. Run
// with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../ChordAcks.js" as ChordAcks
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("only plain verb commands are counted", function () {
            T.equal(ChordAcks.isPlainCommand("down ctrl"), true)
            T.equal(ChordAcks.isPlainCommand("up ctrl"), true)
            T.equal(ChordAcks.isPlainCommand("mods 5"), true)
            T.equal(ChordAcks.isPlainCommand("group 1"), true)
            T.equal(ChordAcks.isPlainCommand("text 👍"), false)
            T.equal(ChordAcks.isPlainCommand("configure\tevdev"), false)
            T.equal(ChordAcks.isPlainCommand("caps 0"), false)
            T.equal(ChordAcks.isPlainCommand(""), false)
            T.equal(ChordAcks.isPlainCommand(null), false)
        })

        T.test("the chord settles on the drain, not the first ok", function () {
            // The review's fourth round, head on: a chord of three lines
            // arms its wait after dispatch, and the FIRST ok — the Ctrl
            // press's — must not settle it.
            var state = ChordAcks.initial()
            for (var i = 0; i < 3; i++)
                state = ChordAcks.sent(state, "down ctrl").state
            state = ChordAcks.chordArmed(state, function () {})
            var first = ChordAcks.okReceived(state)
            T.equal(first.settle, false, "the Ctrl press's ok settles nothing")
            T.equal(first.state.outstanding, 2)
            var second = ChordAcks.okReceived(first.state)
            T.equal(second.settle, false)
            var third = ChordAcks.okReceived(second.state)
            T.equal(third.settle, true, "the FINAL line's ack settles the chord")
        })

        T.test("an interleaved click delays the drain, never breaks it", function () {
            // A modifier click after the chord's last line went out: its
            // ok drains the click too — the chord settles late (safe),
            // never early (the bug).
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl").state
            state = ChordAcks.sent(state, "tap AB04").state  // not counted
            state = ChordAcks.chordArmed(state, function () {})
            state = ChordAcks.sent(state, "down shift").state  // the click
            var a = ChordAcks.okReceived(state)
            T.equal(a.settle, false)
            T.equal(a.state.outstanding, 1)
            var b = ChordAcks.okReceived(a.state)
            T.equal(b.settle, true)
        })

        T.test("a connection that dies resets the ledger and the wait", function () {
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl").state
            state = ChordAcks.chordArmed(state, function () {})
            var gone = ChordAcks.connectionLost(state)
            T.equal(gone.outstanding, 0, "no ok is coming for the dead socket")
            T.equal(gone.chordDone, null)
            // And the fresh world does not settle ghosts.
            T.equal(ChordAcks.okReceived(gone).settle, false)
        })

        T.test("a settled chord leaves the counter to finish draining", function () {
            var state = ChordAcks.initial()
            state = ChordAcks.sent(state, "down ctrl").state
            state = ChordAcks.sent(state, "up ctrl").state
            state = ChordAcks.chordArmed(state, function () {})
            var drained = ChordAcks.okReceived(state)
            T.equal(drained.settle, false)
            var after = ChordAcks.chordSettled(drained.state)
            T.equal(after.outstanding, 1)
            T.equal(after.chordDone, null)
            var last = ChordAcks.okReceived(after)
            T.equal(last.settle, false, "nothing waits any more")
            T.equal(last.state.outstanding, 0)
        })

        Qt.exit(T.report("chord acks"))
    }
}
