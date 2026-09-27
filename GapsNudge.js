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
// - A nudge the compositor refused changed nothing and needs no restore.
// - A failed restore is retried once; a value still nudged after that is an
//   error naming the original, so the user can put it back by hand.
//
// State: { phase: "idle" | "nudging" | "restoring", original, nudged,
// retried }. Each step returns { state, action, log? }:
//   action "write"  write `value` to general:gaps_out
//   action "wait"   arm the restore timer (restoreDue follows)
//   action "done"   the chain is over; the caller may start a queued one
//   log            { level: "log" | "warn" | "error", text } — one journal line

function initial() {
    return { phase: "idle", original: "", nudged: "", retried: false }
}

var NUMBERS = /^\s*-?\d+(\s+-?\d+){0,3}\s*$/

/// The original and the nudged value for a `hyprctl getoption -j
/// general:gaps_out` answer, or null when the answer is not understood.
function plan(replyText) {
    var doc
    try {
        doc = JSON.parse(String(replyText || ""))
    } catch (error) {
        return null
    }
    if (!doc || typeof doc !== "object") return null
    if (typeof doc.int === "number" && isFinite(doc.int)
            && doc.int === Math.floor(doc.int))
        return { original: String(doc.int), nudged: String(doc.int + 1) }
    var text = typeof doc.css === "string" ? doc.css
        : typeof doc.custom === "string" ? doc.custom : null
    if (text === null || !NUMBERS.test(text)) return null
    return {
        original: text,
        nudged: text.replace(/-?\d+/, function (first) {
            return String(Number(first) + 1)
        })
    }
}

/// Whether a `hyprctl keyword` write landed: exit 0 and the compositor's
/// own `ok`. hyprctl exits 0 on a refusal too, so the answer decides.
function writeLanded(exitCode, stdout) {
    return exitCode === 0 && String(stdout || "").trim() === "ok"
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

/// A write finished; `landed` is writeLanded's verdict.
function written(state, landed) {
    if (state.phase === "nudging") {
        if (!landed) {
            return {
                state: initial(),
                action: "done",
                // Expected under the Lua config parser, which refuses
                // `keyword`: nothing changed, so a journal line, no warning.
                log: { level: "log", text: "[oskar] the relayout nudge was refused;"
                    + " general:gaps_out is unchanged" }
            }
        }
        return {
            state: { phase: "restoring", original: state.original,
                nudged: state.nudged, retried: false },
            action: "wait"
        }
    }
    if (state.phase === "restoring") {
        if (landed) return { state: initial(), action: "done" }
        if (!state.retried) {
            return {
                state: { phase: "restoring", original: state.original,
                    nudged: state.nudged, retried: true },
                action: "write",
                value: state.original
            }
        }
        return {
            state: initial(),
            action: "done",
            log: { level: "error", text: "[oskar] could not restore general:gaps_out:"
                + " it is left at \"" + state.nudged + "\", the original was \""
                + state.original + "\"" }
        }
    }
    return { state: state, action: "done" }
}

/// The restore timer fired: write the original back.
function restoreDue(state) {
    if (state.phase !== "restoring") return { state: state, action: "done" }
    return { state: state, action: "write", value: state.original }
}
