.pragma library
.import "LayoutDevices.js" as Devices

// Who moved on the seat, over time: the evidence LayoutDevices.select needs
// to tell the user's toggle on the keyboard under their hands from
// everything else that moves a keyboard's group.
//
// A group toggle (Alt+Shift under grp:alt_shift_toggle) moves the ONE
// keyboard it was pressed on. Everything else that moves groups moves
// several devices within a few milliseconds of each other: the panel's own
// click (one `switch` per keyboard of the set), a compositor-wide switch or
// a keymap re-application (every device in enumeration order, pseudo-
// devices included). A burst can still show one safe keyboard changed in a
// reading taken between two of its events, so a lone-looking move is only a
// CANDIDATE until the seat has been quiet around it; the reading that
// follows the quiet judges it (LayoutDevices.loneMover) against the reading
// from before it moved.
//
// Pure: HelperReplies owns the state (its `seatMotion` field), the clock is
// passed in, and the keyboard's only part is the timer tick that asks for
// the confirming reading at the time `event` names.

/// How long the seat must stay quiet around a lone-looking move before it
/// is judged a toggle. Measured on the owner's seat (the 2026-09-27
/// capture): inside the two compositor-wide bursts, consecutive events
/// from different devices were 1–9 ms apart, 72 ms at the widest (a power
/// button to its twin, 18:48:48.154 to .226); the owner's Alt+Shift
/// presses of one keyboard came at least 149 ms apart and nothing but
/// fcitx5's virtual keyboard moved near them. Twice the widest burst gap.
/// The same keyboard moving again inside the wait is the user toggling on
/// and restarts the wait rather than counting as a burst, so fast toggling
/// never reads as one. This is also how long a diverged seat's caps wait
/// for a toggle to be judged.
var QUIET_MS = 150

/// A virtual keyboard's move is a follower's, never evidence: fcitx5's
/// virtual keyboard mirrors the group of the keyboard whose keys it
/// forwards (1–5 ms after every toggle in the capture), and this helper's
/// own moves on every configure the panel sends.
function isFollower(name) {
    return /^hl-virtual-keyboard/i.test(String(name || ""))
}

function initial() {
    return {
        // The keyboard the newest typed layout event named, and whether it
        // was the echo of the panel's own click.
        mover: "",
        commanded: false,
        // The newest layout event from any device but a follower.
        lastEventDevice: "",
        lastEventAt: 0,
        // A lone-looking move awaiting its quiet: the keyboard, when it
        // (last) moved, and the reading from before it first moved.
        candidate: "",
        candidateAt: 0,
        candidateBase: null,
        // A candidate whose quiet held: the next reading judges it.
        confirming: "",
        confirmingBase: null,
        // The keyboards of the last seat reading, or null before the
        // first; `gap` when that reading is from before a reconnect.
        previous: null,
        gap: false
    }
}

function copy(state) {
    var s = state || initial()
    return {
        mover: s.mover, commanded: s.commanded,
        lastEventDevice: s.lastEventDevice, lastEventAt: s.lastEventAt,
        candidate: s.candidate, candidateAt: s.candidateAt,
        candidateBase: s.candidateBase,
        confirming: s.confirming, confirmingBase: s.confirmingBase,
        previous: s.previous, gap: s.gap
    }
}

/// One `event\tlayout` line: `device` moved, `commanded` when it is the
/// echo of the panel's own click (SettleGuard.isEcho). Returns
/// { state, confirmAt }: `confirmAt` is when the caller should call
/// `quiet` to judge a new candidate, or -1.
function event(state, device, commanded, now, safeNames) {
    var out = copy(state)
    var name = String(device || "")
    if (name === "" || isFollower(name)) return { state: out, confirmAt: -1 }

    // Another device moving within the quiet of a candidate makes the
    // candidate part of a burst.
    if (out.candidate !== "" && name !== out.candidate
            && now - out.candidateAt < QUIET_MS) {
        out.candidate = ""
        out.candidateBase = null
    }
    if (out.confirming !== "" && name !== out.confirming) {
        out.confirming = ""
        out.confirmingBase = null
    }
    // And one within the quiet BEFORE it: the move is a burst's tail.
    var isolated = out.lastEventDevice === "" || out.lastEventDevice === name
        || now - out.lastEventAt >= QUIET_MS
    if (Devices.isTyped(name)) {
        out.mover = name
        out.commanded = commanded === true
    }
    out.lastEventDevice = name
    out.lastEventAt = now

    var names = Array.isArray(safeNames) ? safeNames : []
    var eligible = isolated && commanded !== true && Devices.isTyped(name)
        && Devices.isSafe(name, names)
    if (!eligible) {
        if (out.candidate === name) {
            out.candidate = ""
            out.candidateBase = null
        }
        return { state: out, confirmAt: -1 }
    }
    if (out.candidate !== name) {
        out.candidate = name
        out.candidateBase = out.previous
    }
    out.candidateAt = now
    return { state: out, confirmAt: now + QUIET_MS }
}

/// The quiet timer's tick. Returns { state, ask, confirmAt }: `ask` when
/// the candidate's quiet held and the next reading must judge it;
/// `confirmAt` when a candidate still waits (a timer that fired early, or a
/// keyboard that moved again), else -1.
function quiet(state, now) {
    var out = copy(state)
    if (out.candidate === "") return { state: out, ask: false, confirmAt: -1 }
    if (now - out.candidateAt < QUIET_MS)
        return { state: out, ask: false, confirmAt: out.candidateAt + QUIET_MS }
    out.confirming = out.candidate
    out.confirmingBase = out.candidateBase
    out.candidate = ""
    out.candidateBase = null
    return { state: out, ask: true, confirmAt: -1 }
}

/// One seat reading. Returns { state, motion }: `motion` is the lone-move
/// question this reading answers for LayoutDevices.select, or null — the
/// confirmed candidate against the reading from before it moved, or, for
/// the first reading after a reconnect, whichever one keyboard changed
/// across the gap (no event could name it: the helper was not there). The
/// question is asked once; the reading becomes the next one's `previous`.
function reading(state, devices) {
    var out = copy(state)
    var motion = null
    if (out.gap && Array.isArray(out.previous)) {
        motion = { base: out.previous, candidate: "", gap: true }
    } else if (out.confirming !== "" && Array.isArray(out.confirmingBase)) {
        motion = { base: out.confirmingBase, candidate: out.confirming, gap: false }
    }
    out.confirming = ""
    out.confirmingBase = null
    out.gap = false
    out.previous = Array.isArray(devices) ? devices : null
    return { state: out, motion: motion }
}

/// A genuinely new helper connection. Every event of the old one is
/// forgotten — the mover, the echo marker, any candidate — because the
/// first reading of the new one must not be judged by whatever happened to
/// move last on a connection that is gone. The last reading stays, marked
/// as from before the gap, so a keyboard that moved alone while the helper
/// was away is found by the first reading after it.
function reconnected(state) {
    var out = initial()
    var s = state || initial()
    out.previous = Array.isArray(s.previous) ? s.previous : null
    out.gap = out.previous !== null
    return out
}
