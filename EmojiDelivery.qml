import QtQuick
import Quickshell.Io
import "ClipboardPaste.js" as ClipboardPaste
import "UiStrings.js" as UiStrings

Item {
    id: root

    // The emoji delivery transaction's machinery: the wl-copy publisher,
    // the verify pipeline (its Process, the re-arm timer, the 3 s
    // watchdog), the verdict arms, the queue's hand-over and the
    // queue-cap flash flag — the QML half of the machine whose
    // invariants live in the pure ClipboardPaste.txn* machine. What
    // stayed in the panel is everything a pick is ABOUT: the
    // onEmojiChosen dispatch (tone resolution, the armed-search disarm,
    // and the ONE client-class derivation at the click, handed in as
    // request()'s clientClass argument and never re-derived here), the
    // refusal flashing (flashRefused, bound IN — the one hint channel
    // stays the panel's), the usage recording and the delivered pick's
    // settle and close (the pickSettled signal below), and the paste
    // chip's gate on the txn phase (emojiTxnState stays exposed under
    // its own name for that read, and emojiPickRefused for the hint
    // table's).
    //
    // The verdict seam is ONE signal carrying the emoji rather than a
    // callback per effect (usage, the search settle, the close-after-pick
    // read): the panel's handler keeps the order atomically, this
    // component holds no panel state, and the emission is synchronous so
    // the queue hand-over that follows still runs after the settle, not
    // before it.

    // ---- IN from the panel ----
    //
    // The UI language for the txn's translated refusals (a dropped,
    // refused or cancelled pick is said on the hint line).
    property string uiLang: "en"
    // The one visible-refusal channel (text, ms): the panel's hint
    // flash, called straight from the verdict arms.
    property var flashRefused: null
    // The panel's process-group kill — the retiring discipline every
    // kill-restart process here shares: (proc) => void.
    property var killProcessGroup: null
    // The lane facts, bound from the keyboard's frozen surface: the
    // paste chip's own paced/awaiting chord is the one flow that can own
    // the clipboard beside a txn, and request's gate reads both.
    property bool pastePacing: false
    property var pasteFlow: null
    // The txn's chord rides keyboard.pasteCurrent with its completed
    // callback (the chordSeq captured at the dispatch stays in the
    // closure here): (wmClass, done) => void.
    property var pasteChordStart: null

    // ---- OUT to the panel ----
    //
    // The delivered verdict: usage recording, the search settle and the
    // close-after-pick read are the panel's, in a fixed order.
    signal pickSettled(string emoji)

    // Emoji delivery through the clipboard (the one channel).
    // The transaction lives in the pure ClipboardPaste.txn* machine;
    // these are only its processes and timers. One pick owns the
    // clipboard and its paste chord END TO END: a pick accepted while
    // another is unfinished queues in order, so a queued payload never
    // replaces the clipboard owner an unfinished paste still depends on,
    // and usage/settle/close fire only from the chord's real completion,
    // never from the paste's dispatch. The pick's payload is what replaces
    // the clipboard; a pick that fails puts back what the clipboard held
    // before it while the clipboard is still OSKar's (ClipboardPaste's
    // `restore`).
    property var emojiTxnState: ClipboardPaste.txnInitial()

    // Clipboard text read by a Process lingers in its collector until the
    // next run. A collector's text cannot be cleared, so once a read has
    // been used its collector is replaced by an empty one.
    Component {
        id: collectorFactory
        StdioCollector { waitForEnd: true }
    }
    function freshCollector(proc) {
        var old = proc.stdout
        proc.stdout = collectorFactory.createObject(proc)
        if (old) old.destroy()
    }

    // The one way OSKar puts text on the clipboard, for a pick and for a
    // restore alike. The text rides wl-copy's stdin, never its argv (argv
    // is readable by every local user for as long as the owner lives).
    // wl-copy without --foreground reads the text, forks, and its child
    // serves the selection until something replaces it: the owner is not
    // this shell's tracked child, so the content outlives a shell restart
    // or the plugin being disabled. This Process lives only until that
    // fork; the verify reads the clipboard itself, never the process.
    Process {
        id: emojiClipboardPublish
        command: ["wl-copy", "--type", "text/plain;charset=utf-8"]
        stdinEnabled: true
        property string payload: ""
        onStarted: {
            write(payload)
            stdinEnabled = false
            // Handed to wl-copy; no copy of it stays here.
            payload = ""
        }
    }

    function publishClipboard(text) {
        if (emojiClipboardPublish.running)
            emojiClipboardPublish.running = false
        emojiClipboardPublish.payload = text
        emojiClipboardPublish.stdinEnabled = true
        emojiClipboardPublish.running = true
    }

    Process {
        id: emojiClipboardVerify
        property int seq: 0
        property bool retiring: false
        // The shared reader (ClipboardPaste.READ_SCRIPT): capped, and
        // content marked secret is never read — its empty answer is a
        // mismatch.
        command: ["setsid", "bash", "-c", ClipboardPaste.READ_SCRIPT]
        stdout: StdioCollector { waitForEnd: true }
        // The collector's stream lands before exited, so its text is this
        // run's answer; a retired (killed) run's answer is not.
        onExited: {
            if (!emojiClipboardVerify.retiring) {
                var served = emojiClipboardVerify.stdout.text
                root.freshCollector(emojiClipboardVerify)
                root.finishEmojiPublishVerify(emojiClipboardVerify.seq, served)
                return
            }
            root.freshCollector(emojiClipboardVerify)
            if (emojiClipboardVerify.retiring) {
                emojiClipboardVerify.retiring = false
                // The kill's requester re-arms through us — but only for
                // a transaction that still wants a verify, so an aborted
                // txn does not run a refused wl-paste for nothing.
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
            // verify the live transaction's pick. Wait it out; the
            // interval is short and the exit lands soon.
            if (emojiClipboardVerify.retiring) {
                emojiPublishVerifyTimer.restart()
                return
            }
            if (emojiClipboardVerify.running) {
                // Kill only: the retired exit re-arms the timer; no inline
                // restart racing the killed child.
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
    // forever: bounded like every other read, the stalled run is
    // group-killed and the pick drops — loudly, with the queue handed
    // over. Sequence-guarded, so a late wakeup for a verify the machine
    // has already left changes nothing.
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
            console.warn("[oskar] emoji verify stalled — pick dropped")
            restoreClipboard(timedOut.restore)
            // A dropped pick is the user's click vanishing; flash it
            // rather than let it pass in silence.
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
            startNextEmojiTxn()
        }
    }

    // `before` is the panel's answer to "may this pick read the clipboard
    // for its snapshot?" (ClipboardPaste.snapshotPlan): "read", or the
    // snapshot it gets without one.
    function request(emoji, clientClass, before) {
        // The paste CHIP's own paced/awaiting chord owns the clipboard
        // right now (it is not a txn — the txn machine never saw it),
        // and this pick's very first act is wl-copy replacing what that
        // chord is about to paste. Refuse visibly, the sub-second window
        // closes.
        // "txn idle" is load-bearing: the txn's OWN chord is already
        // serialized by the txn machine's queue — refusing here too would
        // convert queued picks into lost clicks. A chip chord can never
        // coexist with a live txn (the chip refuses on the txn phase), so
        // this narrows the gate to exactly the chip-owned flows without
        // reopening the lane.
        if ((root.pastePacing
                || root.pasteFlow.phase !== "idle")
                && root.emojiTxnState.phase === "idle") {
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
            return
        }
        // The client class is derived ONCE, at the pick — the click's own
        // moment, in the panel's dispatch, the same derivation the paste
        // chord's shape table keys on — and arrives here as the
        // request's clientClass argument, riding the payload through
        // publish, verify and chord. Re-deriving it when the verify lands
        // can disagree with the click's, because focus and the
        // lastClientClass fallback both move under a transaction that
        // spans hundreds of milliseconds. One derivation, one table — the
        // arrival dispatches for the class stored here.
        var picked = ClipboardPaste.txnPick(root.emojiTxnState, emoji,
            clientClass, before)
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
            // The same visible refusal every refused click has: silence
            // is the trust killer.
            root.emojiPickRefused = true
            emojiPickRefuseTimer.restart()
            return
        }
        if (picked.action === "snapshot") {
            startSnapshotRead(picked.state.seq)
            return
        }
        beginEmojiPublish(emoji)
    }

    // The pick's snapshot: one read by the shared reader, at the pick and
    // before anything is published, bounded short. Its text lives in the
    // transaction only, which drops it when it settles.
    Process {
        id: emojiSnapshotRead
        property int seq: 0
        command: ["setsid", "bash", "-c", ClipboardPaste.READ_SCRIPT]
        stdout: StdioCollector { waitForEnd: true }
        onExited: function (exitCode) {
            var text = emojiSnapshotRead.stdout.text
            root.freshCollector(emojiSnapshotRead)
            if (!emojiSnapshotWatchdog.running) return
            emojiSnapshotWatchdog.stop()
            root.finishSnapshot(emojiSnapshotRead.seq,
                ClipboardPaste.snapshotFromRead(exitCode, text))
        }
    }
    Timer {
        id: emojiSnapshotWatchdog
        interval: 400
        repeat: false
        onTriggered: {
            killProcessGroup(emojiSnapshotRead)
            console.log("[oskar] the clipboard did not answer in time; this pick"
                + " goes on without a snapshot and a failure will not restore it")
            root.finishSnapshot(emojiSnapshotRead.seq, { none: "unread" })
        }
    }
    function startSnapshotRead(seq) {
        emojiSnapshotRead.seq = seq
        emojiSnapshotWatchdog.restart()
        emojiSnapshotRead.running = true
        if (!emojiSnapshotRead.running) {
            emojiSnapshotWatchdog.stop()
            root.finishSnapshot(seq, { none: "unread" })
        }
    }
    function finishSnapshot(seq, before) {
        var step = ClipboardPaste.txnSnapshotted(root.emojiTxnState, seq, before)
        root.emojiTxnState = step.state
        if (step.action === "publish") beginEmojiPublish(step.emoji)
    }

    // The visible refusal: an accent flash on the hint line, auto-cleared
    // after a beat.
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
        publishClipboard(emoji)
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
            restoreClipboard(result.restore)
            // The drop is the click vanishing — flash, don't
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
        // The chord is derived for the class the PICK carried
        // (result.state.clientClass) — never re-derived from whoever holds
        // focus by the time the clipboard transaction landed.
        //
        // The completion carries the transaction's seq, captured HERE:
        // a cancelled pick's late reply must land stale, not complete
        // whichever pick owns the machine by then.
        var chordSeq = result.state.seq
        root.pasteChordStart(result.state.clientClass, function (success) {
            finishEmojiChord(chordSeq, success)
        })
    }

    // The chord's verdict. Only a real completion records usage, settles
    // the search and closes the page; a cancellation leaves all three
    // alone. A completion arriving for a cancelled transaction — only the
    // tests cancel now — lands as "ignore" or "stale" and records
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
                + " no usage recorded")
            restoreClipboard(done.restore)
            // The same silence class as the queue caps and the paste
            // chip: a pick whose chord never dispatched must not be
            // the one click that vanishes without a word.
            root.flashRefused(UiStrings.tr("hint.pickFailed", root.uiLang))
        }
        startNextEmojiTxn()
    }

    // A failed pick's debt to the clipboard (ClipboardPaste's `restore`):
    // `{ text }` is published the way a pick is; `{ check }` reads the
    // clipboard once first, and the machine decides from what it serves;
    // `{ none }` leaves the clipboard as it is and says why; null means a
    // queued pick takes the clipboard next and its own outcome decides.
    function restoreClipboard(restore) {
        if (!restore) return
        if (restore.check !== undefined) {
            startRestoreCheck(restore.check)
            return
        }
        if (restore.text === undefined) {
            if (restore.none === "secret")
                console.log("[oskar] the clipboard keeps the failed pick: its"
                    + " previous content was marked secret by a password manager,"
                    + " so it was never read and is not republished")
            else if (restore.none === "foreign")
                console.log("[oskar] the clipboard keeps what it holds: it changed"
                    + " during the failed pick, and that content is not OSKar's to replace")
            else if (restore.none !== "unchanged")
                console.log("[oskar] the clipboard keeps the failed pick: its"
                    + " previous content could not be put back (" + restore.none + ")")
            return
        }
        publishClipboard(restore.text)
        console.log("[oskar] the failed pick's clipboard is put back")
    }

    // The restore check: one bounded read of the clipboard, by the shared
    // reader, answered to the machine by id — a pick that starts meanwhile
    // makes the answer stale.
    Process {
        id: emojiRestoreCheck
        property int checkId: 0
        command: ["setsid", "bash", "-c", ClipboardPaste.READ_SCRIPT]
        stdout: StdioCollector { waitForEnd: true }
        // A check that must wait for a killed run's exit before the
        // Process can start again.
        property int queuedId: 0
        onExited: function (exitCode) {
            emojiRestoreCheckWatchdog.stop()
            // A killed run answers null for its own id, which the machine
            // has already moved past: stale, and nothing is written.
            var served = exitCode === 0 ? emojiRestoreCheck.stdout.text : null
            root.freshCollector(emojiRestoreCheck)
            root.finishRestoreCheck(emojiRestoreCheck.checkId, served,
                exitCode === ClipboardPaste.READ_SECRET_EXIT)
            if (emojiRestoreCheck.queuedId !== 0) {
                var id = emojiRestoreCheck.queuedId
                emojiRestoreCheck.queuedId = 0
                root.startRestoreCheck(id)
            }
        }
    }
    Timer {
        id: emojiRestoreCheckWatchdog
        interval: 1000
        repeat: false
        onTriggered: {
            killProcessGroup(emojiRestoreCheck)
            root.finishRestoreCheck(emojiRestoreCheck.checkId, null, false)
        }
    }
    function startRestoreCheck(id) {
        if (emojiRestoreCheck.running) {
            emojiRestoreCheck.queuedId = id
            killProcessGroup(emojiRestoreCheck)
            return
        }
        emojiRestoreCheck.checkId = id
        emojiRestoreCheck.running = true
        emojiRestoreCheckWatchdog.restart()
    }
    function finishRestoreCheck(id, served, secret) {
        var checked = ClipboardPaste.txnRestoreChecked(root.emojiTxnState, id, served, secret)
        root.emojiTxnState = checked.state
        if (checked.action === "checked") restoreClipboard(checked.restore)
    }

    function startNextEmojiTxn() {
        var next = ClipboardPaste.txnNext(root.emojiTxnState)
        root.emojiTxnState = next.state
        if (next.action === "publish") beginEmojiPublish(next.emoji)
    }
}
