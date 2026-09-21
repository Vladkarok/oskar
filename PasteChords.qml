import QtQuick
import "ModifierReducer.js" as Modifiers
import "ChordAcks.js" as ChordAcks
import "PasteFlow.js" as PasteFlow
import "ClipboardPaste.js" as ClipboardPaste

Item {
    id: root

    // The paste chords' machinery, split out of Keyboard.qml (the
    // structural split's step two): pasteCurrent's dispatch (the
    // PasteFlow gate, the chord-shape derivation, the wine pacer and
    // the immediate branch), the paced tick, the acknowledgement guard
    // and the flow state live here. What stayed in the keyboard is the
    // input gate (applyModifierEvent — the paste event and the abort's
    // compensating releaseAll reach it through `applyEvent`, and its
    // §92 abort reaches back through `abortPacedPaste`), the reply
    // dispatch (it pops the ledger and hands the verdict here through
    // `chordAckCompleted`/`chordAckTimedOut`), and the correlation
    // ledger's one choke point: every write crosses `sendChoked`
    // (sendCommandUnchecked), so every paced line and compensating
    // release occupies its correlation slot exactly as before — the
    // discipline HelperLink's writes keep too.
    //
    // The ledger shape, chosen and why: ChordAcks' root state stays IN
    // the keyboard, because every command is slotted at
    // sendCommandUnchecked and every reply pops in the dispatch, both
    // of which live there. This component therefore holds the READ
    // half as a bound property (`chordAcks: root.chordAcks` at the
    // instantiation site, never assigned here, so the binding never
    // breaks) and writes every transition the machinery makes —
    // chordStart, chordArmed, chordSettled — back through the
    // `setChordAcks(state)` callback: one assignment, one home. A var
    // property reassigned locally would have severed the binding at
    // the first chordStart and left two divergent queues; the { get,
    // set } ledger-object alternative turns the reads into calls too,
    // while the bound property keeps the moved code's reads shaped
    // exactly as the monolith wrote them.
    //
    // OUT, consumed by the keyboard and the panel's frozen surface:
    // `pastePacing` (the input gate's §92 abort and the transport's
    // probe hold), `pasteFlow` (the §88 lane gate, by phase),
    // `abortPacedPaste` (the input gate and the close path), the two
    // verdict paths above, and `pasteCurrent` itself, which the
    // keyboard forwards under its own name.

    // ---- IN from the keyboard ----
    //
    // The correlation ledger's read half: the keyboard's chordAcks
    // object, bound from its single home. Never assigned here — an
    // assignment would break the binding and fork the queue.
    property var chordAcks: null
    // The ledger's write half: (state) => void, assigning the
    // keyboard's chordAcks. Every chordStart/chordArmed/chordSettled
    // the machinery makes goes through this and nothing else.
    property var setChordAcks: null
    // The one write choke point (sendCommandUnchecked): takes the
    // line, returns whether it was written. Only the paced tick, the
    // immediate branch and the abort's compensating releases call it.
    property var sendChoked: null
    // The input gate (applyModifierEvent): (event, sink) => void. The
    // paste event runs through it with a collector in the wine branch
    // and bare in the immediate branch, and the abort's compensating
    // releaseAll is always-live there by construction, so it cannot
    // re-enter the §92 abort that spawned it.
    property var applyEvent: null
    // The readiness fact the pacer's assumptions check reads at every
    // tick.
    property bool inputReady: false
    // The modifier world, bound: the pacer compares the locks its
    // lines planned around against the live state, and the locks are
    // captured at dispatch entry.
    property var modifierState: null

    /// Current-content paste (spec-v1.1 §1): an exact chord through the
    /// reducer, never a held cap and never mixed with latched Ctrl/Alt/Super.
    /// `wmClass` selects the CLIPBOARD chord (terminals: Ctrl+Shift+V; else
    /// Shift+Insert). Empty class uses the terminal chord so PRIMARY is not
    /// sent into a terminal the lookup failed to name.
    // The wine chord's delivery: one line per tick, never a burst. Wine
    // polls its keyboard a frame at a time, and a chord whose lines all
    // land in the same instant can be sampled with V visible before Ctrl
    // — a manual Ctrl+V never has the problem, because hands have
    // latency. The state settles immediately (the reducer ran); only the
    // writes are paced, and a second paste while one is pacing is
    // refused rather than interleaved.
    //
    // Ticket 28's transaction contract (audit 2026-09-13): a paste is no
    // longer fire-and-forget. The optional `completed` callback fires
    // exactly once — on the helper's acknowledgement of the chord's
    // final line, both paths (the review's third round: success is the
    // counterpart answering, not the write returning), and
    // synchronously with false on any refusal (already pacing, a held
    // key, an unready input, a dead socket mid-pace). The
    // emoji page records usage only from a real completion; every
    // caller passes one (§89: the chip and the txn both do — a missing
    // one is a no-op report and the flow still awaits the verdict).
    property bool pastePacing: false
    property var pastePacedLines: []
    // The full chord and how much of it went out, so an abort can owe the
    // device exactly its unlifted presses.
    property var pastePaceAllLines: []
    property int pastePaceSent: 0
    property var pastePaceDone: null
    // The paste lifecycle (PasteFlow.js): one paste at a time, the
    // busy-gate and the ordered cancellation as data. The timer and
    // socket machinery stays here; the invariant lives there.
    property var pasteFlow: PasteFlow.initial()
    // Which modifiers were locked when the chord computed its lines: a
    // mid-chord event that changes the held world (a configure draining
    // the device, a releaseAll) invalidates the remaining lines, and the
    // chord aborts instead of writing plans for a world that is gone.
    property var pastePaceLocks: []
    Timer {
        id: pastePacedTick
        interval: 35
        repeat: false
        onTriggered: () => {
            if (!root.pastePacing) return
            if (root.pastePacedLines.length === 0) {
                // Unreachable today (dispatch commits with lines or fails),
                // but the invariant stays local: every paced exit is
                // finishPacedPaste, so the flow can never outlive the flag.
                finishPacedPaste(false)
                return
            }
            if (!root.inputReady || !root.pasteChordAssumptionsHold()) {
                // The head line is neither consumed nor counted: nothing
                // was dispatched for it, so the sent prefix the abort
                // compensates is exactly what left the panel.
                root.abortPacedPaste()
                return
            }
            if (!root.sendChoked(root.pastePacedLines.shift())) {
                // The write refused: the consumed line pressed nothing at
                // the device (nothing owed for it), and the socket being
                // gone means the compensations are forwarded no-ops —
                // the helper already released its claims on disconnect.
                root.abortPacedPaste()
                return
            }
            root.pastePaceSent++
            if (root.pastePacedLines.length > 0) restart()
            else root.finishPacedPaste(true)
        }
    }

    // The chord's assumptions still hold while no key press interleaved
    // and the locked-modifier set is exactly the one its lines planned
    // around. Pure comparison; the abort itself lives below.
    function pasteChordAssumptionsHold() {
        if (modifierState.pending) return false
        for (var i = 0; i < Modifiers.ORDER.length; i++) {
            var name = Modifiers.ORDER[i]
            var lockedNow = modifierState[name] === "locked"
            var lockedThen = root.pastePaceLocks.indexOf(name) !== -1
            if (lockedNow !== lockedThen) return false
        }
        return true
    }

    function finishPacedPaste(success) {
        root.pastePacing = false
        var done = root.pastePaceDone
        root.pastePaceDone = null
        if (done && success) {
            root.pasteFlow = PasteFlow.awaiting(root.pasteFlow)
            settleChordThroughHelper(done)
        } else {
            root.pasteFlow = PasteFlow.failed(root.pasteFlow)
            if (done) done(false)
        }
    }

    // Route a dispatched chord's success through the helper's reply to its
    // final line. Failure paths never wait: a refusal, an abort or a dead
    // socket is already a verdict.
    function settleChordThroughHelper(done) {
        if (!done) return
        root.setChordAcks(ChordAcks.chordArmed(root.chordAcks, done))
        chordAckGuard.restart()
    }

    // The chord's own final line was answered: `ok` is success, anything
    // else — an err — is a failed chord, and both spend the slot. The
    // lifecycle closes with the verdict, whichever way it came.
    function chordAckCompleted(done, success) {
        root.pasteFlow = PasteFlow.verdictDone(root.pasteFlow)
        chordAckGuard.stop()
        if (done) done(success)
    }

    // The guard timeout, or a connection that cannot answer: the wait
    // ends failed, and the queue keeps draining on its own.
    function chordAckTimedOut() {
        var done = root.chordAcks.chordDone
        root.setChordAcks(ChordAcks.chordSettled(root.chordAcks))
        root.pasteFlow = PasteFlow.verdictDone(root.pasteFlow)
        chordAckGuard.stop()
        if (done) done(false)
    }

    Timer {
        id: chordAckGuard
        // Longer than the daemon's 5 s worst case (the external audit's
        // finding 10): a guard that fired first reported failure while
        // the daemon still delivered the chord late — pasting the next
        // pick's clipboard, the exact A→B race the transaction exists to
        // prevent.
        interval: 8 * 1000
        repeat: false
        onTriggered: () => {
            if (root.chordAcks.chordDone) root.chordAckTimedOut()
        }
    }

    // A paced chord that cannot continue: lift what its sent prefix
    // pressed without pairing, converge the modifier state by lifting
    // (never re-press — the releaseAll that follows resets the panel's
    // locks to match a device that no longer holds them), and report the
    // cancellation. After a socket loss every write here is a forwarded
    // no-op: the helper released its claims on disconnect, and a dead
    // socket cannot owe anything (the disconnect path's own argument).
    function abortPacedPaste() {
        var owed = ClipboardPaste.compensatingReleases(root.pastePaceAllLines,
            root.pastePaceSent)
        for (var i = 0; i < owed.length; i++)
            root.sendChoked(owed[i])
        root.pastePacedLines = []
        root.applyEvent({ type: "releaseAll" })
        root.finishPacedPaste(false)
    }

    function pasteCurrent(wmClass, completed) {
        // Every dispatched chord awaits its verdict (§89): a
        // callback-less call used to return the flow to idle the
        // instant the writes returned — the wl-copy-vs-in-flight-V
        // race the fifth lane was closed against, reborn for any
        // future caller following the old comment. There is no such
        // caller today (the chip and the txn both pass callbacks); a
        // missing one is a no-op report and the flow still awaits the
        // verdict.
        var done = completed || function () {}
        var cls = String(wmClass || "")
        // One paste at a time (PasteFlow owns the gate; round nine's
        // finding was this check living beside a chordStart that reset
        // the running chord's tracking): refused clean, nothing touched.
        var begun = PasteFlow.begin(root.pasteFlow)
        if (begun.refuse) {
            if (done) done(false)
            return false
        }
        root.pasteFlow = begun.state
        var chord = Modifiers.pasteChordForClass(cls)
        console.log("[oskar] paste chord for", cls === "" ? "(unknown class)" : cls,
            "->", (chord.ctrl ? "Ctrl+" : "") + (chord.shift ? "Shift+" : "")
            + chord.position)
        // The chord's region begins here (round eight): every command
        // sent from now until the verdict is the chord's business, and an
        // err anywhere inside it poisons the success — a final ok alone
        // proved nothing when the middle of the chord failed.
        root.setChordAcks(ChordAcks.chordStart(root.chordAcks))
        var event = {
            type: "paste",
            ctrl: chord.ctrl === true,
            shift: chord.shift === true,
            position: chord.position
        }
        if (Modifiers.usesWinePasteChord(cls.toLowerCase())) {
            // The flag arms AFTER the opening dispatch (§93, the audit's
            // poison): it stands guard against events that arrive while
            // the paste DRAINS — arming it before would make the paste's
            // own {type: "paste"} event the first thing the gate aborts.
            root.pastePacedLines = []
            root.applyEvent(event, function (line) {
                root.pastePacedLines.push(line)
            })
            if (root.pastePacedLines.length === 0) {
                // The reducer refused (a key press is pending) or input
                // is not ready: nothing was dispatched and nothing will
                // complete.
                root.pasteFlow = PasteFlow.failed(root.pasteFlow)
                if (done) done(false)
                return false
            }
            root.pastePacing = true
            root.pasteFlow = PasteFlow.paced(root.pasteFlow,
                root.pastePacedLines.length)
            root.pastePaceAllLines = root.pastePacedLines.slice()
            root.pastePaceSent = 0
            root.pastePaceDone = done
            root.pastePaceLocks = []
            for (var m = 0; m < Modifiers.ORDER.length; m++)
                if (modifierState[Modifiers.ORDER[m]] === "locked")
                    root.pastePaceLocks.push(Modifiers.ORDER[m])
            pastePacedTick.restart()
            return true
        }
        var sent = 0
        var wrote = true
        root.applyEvent(event, function (line) {
            sent++
            if (!root.sendChoked(line)) wrote = false
        })
        if (sent === 0 || !wrote) {
            root.pasteFlow = PasteFlow.failed(root.pasteFlow)
            if (done) done(false)
            return false
        }
        // Success is the helper's acknowledgement of the final line, not
        // the write returning (the review's third round): the next emoji
        // must not replace the clipboard before the paste events have at
        // least reached the compositor. `done` is always a function (the
        // §89 default): a missing callback is a NO-OP REPORT — the flow
        // still awaits the verdict and the guard still runs, so the gate
        // can never silently reopen (the agent audit's blocker) and can
        // never wedge on an unarmed wait either.
        root.pasteFlow = PasteFlow.awaiting(root.pasteFlow)
        settleChordThroughHelper(done)
        return true
    }
}
