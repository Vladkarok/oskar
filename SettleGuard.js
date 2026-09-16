.pragma library

// The restart-settle guard (ticket 38): which observed layout-group
// readings the panel may FOLLOW — move the helper's virtual keyboard and
// the persisted `remembered` group with — and which are the compositor's
// own keymap re-application churn echoed at a panel that just re-registered
// its virtual keyboard.
//
// The incident this owns (2026-09-13 18:53, journal in the ticket): the
// shell restarted 18:53:07, the daemon 18:53:17, the first configure
// 18:53:19. One language click at 18:53:22 moved all three keyboards to
// group 1, the panel correctly followed — and then a devices read returned
// the reading keyboard at 0 (Hyprland re-applying keymaps around a fresh
// vkb registration; the mover was outside the panel), the panel FOLLOWED
// the flip too, and the seat stayed split (two ITE keyboards on 1,
// at-translated on 0) with the panel label agreeing with the churn instead
// of the click, until the owner converged it by hand. The click's own
// `switchxkblayout` loop is not the defect and is not touched anywhere in
// this module: the guard only stops the panel from echoing churn back into
// the helper's group and `remembered`.
//
// The decision is pure: connect-age, the last group the panel COMMANDED
// (the click's hyprctl loop), and the sequence of observed readings in,
// follow-or-hold out. The clock is injected — `now` is a parameter, so the
// window and the quiesce are exact in tests and `Date.now()` at the one
// call site in Keyboard.qml. This module is deliberately NOT part of
// KeyboardSession.js: the session's ledger is reduced exclusively by
// helper replies on the socket, while the settle question is about
// compositor readings over time plus a command the panel issued through
// Hyprland — a different input stream and a different decision, with the
// same one-module-per-decision shape as LayoutDevices and ModifierReducer.
//
// The cold-start constraint (decisions §47) is structural here: the
// remembered-group tie-breaker answers from LayoutDevices as part of the
// FIRST reading a new world establishes, and the establishing reading is
// always followed — never held — so a genuinely diverged-sleeper seat on a
// cold start resolves exactly as it did before this guard existed. Only
// what happens AFTER the establishing configure, inside the window, is
// guarded.

/// How long after the establishing configure the guard stands. The
/// incident's click came three seconds after the first configure and the
/// churn flip within the same second as the click; ten seconds covers both
/// with margin while staying short enough that an ordinary session spends
/// its whole life outside the window.
var WINDOW_MS = 10000

/// How long an uncommanded flip must PERSIST — observed again, this far
/// after its first sighting — before the panel follows it inside the
/// window. The incident's churn produced sub-second repeat reads; a real
/// external switch (a keybind, another panel) persists, and the caller's
/// one re-read after this interval supplies the second agreeing reading.
var QUIESCE_MS = 1000

function initial() {
    return {
        // Whether the post-establishment window stands.
        armed: false,
        // When the window was last anchored (the establishing configure,
        // or a command issued while armed — the churn race is around the
        // click × fresh-registration overlap).
        openedAt: 0,
        // The group the panel last FOLLOWED and configures the helper
        // with. -1 while no world is established (a fresh panel, or a
        // genuinely new helper connection): the first valid reading
        // establishes it unguarded.
        followed: -1,
        // The group the click's own hyprctl loop last moved the seat to,
        // or -1. Only consulted while armed: outside the window every
        // reading is followed today's way and the record is unused.
        commanded: -1,
        // An uncommanded flip's first sighting, awaiting persistence; -1
        // when nothing is held.
        candidate: -1,
        candidateAt: 0
    }
}

function copy(state) {
    return {
        armed: state.armed,
        openedAt: state.openedAt,
        followed: state.followed,
        commanded: state.commanded,
        candidate: state.candidate,
        candidateAt: state.candidateAt
    }
}

/// A genuinely new helper connection (the hello a fresh socket answered —
/// not the repair timer's re-hello of a live one, which changes nothing
/// here). The old socket's world died with it: the helper is back at group
/// 0, acknowledges nothing, and whatever the panel followed or commanded
/// belongs to a world no reading can confirm. Everything resets and the
/// window disarms until the next establishing configure arms it fresh —
/// the establishing configure after a reconnect is the compositor's own
/// current answer and must be followed, exactly as it was before this
/// guard existed.
function connected(state) {
    var out = copy(state)
    out.armed = false
    out.openedAt = 0
    out.followed = -1
    out.commanded = -1
    out.candidate = -1
    out.candidateAt = 0
    return out
}

/// The panel's own click moved the physical seat to `group` — the
/// `switchxkblayout` loop in switchToGroup, the one path this guard never
/// touches. Recorded so the echo reading is followed immediately inside
/// the window (a guard that held its own click would break language
/// switching for the window's whole length) and so a held candidate dies
/// when the user clicks through churn. A command issued while armed
/// re-anchors the window around the click, because the loop re-races
/// whatever re-application churn remains after the fresh registration; a
/// command outside the window re-arms nothing — that is today's steady
/// state and stays exactly as it was.
function commanded(state, group, now) {
    var out = copy(state)
    out.commanded = group
    out.candidate = -1
    out.candidateAt = 0
    if (out.armed) out.openedAt = now
    return out
}

/// May the panel follow this observed reading — configure the helper with
/// it, draw it, and let the ack persist it into `remembered`?
///
/// Returns { state, follow, held }: `follow` says the reading may move the
/// panel; when false, `held` names the group to keep configuring (the
/// last followed one), which is also why `remembered` can never be dragged
/// into a held reading — it is persisted from configure acks, and the
/// panel never sends the held-out group while the hold stands.
function decide(state, observed, now) {
    var valid = typeof observed === "number" && isFinite(observed)
        && observed >= 0 && observed === Math.floor(observed)
    if (!valid) return { state: copy(state), follow: false, held: state.followed }

    var out = copy(state)

    // The establishing configure: no followed world exists (a fresh panel,
    // or a fresh helper connection reset it). This is the cold-start path
    // §47 rides — the remembered tie-breaker's answer arrives exactly here
    // and is followed unconditionally — and the reconnect path's first
    // compositor answer after the daemon restart. It also arms the window:
    // everything guarded below happens only AFTER a world was established.
    if (out.followed < 0) {
        out.followed = observed
        out.commanded = -1
        out.candidate = -1
        out.candidateAt = 0
        out.armed = true
        out.openedAt = now
        return { state: out, follow: true, held: observed }
    }

    // Not a flip: the reading agrees with the world already installed.
    // Whatever candidate was held is retired — the flip did not persist —
    // and following a no-op is exactly today's behavior.
    if (observed === out.followed) {
        out.candidate = -1
        out.candidateAt = 0
        return { state: out, follow: true, held: observed }
    }

    // Outside the window — never armed, or the quiesce expired — every
    // reading is followed at first sight. This is the whole of today's
    // behavior, unchanged, and the reason the guard cannot outlive the
    // few seconds it exists for.
    if (!out.armed || now - out.openedAt >= WINDOW_MS) {
        out.armed = false
        out.followed = observed
        out.candidate = -1
        out.candidateAt = 0
        return { state: out, follow: true, held: observed }
    }

    // The click's own echo: user intent, followed immediately even though
    // it flips the group inside the window.
    if (out.commanded >= 0 && observed === out.commanded) {
        out.followed = observed
        out.candidate = -1
        out.candidateAt = 0
        return { state: out, follow: true, held: observed }
    }

    // An uncommanded flip inside the window: HOLD it. First sighting, a
    // different value than the one held (the churn is still moving), or
    // the same value still inside its quiesce — every held decision
    // re-anchors the candidate's clock, so continuous churn (the
    // incident's repeat reads were sub-second) never accumulates into
    // agreement. Only a reading this far past the LAST sighting of the
    // SAME value counts as the flip having persisted.
    if (out.candidate !== observed || now - out.candidateAt < QUIESCE_MS) {
        out.candidate = observed
        out.candidateAt = now
        return { state: out, follow: false, held: out.followed }
    }

    // The same flip, a full quiesce past its last sighting: something
    // outside the panel really did move the seat and it STAYED moved, so
    // follow it — and the agreement is the quiesce the window existed
    // for; it closes here.
    out.followed = observed
    out.candidate = -1
    out.candidateAt = 0
    out.armed = false
    return { state: out, follow: true, held: observed }
}
