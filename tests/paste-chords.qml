// The paste chords' acknowledgement guard, driven through the real
// PasteChords component with the keyboard's wiring stubbed: the guard
// measures the helper's silence, not the time since the chord was
// written, and when it does expire the link is torn down so the chord
// still queued in the helper can never paste afterwards. Run with
// tools/run-tests.sh — offscreen, no compositor, no socket.
import QtQml
import "../ChordAcks.js" as ChordAcks
import "harness.js" as T

QtObject {
    id: suite

    property var chords: null
    property var verdicts: []
    property int abandoned: 0
    property var steps: []

    // The keyboard's wiring, stubbed: the ledger lives here, writes are
    // counted, and abandoning the link settles the chord the way the
    // rebuild's connectionLost does.
    function makeChords(guardMs, withAbandon) {
        var component = Qt.createComponent("../PasteChords.qml")
        if (component.status !== Component.Ready) {
            T.fail("PasteChords did not load: " + component.errorString())
            return null
        }
        var made = component.createObject(null, { chordGuardMs: guardMs })
        if (!made) {
            T.fail("PasteChords did not instantiate")
            return null
        }
        made.chordAcks = ChordAcks.initial()
        made.setChordAcks = function (state) { made.chordAcks = state }
        made.sendChoked = function (line) {
            made.chordAcks = ChordAcks.sent(made.chordAcks, line)
            return true
        }
        if (withAbandon)
            made.abandonLink = function () {
                suite.abandoned += 1
                // What the rebuild's connectionLost program does to an
                // armed chord: the wait settles as a cancellation.
                if (made.chordAcks.chordDone) made.chordAckTimedOut()
                made.chordAcks = ChordAcks.connectionLost(made.chordAcks)
            }
        return made
    }

    // A chord queued behind a `share`: the share's slot, then the
    // chord's three lines, armed on the last.
    function armBehindShare(made) {
        made.sendChoked("share\t/run/user/1000/oskar/keymap.xkb")
        made.setChordAcks(ChordAcks.chordStart(made.chordAcks))
        made.sendChoked("down LCTL")
        made.sendChoked("down AB04")
        made.sendChoked("up AB04")
        made.sendChoked("up LCTL")
        made.settleChordThroughHelper(function (ok) { suite.verdicts.push(ok) })
    }

    // Steps run in order on a timer: { at: ms since start, run }.
    property int stepIndex: 0
    property double startedAt: 0
    property Timer ticker: Timer {
        interval: 20
        repeat: true
        onTriggered: suite.tick()
    }

    function tick() {
        var now = Date.now() - startedAt
        while (stepIndex < steps.length && steps[stepIndex].at <= now) {
            var step = steps[stepIndex]
            stepIndex += 1
            T.test(step.name, step.run)
        }
        if (stepIndex >= steps.length) {
            ticker.stop()
            Qt.exit(T.report("paste chords"))
        }
    }

    Component.onCompleted: {
        try {
            chords = makeChords(400, true)
            if (chords) armBehindShare(chords)
        } catch (error) {
            T.fail("the guard's wiring is missing: " + error)
            chords = null
        }
        if (!chords) {
            Qt.exit(T.report("paste chords"))
            return
        }
        steps = [
            { at: 250, name: "a reply ahead of the chord is progress", run: function () {
                // The share answers: the lane moved, the guard starts over.
                var popped = ChordAcks.replyReceived(chords.chordAcks, "ok")
                chords.chordAcks = popped.state
                T.equal(popped.progress, true, "a pop ahead of the final line is progress")
                chords.chordLaneAdvanced()
            } },
            { at: 550, name: "the guard measures silence, not the chord's age", run: function () {
                // 550 ms since the chord was written, 300 since the lane
                // last moved: the chord is still owed its verdict.
                T.deepEqual(suite.verdicts, [])
                T.equal(suite.abandoned, 0, "the link stands while the helper progresses")
            } },
            { at: 1000, name: "a silent lane tears the link down before reporting", run: function () {
                T.equal(suite.abandoned, 1, "the expiry abandons the link")
                T.deepEqual(suite.verdicts, [false], "and the chord reports cancelled once")
                T.equal(chords.chordAcks.chordDone, null)
                T.equal(chords.pasteFlow.phase, "idle")
            } }
        ]
        startedAt = Date.now()
        ticker.start()
    }
}
