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
// A pick that FAILS puts back what the clipboard held before it, but only
// while the clipboard is provably still OSKar's: the user may have copied
// something during the pick, and that is theirs.
//
// `before` is the pick's snapshot: `{ text }` when the previous content
// could be read as text, `{ none: why }` when it could not be put back
// (see snapshotPlan). The first pick of a burst brings it; a delivered
// pick makes its own emoji the next queued pick's `before`; a failed one
// leaves `before` as it was. It lives only as long as the transaction:
// the machine clears it when it goes idle with nothing queued, and a
// failure hands the text out once, in its `restore`.
//
// `observed` is what the verify reads saw since this pick published, other
// than the pick itself: "none", "previous" (the snapshot's own text — the
// publish had not landed yet) or "foreign" (anything else: the user's
// copy, an empty clipboard). Every terminal failure that leaves the
// machine idle carries `restore`:
//   { text }         publish it: the clipboard is still OSKar's
//   { none: why }    write nothing, and say why in the journal
//   { check: id }    read the clipboard first (txnRestoreChecked decides)
// A failure with a queued pick behind it carries `restore: null`: the next
// pick replaces the clipboard anyway, and its own outcome decides.
//
// The rule, per failure: the verify's last read (mismatch exhausted) was
// not the pick, so the clipboard holds either the snapshot already or
// someone else's content — nothing is written. The verify watchdog saw no
// answer, so it restores unless something foreign was seen earlier. A
// refused chord or a cancellation during the paste happens after the
// verify saw the pick, so the clipboard is read once more and restored
// only if it still serves the pick.
function txnInitial() {
    return { seq: 0, phase: "idle", pending: "", clientClass: "",
        attempts: 0, queue: [], before: { none: "unread" }, observed: "none",
        restoreCheck: null }
}

function txnWith(state, changes) {
    var next = {
        seq: state.seq, phase: state.phase, pending: state.pending,
        clientClass: state.clientClass, attempts: state.attempts,
        queue: state.queue, before: state.before, observed: state.observed,
        restoreCheck: state.restoreCheck
    }
    for (var key in changes) next[key] = changes[key]
    return next
}

var NO_SNAPSHOT = { none: "unread" }

// The machine going idle: the snapshot outlives the transaction only for a
// queued pick, which inherits it.
function txnIdle(state, changes) {
    var idle = txnWith(state, { phase: "idle", pending: "", clientClass: "",
        attempts: 0, observed: "none" })
    if (idle.queue.length === 0) idle.before = NO_SNAPSHOT
    return changes ? txnWith(idle, changes) : idle
}

function snapshotOf(before) {
    if (before && typeof before.text === "string" && before.text !== "")
        return { text: before.text }
    return { none: before && typeof before.none === "string" ? before.none : "unread" }
}

// What a failure owes the clipboard when no fresh read is needed. `served`
// is the verify's last read when the failure is its mismatch.
function restoreFor(state, served) {
    if (state.queue.length > 0) return null
    var before = snapshotOf(state.before)
    if (before.text === undefined) return before
    if (served !== undefined)
        return String(served) === before.text ? { none: "unchanged" } : { none: "foreign" }
    if (state.observed === "foreign") return { none: "foreign" }
    return before
}

// A failure after the verify saw the pick: ask for one more read.
function checkFor(state) {
    if (state.queue.length > 0) return { restore: null, check: null }
    var before = snapshotOf(state.before)
    if (before.text === undefined) return { restore: before, check: null }
    return {
        restore: { check: state.seq },
        check: { id: state.seq, emoji: state.pending, before: before }
    }
}

// The pick's snapshot is taken by one bounded read at the moment of the
// pick, before anything is published, and lives only in the transaction.
// Whether that read may run is decided from the chip's type listing:
// only plain text is read, never content a password manager marked secret
// (kind "hidden") — republishing it would leave a secret as plain text
// owned by OSKar — and never while a listing is in flight (the kind may
// be stale).
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

/// "read" when the pick may read the clipboard for its snapshot, or the
/// snapshot it gets without one.
function snapshotPlan(kind, refreshing) {
    if (kind === "hidden") return { none: "secret" }
    if (refreshing) return { none: "stale" }
    if (kind === "empty") return { none: "empty" }
    if (kind !== "text") return { none: "not text" }
    return "read"
}

/// The snapshot a completed read gives: the shared reader's exit code and
/// output. Text at the reader's own cap may be cut short, so it is not put
/// back.
function snapshotFromRead(exitCode, text) {
    if (exitCode === READ_SECRET_EXIT) return { none: "secret" }
    if (exitCode !== 0 || text === null || text === undefined) return { none: "unread" }
    var value = String(text)
    if (value === "") return { none: "empty" }
    if (value.indexOf("\u0000") >= 0) return { none: "not text" }
    if (utf8Length(value) >= SNAPSHOT_CAP) return { none: "too large" }
    return { text: value }
}

// The one clipboard reader every payload read uses (the chip's preview,
// the panel-local paste, the emoji verify, the restore check). It lists the
// types before AND after reading: content a password manager marks secret
// (x-kde-passwordManagerHint) is not read at all, and a secret that
// landed during the read is discarded unprinted. Exit 3 means secret. The
// stream is capped (a malicious owner cannot balloon the shell's memory),
// and it runs under setsid so a watchdog can kill the whole group.
var READ_SCRIPT = "h=x-kde-passwordmanagerhint; "
    + "wl-paste --list-types 2>/dev/null | grep -qix \"$h\" && exit 3; "
    + "data=$(wl-paste --no-newline 2>/dev/null | head -c 65536; printf .); "
    + "wl-paste --list-types 2>/dev/null | grep -qix \"$h\" && exit 3; "
    + "printf %s \"${data%.}\""
var READ_SECRET_EXIT = 3

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
    // A new burst: a restore still waiting for its check is abandoned — this
    // pick owns the clipboard now. With `before === "read"` the snapshot is
    // read first ("snapshotting"); picks arriving meanwhile queue.
    var reading = before === "read"
    return {
        state: txnWith(state, {
            seq: state.seq + 1, phase: reading ? "snapshotting" : "publishing",
            pending: payload, clientClass: cls, attempts: 0,
            before: reading ? NO_SNAPSHOT : snapshotOf(before),
            observed: "none", restoreCheck: null
        }),
        action: reading ? "snapshot" : "publish"
    }
}

/// The snapshot read answered (or its bound ran out: pass { none: "unread" }).
/// The pick publishes now, with whatever snapshot it got.
function txnSnapshotted(state, seq, before) {
    if (state.phase !== "snapshotting" || seq !== state.seq)
        return { state: state, action: "stale" }
    return {
        state: txnWith(state, { phase: "publishing", before: snapshotOf(before) }),
        action: "publish", emoji: state.pending
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
    var before = snapshotOf(state.before)
    var observed = state.observed === "foreign"
        || before.text === undefined || String(served) !== before.text
        ? "foreign" : "previous"
    var seen = txnWith(state, { observed: observed })
    var attempts = state.attempts + 1
    if (attempts >= 5)
        return { state: txnIdle(seen), action: "drop",
            restore: restoreFor(seen, served) }
    // A retry is a NEW verify run: the sequence moves, so the answer of
    // the wl-paste this retry is about to kill cannot masquerade as it.
    return {
        state: txnWith(seen, { seq: state.seq + 1, attempts: attempts }),
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
    if (success === true) {
        var done = txnIdle(state)
        if (done.queue.length > 0) done.before = { text: state.pending }
        return { state: done, action: "completed", emoji: state.pending }
    }
    var owed = checkFor(state)
    return { state: txnIdle(state, { restoreCheck: owed.check }), action: "cancelled",
        restore: owed.restore }
}

// The restore check's answer: `served` is what the clipboard held (null
// when the read failed or timed out), `secret` that it was marked secret.
// The snapshot goes back only if the clipboard still serves the pick.
function txnRestoreChecked(state, id, served, secret) {
    var check = state.restoreCheck
    if (!check || check.id !== id)
        return { state: state, action: "stale", restore: null }
    var next = txnWith(state, { restoreCheck: null })
    var restore
    if (secret) restore = { none: "foreign" }
    else if (served === null || served === undefined) restore = { none: "unread" }
    else if (String(served) === check.emoji) restore = check.before
    else if (String(served) === check.before.text) restore = { none: "unchanged" }
    else restore = { none: "foreign" }
    return { state: next, action: "checked", restore: restore }
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
        clientClass: pick.clientClass, attempts: 0, observed: "none",
        queue: state.queue.slice(1)
    })
    return { state: next, action: "publish", emoji: pick.emoji }
}

// Cancel the running pick and everything queued. A chord already
// dispatching cannot be un-dispatched; its late completion lands on the
// idle machine as "ignore" and records nothing. A pick that had already
// published owes the clipboard its snapshot, by the same rule as its own
// failure would.
function txnCancel(state) {
    if (state.phase === "idle" && state.queue.length === 0)
        return { state: state, action: "ignore" }
    var cleared = txnWith(state, { queue: [] })
    if (state.phase === "pasting") {
        var owed = checkFor(cleared)
        return { state: txnIdle(cleared, { restoreCheck: owed.check }), action: "dropped",
            restore: owed.restore }
    }
    return {
        state: txnIdle(cleared),
        action: "dropped",
        restore: state.phase === "publishing" ? restoreFor(cleared) : null
    }
}

// The paste chip. At rest it shows only what KIND of content the
// clipboard holds and how much — never the content: the type listing gives
// the kind, and a count read (COUNT_SCRIPT) gives the size without the
// text entering the panel. The text is read only to peek — while the
// pointer rests on the chip (mouse) or a touch holds it — and dropped the
// moment the peek ends, the panel closes or the clipboard changes. Content
// a password manager marked secret (kind "hidden") is never read, peek or
// not. Clicking pastes whatever the kind: the chord needs no text.
//
// State: { kind, count, capped, countSeq, peek, peeking, peekSeq }. Steps
// return { state, action, seq? }; action "count" / "read" asks the host
// to run that read tagged with `seq`, "none" asks nothing.
function chipInitial() {
    return { kind: "empty", count: -1, capped: false, countSeq: 0,
        peek: "", peeking: false, peekSeq: 0 }
}

function chipWith(state, changes) {
    var next = { kind: state.kind, count: state.count, capped: state.capped,
        countSeq: state.countSeq, peek: state.peek, peeking: state.peeking,
        peekSeq: state.peekSeq }
    for (var key in changes) next[key] = changes[key]
    return next
}

/// A new type listing (Config.clipboardKind's answer): the clipboard
/// changed, so any peek is dropped and the size is asked for again.
function chipTypes(state, kind) {
    var next = chipWith(state, { kind: String(kind || "empty"), count: -1,
        capped: false, countSeq: state.countSeq + 1, peek: "", peeking: false,
        peekSeq: state.peekSeq + 1 })
    return next.kind === "text"
        ? { state: next, action: "count", seq: next.countSeq }
        : { state: next, action: "none" }
}

// The count read: types checked before and after like every read, the
// payload streamed through `wc` so only "<characters> <bytes>" comes out.
// One byte past the cap tells a capped clipboard from one exactly at it.
var COUNT_SCRIPT = "h=x-kde-passwordmanagerhint; "
    + "wl-paste --list-types 2>/dev/null | grep -qix \"$h\" && exit 3; "
    + "n=$(wl-paste --no-newline 2>/dev/null | head -c 65537 | LC_ALL=C.UTF-8 wc -mc); "
    + "wl-paste --list-types 2>/dev/null | grep -qix \"$h\" && exit 3; "
    + "printf %s \"$n\""

/// The count read answered.
function chipCounted(state, seq, exitCode, output) {
    if (seq !== state.countSeq || state.kind !== "text") return { state: state, action: "none" }
    if (exitCode === READ_SECRET_EXIT)
        return { state: chipWith(state, { kind: "hidden", count: -1, peek: "",
            peeking: false }), action: "none" }
    var fields = String(output || "").trim().split(/\s+/)
    var chars = parseInt(fields[0], 10)
    var bytes = parseInt(fields[1], 10)
    if (exitCode !== 0 || !isFinite(chars) || !isFinite(bytes))
        return { state: chipWith(state, { count: 0 }), action: "none" }
    var capped = bytes > SNAPSHOT_CAP
    return { state: chipWith(state, { count: capped ? Math.max(0, chars - 1) : chars,
        capped: capped }), action: "none" }
}

/// What the chip draws: "empty" (hidden), "text", "hidden" or "other".
/// Text shows once its size is known and non-zero.
function chipShown(state) {
    if (state.kind === "hidden" || state.kind === "other") return state.kind
    if (state.kind === "text" && state.count > 0) return "text"
    return "empty"
}

/// The rest label as a UiStrings id and its arguments, or null (the glyph
/// or nothing). Never content.
function chipLabel(state) {
    var shown = chipShown(state)
    if (shown === "hidden") return { id: "paste.hidden", args: [] }
    if (shown !== "text") return null
    if (state.capped) return { id: "paste.textAtLeast", args: [String(state.count)] }
    if (state.count === 1) return { id: "paste.textOne", args: [] }
    return { id: "paste.textCount", args: [String(state.count)] }
}

/// The pointer came to rest on the chip, or a touch holds it: read the
/// text to peek — plain text only, never hidden content.
function chipPeekStart(state) {
    if (state.peeking || chipShown(state) !== "text") return { state: state, action: "none" }
    var next = chipWith(state, { peeking: true, peek: "", peekSeq: state.peekSeq + 1 })
    return { state: next, action: "read", seq: next.peekSeq }
}

/// The peek read answered (the shared reader's exit code and output).
function chipPeekRead(state, seq, exitCode, text) {
    if (!state.peeking || seq !== state.peekSeq) return { state: state, action: "none" }
    if (exitCode === READ_SECRET_EXIT)
        return { state: chipWith(state, { kind: "hidden", peek: "", peeking: false }),
            action: "none" }
    if (exitCode !== 0) return { state: chipWith(state, { peek: "" }), action: "none" }
    var flat = String(text === null || text === undefined ? "" : text)
        .replace(/[\r\n\t]+/g, " ").replace(/^\s+|\s+$/g, "")
    return { state: chipWith(state, { peek: flat.slice(0, 240) }), action: "none" }
}

/// The peek ended — the pointer left, the touch lifted, the panel closed:
/// the text is gone from the state, and a read still in flight is stale.
function chipPeekEnd(state) {
    return { state: chipWith(state, { peek: "", peeking: false, peekSeq: state.peekSeq + 1 }),
        action: "none" }
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
