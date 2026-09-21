.pragma library

// The paste lifecycle, pure: ONE paste at a time, from the first click
// to the verdict. The busy-gate, the region boundary and the cancel
// ordering that rounds seven through nine kept finding in the QML glue
// live here as data the glue executes:
//
//   idle → dispatching → paced ─┐
//          dispatching → ───────┴→ awaiting → idle
//
// - `begin` refuses while ANY phase but idle is live — a paste-chip
//   click during an unfinished chord no longer resets anything, it
//   bounces (round nine).
// - The caller marks `chordStart` on the correlation ledger between
//   `begin` and the first send — the region belongs to the whole
//   dispatch, not its last line (round eight).
// - `cancel` answers WHAT to do and in which order: abort the pacer
//   first (its own path compensates the sent prefix and releases the
//   world — round nine's timer kept pressing V onto a held Ctrl),
//   then clear the armed verdict wait (round seven's late-reply hole).
//
// The timer and socket machinery stays in the QML; this module is the
// invariant they cannot violate.

function initial() {
    return { phase: "idle" }
}

/// A paste was requested. `refuse` is true while another paste owns the
/// lifecycle — the caller reports failure and touches NOTHING of the
/// running paste's tracking.
function begin(state) {
    if (state.phase !== "idle")
        return { state: state, refuse: true }
    return { state: { phase: "dispatching" }, refuse: false }
}

/// The paced path committed its lines: the ticks own the dispatch now.
/// Zero lines is the reducer's refusal — back to idle, nothing sent.
function paced(state, lines) {
    if (state.phase !== "dispatching") return state
    if (lines <= 0) return { phase: "idle" }
    return { phase: "paced" }
}

/// The dispatch finished sending (paced's last tick, or the direct
/// path's writes): the verdict wait begins. The caller arms the
/// correlation ledger's chord wait here.
function awaiting(state) {
    if (state.phase !== "dispatching" && state.phase !== "paced") return state
    return { phase: "awaiting" }
}

/// The dispatch failed before anything could complete (the reducer
/// refused, a write failed): back to idle, the caller reports failure.
function failed(state) {
    return { phase: "idle" }
}

/// The verdict arrived — by the ledger's drain, the guard timer or a
/// dying connection. Idempotent: a second verdict
/// (the guard racing the drain) changes nothing.
function verdictDone(state) {
    return { phase: "idle" }
}

/// A cancellation (§91 history: production callers are gone; the
/// tests pin the semantics for any future cancel path). The ANSWER is an ordered
/// program: abort the pacer first — its own path owes the device its
/// compensations and releases — then clear the armed verdict wait.
/// Dispatching cannot be cancelled from outside (its block is atomic in
//  the single thread); the defensive answer releases everything anyway.
function cancel(state) {
    return {
        state: { phase: "idle" },
        abortPacer: state.phase === "paced",
        clearWait: state.phase === "awaiting" || state.phase === "dispatching"
    }
}
