.pragma library

// Paste target determination and the panel-local read's correlation. The
// processes live in Panel.qml; the pure state machine here owns the
// target rule and the read's lifecycle, so a local read can never insert
// into a target that closed.
//
// The external paste itself carries no pre-flight: the click sends its
// chord unconditionally.

// One target determination before any delivery choice: a paste click
// lands in whichever panel-local input is active — the colour field, or
// the emoji page whose search the keys are typing into while it is open —
// and only a panel with no local input delivers the chord to the focused
// client. The armed search wins if both are somehow active: opening a
// field disarms the search, so the pair is a state the panel does not
// produce, and the precedence is stated rather than assumed.
//
// The colour target carries the WHOLE identity: the surface that owns the
// field — popover or the custom editor, which can both be editing
// `textColor` — and the field itself. A read started for one surface's
// field must not land in another's when focus moves mid-read; the arrival
// guard refuses exactly that.
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

// The delivery transaction: one pick owns the clipboard and its paste
// chord end to end. A pick accepted while another is unfinished queues IN
// ORDER — a queued payload must never replace the clipboard owner an
// unfinished paste still depends on (otherwise a second wl-copy can
// replace the first before its paced Ctrl+V reaches the client, and both
// get recorded as success). Usage, search settle and close-after-pick
// fire only from the chord's completion, which Keyboard.pasteCurrent
// reports; a refused or aborted dispatch is a cancellation, never a
// success.
//
// The phases: "idle" accepts a pick, "publishing" owns the wl-copy and the
// verify rounds, "pasting" owns the chord dispatch. Every verify run stays
// sequence-tagged (a killed run's late answer carries an old sequence and
// counts for nothing), five attempts then a loud drop with no chord, and a
// drop or cancellation hands the machine to the next queued pick.
//
// A pick carries the CLIENT CLASS it was clicked for, from the click to
// its chord. The class is derived once, at the pick — the click's own
// moment, the same derivation the paste chord's shape table uses — and
// the arrival dispatches with the carried value; it must never be
// re-derived when the verify lands, since that second opinion can
// disagree with the click's. Queued picks queue `{emoji, clientClass}`
// pairs, so promotion is not a re-derivation either; terminal outcomes
// carry nothing.
//
// The clipboard a pick replaces. A delivered pick leaves its emoji in the
// clipboard — that is how an emoji picker works, and putting the old
// content back after the paste would race the client still reading it.
// A pick that FAILS puts back what the clipboard held before it: `before`
// is that content, `{ text }` when the panel could read it as text, or
// `{ none: why }` when it could not be put back (see restoreSnapshot).
// The first pick of a burst brings the panel's snapshot; a delivered pick
// makes its own emoji the next pick's `before`; a failed one leaves
// `before` as it was. Every terminal failure that leaves the machine idle
// carries `restore` — `{ text }` to publish, or `{ none: why }` to say in
// the journal that the clipboard stays as it is. A failure with a queued
// pick behind it carries `restore: null`: the next pick replaces the
// clipboard anyway, and its own outcome decides.
function txnInitial() {
    return { seq: 0, phase: "idle", pending: "", clientClass: "",
        attempts: 0, queue: [], before: { none: "unread" } }
}

function txnWith(state, changes) {
    var next = {
        seq: state.seq, phase: state.phase, pending: state.pending,
        clientClass: state.clientClass, attempts: state.attempts,
        queue: state.queue, before: state.before
    }
    for (var key in changes) next[key] = changes[key]
    return next
}

function txnIdle(state, changes) {
    var idle = txnWith(state, { phase: "idle", pending: "", clientClass: "",
        attempts: 0 })
    return changes ? txnWith(idle, changes) : idle
}

function snapshotOf(before) {
    if (before && typeof before.text === "string" && before.text !== "")
        return { text: before.text }
    return { none: before && typeof before.none === "string" ? before.none : "unread" }
}

// What a terminal failure owes the clipboard: nothing while a queued pick
// is about to replace it, otherwise the snapshot. `served` is the verify's
// last read, when there was one: a clipboard already holding the snapshot
// needs nothing written.
function restoreFor(state, served) {
    if (state.queue.length > 0) return null
    var before = snapshotOf(state.before)
    if (before.text !== undefined && served !== undefined && String(served) === before.text)
        return { none: "unchanged" }
    return before
}

// The panel's clipboard reading, as a snapshot a failed pick could put
// back. `kind` and `text` are the paste chip's reading (Panel.qml's
// wl-paste probe), `textSeq` the sequence its text was read under and
// `currentSeq` the newest one; `refreshing` says a read is in flight. The
// reading is current only when no read is in flight and the text belongs
// to the newest sequence — the chip's watch re-reads on every change, so
// that is the moment it describes the clipboard as it is. Text past the
// reading's own cap (a 65536-byte stream) may be cut short, so it is not
// put back; neither is anything that is not text, nor content a password
// manager marked secret (kind "hidden"): it was never read, and
// republishing it would leave a secret as plain text owned by OSKar.
var SNAPSHOT_CAP = 65536

function utf8Length(text) {
    var bytes = 0
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i)
        if (code < 0x80) bytes += 1
        else if (code < 0x800) bytes += 2
        else if (code >= 0xd800 && code <= 0xdbff) { bytes += 4; i += 1 }
        else bytes += 3
    }
    return bytes
}

function restoreSnapshot(kind, text, textSeq, currentSeq, refreshing) {
    if (kind === "hidden") return { none: "secret" }
    if (refreshing) return { none: "stale" }
    if (kind === "empty") return { none: "empty" }
    if (kind !== "text") return { none: "not text" }
    if (textSeq !== currentSeq) return { none: "stale" }
    var value = String(text === null || text === undefined ? "" : text)
    if (value === "") return { none: "empty" }
    if (value.indexOf("\u0000") >= 0) return { none: "not text" }
    if (utf8Length(value) >= SNAPSHOT_CAP) return { none: "too large" }
    return { text: value }
}

function txnPick(state, emoji, clientClass, before) {
    var payload = String(emoji || "")
    var cls = String(clientClass || "")
    // An empty payload is refused rather than queued: nothing could ever
    // verify against it, and a transaction that can neither serve nor
    // drop would wedge every pick behind it.
    if (payload === "")
        return { state: state, action: "refused" }
    if (state.phase !== "idle" || state.pending !== "") {
        // Cap how many picks may wait behind the running one: a stalled
        // transaction must not accumulate picks without end — the fourth
        // is refused at the door, loudly, rather than wedged quietly
        // behind whatever never finishes.
        if (state.queue.length >= 3)
            return { state: state, action: "refused-full" }
        return {
            state: txnWith(state, {
                queue: state.queue.concat([{ emoji: payload, clientClass: cls }])
            }),
            action: "queued"
        }
    }
    return {
        state: txnWith(state, {
            seq: state.seq + 1, phase: "publishing", pending: payload,
            clientClass: cls, attempts: 0, before: snapshotOf(before)
        }),
        action: "publish"
    }
}

// The verify watchdog's verdict: a clipboard owner that never finishes
// its read stalls the verify forever, so the caller's timeout is a
// terminal drop — the same shape the five-mismatch limit already makes,
// loud, no chord, the queue handed over. A stale sequence (the timeout
// describes a verify the machine no longer holds) changes nothing.
function txnVerifyTimedOut(state, seq) {
    if (state.phase !== "publishing" || state.pending === ""
            || seq !== state.seq)
        return { state: state, action: "ignore" }
    return { state: txnIdle(state), action: "drop", restore: restoreFor(state) }
}

function txnServed(state, seq, served) {
    if (state.phase !== "publishing" || state.pending === "" || seq !== state.seq)
        return { state: state, action: "stale" }
    if (String(served) === state.pending)
        return { state: txnWith(state, { phase: "pasting" }), action: "chord" }
    var attempts = state.attempts + 1
    if (attempts >= 5)
        return { state: txnIdle(state), action: "drop",
            restore: restoreFor(state, served) }
    // A retry is a NEW verify run: the sequence moves, so the answer of
    // the wl-paste this retry is about to kill cannot masquerade as it.
    return {
        state: txnWith(state, { seq: state.seq + 1, attempts: attempts }),
        action: "retry"
    }
}

// The chord's verdict, delivered by pasteCurrent's completion callback.
// Only "completed" carries the emoji: it is the one outcome that may
// record usage, settle the search and close the page.
//
// The `seq` is the transaction the CALLBACK was armed for — captured at
// dispatch, compared here: the machine's phase alone says "pasting" but
// not WHOSE pasting, so a cancelled transaction's late reply must not be
// able to complete a live one. A seq that is not the machine's own means
// the verdict belongs to a transaction already cancelled or handed over:
// it lands as "stale" and changes nothing.
function txnChordDone(state, seq, success) {
    if (state.phase !== "pasting")
        return { state: state, action: "ignore" }
    if (seq !== state.seq)
        return { state: state, action: "stale" }
    if (success === true)
        return { state: txnIdle(state, { before: { text: state.pending } }),
            action: "completed", emoji: state.pending }
    return { state: txnIdle(state), action: "cancelled", restore: restoreFor(state) }
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
    var next = txnWith(state, {
        seq: state.seq + 1, phase: "publishing", pending: pick.emoji,
        clientClass: pick.clientClass, attempts: 0,
        queue: state.queue.slice(1)
    })
    return { state: next, action: "publish", emoji: pick.emoji }
}

// Cancel the running pick and everything queued. A chord already
// dispatching cannot be un-dispatched; its late completion lands on the
// idle machine as "ignore" and records nothing. A pick that had already
// published owes the clipboard its snapshot.
function txnCancel(state) {
    if (state.phase === "idle" && state.queue.length === 0)
        return { state: state, action: "ignore" }
    var cleared = txnWith(state, { queue: [] })
    return {
        state: txnIdle(cleared),
        action: "dropped",
        restore: state.phase !== "idle" ? restoreFor(cleared) : null
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
