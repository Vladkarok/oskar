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
// client. The colour field wins if both are somehow active: the page
// replaces the card on open, so the pair is a state the panel does not
// produce, and the precedence is stated rather than assumed.
function pasteTarget(hexEditing, emojiOpen) {
    if (hexEditing) return "colour-field"
    if (emojiOpen) return "emoji-search"
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

// Ticket 28's publish-verify-chord machine, extracted after review: one
// pick in flight at a time, every verify run sequence-tagged (a killed
// run's late empty answer carries an old sequence and counts for nothing,
// where the first in-QML cut let it burn a retry), five attempts, then a
// loud drop with no chord.
function publishInitial() {
    return { seq: 0, pending: "", attempts: 0 }
}

function publishStart(state, emoji) {
    return {
        state: { seq: state.seq + 1, pending: String(emoji || ""), attempts: 0 },
        action: state.pending !== "" ? "publish-superseding" : "publish"
    }
}

function publishServed(state, seq, served) {
    if (!state.pending || seq !== state.seq)
        return { state: state, action: "stale" }
    if (String(served) === state.pending)
        return { state: state, action: "chord" }
    var attempts = state.attempts + 1
    if (attempts >= 5)
        return {
            state: { seq: state.seq, pending: "", attempts: 0 },
            action: "drop"
        }
    // A retry is a NEW verify run: the sequence moves, so the answer of
    // the wl-paste this retry is about to kill cannot masquerade as it.
    return {
        state: { seq: state.seq + 1, pending: state.pending, attempts: attempts },
        action: "retry"
    }
}

function publishCancel(state) {
    if (!state.pending)
        return { state: state, action: "ignore" }
    return {
        state: { seq: state.seq, pending: "", attempts: 0 },
        action: "dropped"
    }
}
