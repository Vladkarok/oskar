.pragma library

// Correlating the helper's bare `ok` replies with the plain commands they
// answer, so a dispatched paste chord can wait for the acknowledgement of
// ITS OWN final line (the review's fourth round: a single awaiting slot
// settled on the FIRST ok — the Ctrl press's — and the next emoji could
// still replace the clipboard before the paste events left the panel).
//
// The helper serves each connection strictly in order and answers every
// plain command `down|up|mods|group` with exactly one `ok`. So the panel
// counts plain commands sent minus oks received; the chord's final line
// is acked the moment the counter drains to zero while a chord waits.
// A command the panel never counted (text, configure, caps, ping) never
// decrements it; a write that failed never increments it. An interleaved
// click after the chord's last line only delays the drain — late is
// safe, early was the bug.
//
// One chord waits at a time (the clipboard transaction serializes them),
// and a connection that dies resets the whole ledger: its oks never
// come, and the reconnect's world starts clean.

function initial() {
    return { outstanding: 0, chordDone: null }
}

// The verbs whose reply is a bare `ok` — nothing else moves the counter.
function isPlainCommand(line) {
    return /^(down|up|mods|group) /.test(String(line || ""))
}

function sent(state, line) {
    if (!isPlainCommand(line)) return { state: state, counted: false }
    return {
        state: { outstanding: state.outstanding + 1, chordDone: state.chordDone },
        counted: true
    }
}

// Arm the waiting chord: settle when the drain reaches zero.
function chordArmed(state, done) {
    return { outstanding: state.outstanding, chordDone: done || null }
}

// One `ok` arrived. `settle` is true only when nothing sent is unacked —
// the chord's final line included, whatever else went out around it.
function okReceived(state) {
    if (state.outstanding <= 0)
        return { state: state, settle: false }
    var outstanding = state.outstanding - 1
    return {
        state: { outstanding: outstanding, chordDone: state.chordDone },
        settle: state.chordDone !== null && outstanding === 0
    }
}

// The verdict is in — the waiting callback leaves, the counter stays (the
// remaining oks are still owed and still drain).
function chordSettled(state) {
    return { outstanding: state.outstanding, chordDone: null }
}

// The connection died: no ok is coming for anything sent on it, and the
// reconnect's replies answer only its own commands.
function connectionLost(state) {
    return initial()
}
