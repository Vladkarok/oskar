.pragma library

// Paste target determination (review R2) and the panel-local read's
// correlation. The processes live in Panel.qml; the pure state machine
// here owns the target rule and the read's lifecycle, so a local read can
// never insert into a target that closed.
//
// The external paste itself carries no pre-flight: the click sends its
// chord unconditionally (decisions §41). Ticket 25's liveness probe and
// its state machine were removed by the same owner verdict.

// One target determination before any delivery choice (R2): a paste click
// lands in whichever panel-local input is active — the colour field, or
// the emoji page whose search the keys are typing into while it is open —
// and only a panel with no local input delivers the chord to the focused
// client. The armed search wins if both are somehow active: opening a
// field disarms the search, so the pair is a state the panel does not
// produce, and the precedence is stated rather than assumed.
//
// The colour target carries the WHOLE identity (rounds 13-14): the
// surface that owns the field — popover or the custom editor, which can
// both be editing `textColor` — and the field itself. A read started for
// one surface's field must not land in another's when focus moves
// mid-read; the arrival guard refuses exactly that.
function pasteTargetFor(emojiArmed, hexEditing, hexField, customEditorOpen) {
    if (emojiArmed) return "emoji-search"
    if (hexEditing)
        return "colour:" + (customEditorOpen ? "editor" : "popover")
            + ":" + hexField
    return "external-client"
}

// The panel-local read (colour field, emoji search) owes the probe's own
// discipline: wl-paste blocks on a dead selection owner, so the read is
// bounded by its caller's watchdog and force-killed on timeout, and an
// answer arriving for a target that closed or was replaced inserts
// nothing. The caller passes the CURRENT target determination back at
// arrival. The selection generation is deliberately not carried over
// from the probe: a local insert uses exactly the bytes this read
// returned, so a selection that changed mid-read inserts its own new
// content, never a remembered preview.
function readInitial() {
    return { seq: 0, pending: false, target: "" }
}

function readStart(state, target) {
    if (state.pending)
        return { state: state, action: "ignore" }
    return {
        state: { seq: state.seq + 1, pending: true, target: String(target || "") },
        action: "read"
    }
}

function readSettled(state) {
    return { seq: state.seq, pending: false, target: "" }
}

function readExited(state, seq, target) {
    if (!state.pending || seq !== state.seq)
        return { state: state, action: "ignore" }
    var next = readSettled(state)
    if (String(target || "") !== state.target)
        return { state: next, action: "target-changed" }
    return { state: next, action: "insert" }
}

function readTimedOut(state, seq, target) {
    if (!state.pending || seq !== state.seq)
        return { state: state, action: "ignore" }
    return {
        state: readSettled(state),
        action: String(target || "") === state.target ? "gone" : "target-changed",
        // Host contract: an accepted timeout always force-kills its Process.
        kill: true
    }
}

// The delivery transaction (ticket 28, §91's one channel): one pick owns the
// clipboard and its paste chord end to end. A pick accepted while another
// is unfinished queues IN ORDER — a queued payload must never replace the
// clipboard owner an unfinished paste still depends on (the audit's A→B
// race: B's wl-copy replaced A before A's paced Ctrl+V reached the client,
// and both were recorded as success). Usage, search settle and
// close-after-pick fire only from the chord's completion, which
// Keyboard.pasteCurrent reports; a refused or aborted dispatch is a
// cancellation, never a success.
//
// The phases: "idle" accepts a pick, "publishing" owns the wl-copy and the
// verify rounds, "pasting" owns the chord dispatch. Every verify run stays
// sequence-tagged (a killed run's late answer carries an old sequence and
// counts for nothing), five attempts then a loud drop with no chord, and a
// drop or cancellation hands the machine to the next queued pick.
//
// Ticket 56: a pick carries the CLIENT CLASS it was clicked for, from the
// click to its chord. The class is derived once, at the pick — the click's
// own moment, the same derivation the paste chord's shape table uses — and the
// arrival dispatches with the carried value. The old shape re-derived the
// class when the verify landed, and that second opinion could disagree
// with the click's (the IME matrix's kitty cell: the chord arrived
// wine-shaped). Queued picks queue `{emoji, clientClass}` pairs, so
// promotion is not a re-derivation either; terminal outcomes carry nothing.
function txnInitial() {
    return { seq: 0, phase: "idle", pending: "", clientClass: "",
        attempts: 0, queue: [] }
}

function txnPick(state, emoji, clientClass) {
    var payload = String(emoji || "")
    var cls = String(clientClass || "")
    // An empty payload is refused rather than queued: nothing could ever
    // verify against it, and a transaction that can neither serve nor
    // drop would wedge every pick behind it (review finding).
    if (payload === "")
        return { state: state, action: "refused" }
    if (state.phase !== "idle" || state.pending !== "") {
        // How many picks may wait behind the running one (the review's
        // third round): a stalled transaction used to accumulate picks
        // without end — the fourth is refused at the door, loudly, rather
        // than wedged quietly behind whatever never finishes.
        if (state.queue.length >= 3)
            return { state: state, action: "refused-full" }
        return {
            state: {
                seq: state.seq, phase: state.phase, pending: state.pending,
                clientClass: state.clientClass, attempts: state.attempts,
                queue: state.queue.concat([{ emoji: payload, clientClass: cls }])
            },
            action: "queued"
        }
    }
    return {
        state: {
            seq: state.seq + 1, phase: "publishing", pending: payload,
            clientClass: cls, attempts: 0, queue: state.queue
        },
        action: "publish"
    }
}

// The verify watchdog's verdict (finding 2's first half): a clipboard
// owner that never finishes its read stalls the verify forever, so the
// caller's timeout is a terminal drop — the same shape the five-mismatch
// limit already made, loud, no chord, the queue handed over. A stale
// sequence (the timeout describes a verify the machine no longer holds)
// changes nothing.
function txnVerifyTimedOut(state, seq) {
    if (state.phase !== "publishing" || state.pending === ""
            || seq !== state.seq)
        return { state: state, action: "ignore" }
    return {
        state: { seq: state.seq, phase: "idle", pending: "", clientClass: "",
            attempts: 0, queue: state.queue },
        action: "drop"
    }
}

function txnServed(state, seq, served) {
    if (state.phase !== "publishing" || state.pending === "" || seq !== state.seq)
        return { state: state, action: "stale" }
    if (String(served) === state.pending)
        return {
            state: {
                seq: state.seq, phase: "pasting", pending: state.pending,
                clientClass: state.clientClass, attempts: state.attempts,
                queue: state.queue
            },
            action: "chord"
        }
    var attempts = state.attempts + 1
    if (attempts >= 5)
        return {
            state: {
                seq: state.seq, phase: "idle", pending: "", clientClass: "",
                attempts: 0, queue: state.queue
            },
            action: "drop"
        }
    // A retry is a NEW verify run: the sequence moves, so the answer of
    // the wl-paste this retry is about to kill cannot masquerade as it.
    return {
        state: {
            seq: state.seq + 1, phase: "publishing", pending: state.pending,
            clientClass: state.clientClass, attempts: attempts,
            queue: state.queue
        },
        action: "retry"
    }
}

// The chord's verdict, delivered by pasteCurrent's completion callback.
// Only "completed" carries the emoji: it is the one outcome that may
// record usage, settle the search and close the page.
//
// The `seq` is the transaction the CALLBACK was armed for — captured at
// dispatch, compared here (round seven: a cancelled A's late reply used
// to complete a live B, because the machine's phase said "pasting" and
// nothing said WHOSE pasting). A seq that is not the machine's own means
// the verdict belongs to a transaction already cancelled or handed over:
// it lands as "stale" and changes nothing.
function txnChordDone(state, seq, success) {
    if (state.phase !== "pasting")
        return { state: state, action: "ignore" }
    if (seq !== state.seq)
        return { state: state, action: "stale" }
    var idle = {
        seq: state.seq, phase: "idle", pending: "", clientClass: "",
        attempts: 0, queue: state.queue
    }
    return success === true
        ? { state: idle, action: "completed", emoji: state.pending }
        : { state: idle, action: "cancelled" }
}

// Starts the next queued pick after a terminal outcome. Called by the QML
// glue once per ending; returns "publish" with the emoji to publish, or
// "none" when the machine is empty. The sequence keeps counting up, so a
// verify answer from any earlier transaction stays stale forever, and the
// rest of the queue keeps its order behind the promoted pick. The promoted
// pick brings its OWN click-time class: promotion is the queue handing
// over, never a fresh derivation.
function txnNext(state) {
    if (state.phase !== "idle" || state.queue.length === 0)
        return { state: state, action: "none" }
    var pick = state.queue[0]
    var next = {
        seq: state.seq + 1, phase: "publishing", pending: pick.emoji,
        clientClass: pick.clientClass, attempts: 0,
        queue: state.queue.slice(1)
    }
    return { state: next, action: "publish", emoji: pick.emoji }
}

// Cancel the running pick and everything queued (§91 history: the
// delivery-mode flip — the only caller txnCancel ever had — is gone,
// and the old doc's "teardown" caller never existed; this is
// test-pinned semantics now, kept so a future cancel path inherits a
// proven machine). A chord already dispatching cannot be
// un-dispatched; its late completion lands on the idle machine as
// "ignore" and records nothing.
function txnCancel(state) {
    if (state.phase === "idle" && state.queue.length === 0)
        return { state: state, action: "ignore" }
    return {
        state: { seq: state.seq, phase: "idle", pending: "", clientClass: "",
            attempts: 0, queue: [] },
        action: "dropped"
    }
}

// What an interrupted paced chord owes the device: an "up" for every
// "down" the abort's prefix pressed without pairing, in reverse press
// order. A prefix "up" whose restoring "down" never went out is owed
// NOTHING here — an aborted transaction converges by lifting (the caller
// follows with a releaseAll), never by re-pressing a lock whose state the
// abort is about to reset anyway.
function compensatingReleases(lines, sentCount) {
    var chord = Array.isArray(lines) ? lines : []
    var sent = chord.slice(0, Math.max(0, Math.min(sentCount, chord.length)))
    var open = []
    // A leading "up" the chord itself plans to restore: its pairing
    // "down" is a restore, not a new press, so it must not read as owed.
    var lifted = []
    for (var i = 0; i < sent.length; i++) {
        var line = String(sent[i])
        if (line.indexOf("down ") === 0) {
            var pressed = line.slice(5)
            if (lifted.indexOf(pressed) !== -1)
                lifted.splice(lifted.indexOf(pressed), 1)
            else
                open.push(pressed)
        } else if (line.indexOf("up ") === 0) {
            var rising = line.slice(3)
            if (open.indexOf(rising) !== -1)
                open.splice(open.indexOf(rising), 1)
            else
                lifted.push(rising)
        }
    }
    var releases = []
    for (var r = open.length - 1; r >= 0; r--)
        releases.push("up " + open[r])
    return releases
}
