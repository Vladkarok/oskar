.pragma library

// The keymap-share scheduler, pure: one share run is in flight at a
// time, launched FOR a generation; a newer generation arriving mid-run
// only updates the wish. The run's success records the generation IT
// launched (decisions §69 — an old run's exit used to mark a newer map
// shared and the required rerun never happened), and — §71's half of
// the same defect — a pending wish is CONSUMED on success: the next run
// is scheduled immediately, so the newest map cannot sit unshared with
// nothing running and nothing retrying.
//
// Failures do not consume the wish: the retry loop belongs to the
// caller (same generation, same run), and a caller that gives up loudly
// self-heals on the next generation change — the guard relaunches
// because the shared generation no longer matches.

function initial() {
    return { running: false, launched: 0, wished: 0, shared: 0 }
}

/// A keymap was acknowledged: share it. Returns the next state plus
/// `start`, true when the caller must launch a run NOW (the run is for
/// `state.launched`). An ack at or below what is already shared — the
/// equal case, or a stale ack replayed by a fallback path — is no work
/// at all: it launches nothing and touches nothing.
function acked(state, generation) {
    if (generation <= 0 || generation <= state.shared) return { state: state, start: false }
    var next = {
        running: state.running,
        launched: state.launched,
        wished: Math.max(state.wished, generation),
        shared: state.shared
    }
    if (state.running) return { state: next, start: false }
    next = {
        running: true,
        launched: next.wished,
        wished: next.wished,
        shared: state.shared
    }
    return { state: next, start: true }
}

/// The run's verdict. Success shares EXACTLY what this run launched and
/// schedules the pending wish if it is newer (§71); failure keeps the
/// run alive for the caller's retry, wish untouched.
function runFinished(state, succeeded) {
    if (!state.running) return { state: state, start: false }
    if (!succeeded) return { state: state, start: false }
    var shared = state.launched
    var pending = state.wished > shared
    var next = {
        running: pending,
        launched: pending ? state.wished : 0,
        wished: state.wished,
        shared: shared
    }
    return { state: next, start: pending }
}

/// The caller gave the run up loudly (the five-attempt ceiling): the run
/// ends unshared, the wish stays, and the next ack launches for the
/// newest generation — a fresh map may succeed where the old one could
/// not, and a self-healing loop must not spin forever on a dead one.
function runAbandoned(state) {
    return { running: false, launched: 0, wished: state.wished, shared: state.shared }
}

/// The compositor was seen carrying something other than the published
/// map (the user's own kb_file, an explicit clear): the panel's record
/// of what is shared is void — everything else about a run in flight
/// stays, and the caller immediately asks to share again.
function displaced(state) {
    return { running: state.running, launched: state.launched, wished: state.wished, shared: 0 }
}
