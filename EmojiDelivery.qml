import QtQuick
import Quickshell.Io
import "ClipboardPaste.js" as ClipboardPaste
import "UiStrings.js" as UiStrings

Item {
    id: root

    // The emoji delivery transaction's machinery, split out of Panel.qml
    // (the structural split's step four): the wl-copy publisher, the
    // verify pipeline (its Process, the re-arm timer, the 3 s watchdog),
    // the verdict arms, the queue's hand-over and the queue-cap flash
    // flag — the QML half of the machine whose invariants live in the
    // pure ClipboardPaste.txn* machine. What stayed in the panel is
    // everything a pick is ABOUT: the onEmojiChosen dispatch (tone
    // resolution, the armed-search disarm, and ticket 56's ONE
    // client-class derivation at the click, handed in as request()'s
    // clientClass argument and never re-derived here), the refusal
    // flashing (flashRefused, bound IN — §79's one hint channel stays
    // the panel's), the usage recording and the delivered pick's settle
    // and close (the pickSettled signal below), and the paste chip's
    // gate on the txn phase (emojiTxnState stays exposed under its own
    // name for that read, and emojiPickRefused for the hint table's).
    //
    // The verdict seam's shape, chosen and why: the monolith's completed
    // arm was three panel-side effects in one fixed order — usage, the
    // search settle, the close-after-pick read — so the seam is ONE
    // signal carrying the emoji rather than a callback per effect: the
    // panel's handler keeps the order atomically, this component holds
    // no panel state, and the emission is synchronous exactly as the
    // inline calls were (the queue hand-over that follows still runs
    // after the settle, not before it).

    // ---- IN from the panel ----
    //
    // The UI language for the txn's translated refusals (§87/§79: a
    // dropped, refused or cancelled pick is said on the hint line).
    property string uiLang: "en"
    // The one visible-refusal channel (text, ms): the panel's hint
    // flash, called straight from the verdict arms exactly where the
    // monolith called it.
    property var flashRefused: null
    // The panel's process-group kill — the retiring discipline every
    // kill-restart process here shares: (proc) => void.
    property var killProcessGroup: null
    // The §88 lane facts, bound from the keyboard's frozen surface: the
    // paste chip's own paced/awaiting chord is the one flow that can
    // own the clipboard beside a txn, and request's gate reads both
    // exactly as the monolith read them off the keyboard.
    property bool pastePacing: false
    property var pasteFlow: null
    // The txn's chord rides keyboard.pasteCurrent with its completed
    // callback (§89 — the chordSeq captured at the dispatch stays in
    // the closure here): (wmClass, done) => void.
    property var pasteChordStart: null

    // ---- OUT to the panel ----
    //
    // The delivered verdict: usage recording, the search settle and the
    // close-after-pick read are the panel's, in the monolith's order.
    signal pickSettled(string emoji)

    // Emoji delivery through the clipboard (the one channel, §91).
    // The transaction lives in the pure ClipboardPaste.txn* machine;
    // these are only its processes and timers. One pick owns the
    // clipboard and its paste chord END TO END: a pick accepted while
    // another is unfinished queues in order, so a queued payload never
    // replaces the clipboard owner an unfinished paste still depends on,
    // and usage/settle/close fire only from the chord's real completion
    // (audit 2026-09-13 — the old code recorded success the instant the
    // paste was dispatched). The publisher stays alive as the selection
    // owner — killing it would recreate ticket 25's dead-owner behaviour;
    // the next pick replaces it, which is replacement, not loss. The
    // pick's payload is what replaces the clipboard.
    property var emojiTxnState: ClipboardPaste.txnInitial()

    Process {
        id: emojiClipboardPublish
        command: []
    }

    Process {
        id: emojiClipboardVerify
        property int seq: 0
        property bool retiring: false
        // head caps the stream (the security audit): a malicious clipboard
        // owner cannot balloon the shell's memory through the collector —
        // SIGPIPE closes wl-paste past the bound.
        command: ["setsid", "bash", "-c", "wl-paste --no-newline | head -c 65536"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (emojiClipboardVerify.retiring) return
                root.finishEmojiPublishVerify(
                    emojiClipboardVerify.seq, this.text)
            }
        }
        onExited: {
            if (emojiClipboardVerify.retiring) {
                emojiClipboardVerify.retiring = false
                // The kill's requester re-arms through us — but only for
                // a transaction that still wants a verify (the triage's
                // finding 6: an aborted txn's stray restart ran one
                // refused wl-paste for nothing).
                if (root.emojiTxnState.phase === "publishing")
                    emojiPublishVerifyTimer.restart()
            }
        }
    }

    Timer {
        id: emojiPublishVerifyTimer
        interval: 60
        repeat: false
        onTriggered: () => {
            // A kill in flight: the late stream of the DEAD run must not
            // verify the live transaction's pick (the cold-audit's
            // second finding — a premature chord). Wait it out; the
            // interval is short and the exit lands in a round or two.
            if (emojiClipboardVerify.retiring) {
                emojiPublishVerifyTimer.restart()
                return
            }
            if (emojiClipboardVerify.running) {
                // Kill only (finding 6): the retired exit re-arms the
                // timer; no inline restart racing the killed child.
                emojiClipboardVerify.retiring = true
                killProcessGroup(emojiClipboardVerify)
                return
            }
            emojiClipboardVerify.seq = root.emojiTxnState.seq
            emojiClipboardVerify.running = true
            emojiVerifyWatchdog.restart()
        }
    }

    // A clipboard owner that never finishes its read stalls the verify
    // forever (the review's third round): bounded like every other read,
    // the stalled run is group-killed and the pick drops — loudly, with
    // the queue handed over. Sequence-guarded, so a late wakeup for a
    // verify the machine has already left changes nothing.
    Timer {
        id: emojiVerifyWatchdog
        interval: 3000
        repeat: false
        onTriggered: () => {
            var timedOut = ClipboardPaste.txnVerifyTimedOut(root.emojiTxnState,
                emojiClipboardVerify.seq)
            root.emojiTxnState = timedOut.state
            if (timedOut.action !== "drop") return
            killProcessGroup(emojiClipboardVerify)
            console.warn("[oskar] emoji verify stalled — pick dropped,"
                + " the clipboard keeps whatever it holds")
            // §87: a dropped pick is the user's click vanishing — the
            // same silence the chord refusal used to be. Flash it.
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
            startNextEmojiTxn()
        }
    }

    function request(emoji, clientClass) {
        // The fifth serialization lane (§88): the paste CHIP's own
        // paced/awaiting chord owns the clipboard right now (it is not
        // a txn — the txn machine never saw it), and this pick's very
        // first act is wl-copy replacing what that chord is about to
        // paste. Refuse visibly, the sub-second window closes.
        // "txn idle" is load-bearing (§89): the txn's OWN chord is
        // already serialized by the txn machine's queue — refusing
        // here too converted queued picks into lost clicks. A chip
        // chord can never coexist with a live txn (the chip refuses
        // on the txn phase), so this narrows the gate to exactly the
        // chip-owned flows without reopening the lane.
        if ((root.pastePacing
                || root.pasteFlow.phase !== "idle")
                && root.emojiTxnState.phase === "idle") {
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
            return
        }
        // Ticket 56: the client class is derived ONCE, at the pick —
        // the click's own moment, in the panel's dispatch, the same
        // derivation the paste chord's shape table keys on — and
        // arrives here as the request's clientClass argument, riding
        // the payload through publish, verify and chord. The old shape
        // re-derived it when the verify landed, and that second opinion
        // could disagree with the click's (the IME matrix's kitty
        // cell: the chord landed wine-shaped, no Shift, no "paste
        // chord for kitty" line) because focus and the lastClientClass
        // fallback both move under a transaction that spans hundreds
        // of milliseconds. One derivation, one table — the arrival
        // dispatches for the class stored here.
        var picked = ClipboardPaste.txnPick(root.emojiTxnState, emoji,
            clientClass)
        root.emojiTxnState = picked.state
        if (picked.action === "queued") {
            console.log("[oskar] emoji pick queued behind an unfinished paste")
            return
        }
        if (picked.action === "refused") {
            console.warn("[oskar] emoji pick refused: empty payload")
            return
        }
        if (picked.action === "refused-full") {
            console.warn("[oskar] emoji pick refused: three already queued"
                + " behind an unfinished paste")
            // The same visible refusal every refused click since the
            // flows review's N1 has had: silence is the trust killer.
            root.emojiPickRefused = true
            emojiPickRefuseTimer.restart()
            return
        }
        beginEmojiPublish(emoji)
    }

    // The visible refusal (P2's other half): an accent flash on the hint
    // line, auto-cleared after the clipboard-gone notice's own beat.
    property bool emojiPickRefused: false
    Timer {
        id: emojiPickRefuseTimer
        interval: 1500
        repeat: false
        onTriggered: root.emojiPickRefused = false
    }

    // The effects of one accepted pick: replace the clipboard owner, then
    // verify. Called for the first pick and for every pick the queue
    // hands over — never for a pick still waiting its turn.
    function beginEmojiPublish(emoji) {
        if (emojiClipboardPublish.running)
            emojiClipboardPublish.running = false
        emojiClipboardPublish.command = ["wl-copy", "--foreground", "--", emoji]
        emojiClipboardPublish.running = true
        emojiPublishVerifyTimer.restart()
    }

    function finishEmojiPublishVerify(seq, served) {
        var result = ClipboardPaste.txnServed(root.emojiTxnState, seq, served)
        root.emojiTxnState = result.state
        if (result.action === "stale") return
        // A real answer disarms the watchdog: only a read that never
        // finishes is the watchdog's to judge.
        emojiVerifyWatchdog.stop()
        if (result.action === "retry") {
            emojiPublishVerifyTimer.restart()
            return
        }
        if (result.action === "drop") {
            console.warn("[oskar] emoji clipboard publication not confirmed;"
                + " pick dropped, no chord sent")
            // §87: the drop is the click vanishing — flash, don't
            // journal.
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
            startNextEmojiTxn()
            return
        }
        // "chord": the transaction owns the paste. Usage, search settle
        // and close-after-pick wait for the chord's real completion — a
        // paced wine chord is still draining line by line when dispatch
        // returns, and a refusal (a busy pacer, an unready helper, a
        // socket that died mid-chord) is reported to the callback instead
        // of passing unnoticed. The emoji stays published; if the chord
        // never completes, manual Ctrl+V remains possible.
        //
        // Ticket 56: the chord is derived for the class the PICK carried
        // (result.state.clientClass) — never re-derived from whoever holds
        // focus by the time the clipboard transaction landed.
        //
        // The completion carries the transaction's seq, captured HERE:
        // a cancelled pick's late reply must land stale, not complete
        // whichever pick owns the machine by then (round seven).
        var chordSeq = result.state.seq
        root.pasteChordStart(result.state.clientClass, function (success) {
            finishEmojiChord(chordSeq, success)
        })
    }

    // The chord's verdict. Only a real completion records usage, settles
    // the search and closes the page; a cancellation leaves all three
    // alone. A completion arriving for a cancelled transaction (only
    // the tests cancel now — the delivery-mode flip that once did this
    // is §91 history) lands as "ignore" or "stale" and records
    // nothing, then the queue — empty after a cancel — hands over nothing.
    function finishEmojiChord(seq, success) {
        var done = ClipboardPaste.txnChordDone(root.emojiTxnState, seq, success)
        root.emojiTxnState = done.state
        if (done.action === "completed") {
            // The completed verdict crosses the seam as the one signal:
            // usage, the search settle and the close-after-pick read
            // are the panel's — its handler, the monolith's order,
            // synchronous here.
            root.pickSettled(done.emoji)
        } else if (done.action === "cancelled") {
            console.warn("[oskar] emoji paste chord refused or aborted;"
                + " no usage recorded (the clipboard keeps the pick)")
            // Same silence class the round has been closing, one layer
            // down (the diff audit's finding): the queue caps and the
            // paste chip flash their refusals — a pick whose chord
            // never dispatched must not be the one click that vanishes
            // without a word.
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
        }
        startNextEmojiTxn()
    }

    function startNextEmojiTxn() {
        var next = ClipboardPaste.txnNext(root.emojiTxnState)
        root.emojiTxnState = next.state
        if (next.action === "publish") beginEmojiPublish(next.emoji)
    }
}
