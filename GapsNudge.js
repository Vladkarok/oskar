.pragma library

// The docked panel's relayout nudge, pure: what to write to
// `general:gaps_out` to force Hyprland to relayout the tiled windows, and
// what to write back. The processes live in Panel.qml; this module owns the
// values and the chain's verdicts.
//
// Why a nudge at all: the docked panel's exclusive zone registers and NEW
// tiled windows respect it, but Hyprland does not relayout the windows that
// were tiled while the panel was closed (measured at scale 2) — one config
// write forces it. The write changes one number of the user's value by one
// for a single frame and puts the exact original text back.
//
// The rules the chain keeps:
// - The value is read in whatever form Hyprland answers: `int` (older
//   builds), or `css` / `custom`, a string of one to four whole numbers
//   ("0 0 0 0"). Any other answer is not understood and NOTHING is written:
//   a guess written back as the "original" would flatten the user's gaps.
// - Only the first number moves, by one; the restore writes the original
//   string exactly as it was read.
// - Every write is judged by reading the value back, never by hyprctl's
//   reply: a write that landed but answered something other than `ok`
//   must still be restored. A nudge that reads back as the original
//   changed nothing and needs no restore.
// - A restore that does not read back as the original is retried once;
//   a value still wrong after that is an error naming the original, so
//   the user can put it back by hand.
//
// State: { phase, original, nudged, retried }; phase is "idle",
// "nudging" (the nudge write is out), "nudge-check" (its read-back is out),
// "waiting" (the restore timer runs), "restoring" (the restore write is
// out), "restore-check" (its read-back is out). Each step returns
// { state, action, value?, log? }:
//   action "write"  write `value` to general:gaps_out
//   action "read"   read general:gaps_out back (readBack follows)
//   action "wait"   arm the restore timer (restoreDue follows)
//   action "done"   the chain is over; the caller may start a queued one
//   log            { level: "log" | "warn" | "error", text } — one journal line

function initial() {
    return { phase: "idle", original: "", nudged: "", retried: false }
}

function withPhase(state, phase, retried) {
    return { phase: phase, original: state.original, nudged: state.nudged,
        retried: retried === undefined ? state.retried : retried }
}

var NUMBERS = /^\s*-?\d+(\s+-?\d+){0,3}\s*$/

/// The value a `hyprctl getoption -j general:gaps_out` answer carries, as
/// the text a restore would write, or null when the answer is not
/// understood.
function valueOf(replyText) {
    var doc
    try {
        doc = JSON.parse(String(replyText || ""))
    } catch (error) {
        return null
    }
    if (!doc || typeof doc !== "object") return null
    if (typeof doc.int === "number" && isFinite(doc.int)
            && doc.int === Math.floor(doc.int))
        return String(doc.int)
    var text = typeof doc.css === "string" ? doc.css
        : typeof doc.custom === "string" ? doc.custom : null
    if (text === null || !NUMBERS.test(text)) return null
    return text
}

/// The original and the nudged value for an answer, or null.
function plan(replyText) {
    var original = valueOf(replyText)
    if (original === null) return null
    return {
        original: original,
        nudged: original.replace(/-?\d+/, function (first) {
            return String(Number(first) + 1)
        })
    }
}

/// The probe answered: start the chain, or write nothing at all.
function start(replyText) {
    var values = plan(replyText)
    if (values === null) {
        return {
            state: initial(),
            action: "done",
            log: { level: "warn", text: "[oskar] general:gaps_out answered in a form"
                + " the relayout nudge does not understand; nothing written: "
                + String(replyText || "").trim().slice(0, 160) }
        }
    }
    return {
        state: { phase: "nudging", original: values.original,
            nudged: values.nudged, retried: false },
        action: "write",
        value: values.nudged
    }
}

/// A write finished, whatever hyprctl answered: read the value back.
function written(state) {
    if (state.phase === "nudging")
        return { state: withPhase(state, "nudge-check"), action: "read" }
    if (state.phase === "restoring")
        return { state: withPhase(state, "restore-check"), action: "read" }
    return { state: state, action: "done" }
}

/// A read-back answered. An unreadable answer counts as "not the
/// original": writing the original back is always safe.
function readBack(state, replyText) {
    var value = valueOf(replyText)
    if (state.phase === "nudge-check") {
        if (value === state.original) {
            return {
                state: initial(),
                action: "done",
                // Expected under the Lua config parser, which refuses
                // `keyword`: nothing changed, so a journal line, no warning.
                log: { level: "log", text: "[oskar] the relayout nudge did not change"
                    + " general:gaps_out; nothing to restore" }
            }
        }
        return { state: withPhase(state, "waiting"), action: "wait" }
    }
    if (state.phase === "restore-check") {
        if (value === state.original) return { state: initial(), action: "done" }
        if (!state.retried)
            return { state: withPhase(state, "restoring", true), action: "write",
                value: state.original }
        return {
            state: initial(),
            action: "done",
            log: { level: "error", text: "[oskar] could not restore general:gaps_out:"
                + " it reads \"" + (value === null ? "?" : value) + "\", the original was \""
                + state.original + "\"" }
        }
    }
    return { state: state, action: "done" }
}

/// The restore timer fired: write the original back.
function restoreDue(state) {
    if (state.phase !== "waiting") return { state: state, action: "done" }
    return { state: withPhase(state, "restoring"), action: "write", value: state.original }
}
