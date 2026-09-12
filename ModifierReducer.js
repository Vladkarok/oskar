.pragma library

// The modifier state machine (spec-v1 §5), kept out of QML on purpose: it is
// the one piece of panel logic with enough branching to earn a test seam, and
// a seam that needs a running shell is not a seam. Events in, next state and
// the protocol lines to write out — nothing ambient is read, nothing is
// mutated in place.
//
// Why the states behave the way they do. One hand on a mouse cannot hold a
// modifier and click a key, so a click latches the modifier for exactly the
// next key press and a double click locks it until clicked again.
//
// Latched and locked reach the compositor by different routes, and the
// difference matters downstream. A latched modifier is pressed and released
// around the one key it applies to, so nothing is left held between clicks. A
// locked modifier is genuinely held down at the device from the moment it
// locks — which is what makes the lock indicator true, and why the helper's
// stuck-key cap exempts modifier codes (spec-v1 §6): a locked Ctrl is
// deliberately down for minutes.
//
// A latch is consumed by the next non-modifier press whether or not the
// compositor swallowed that press as a binding. The panel cannot know a bind
// fired, so "clear on the next key" is the only rule it can implement
// honestly, and it is what a physical keyboard does.

/// The roster, in the order modifiers are pressed around a key. Releases go in
/// the reverse order, the way a hand would let go.
var ORDER = ["ctrl", "alt", "logo", "altgr", "shift"]

/// The positions that carry each modifier. Positions rather than names because
/// the panel sends positions and the compositor decides what they mean; this
/// is the only table of them in the project.
var POSITIONS = {
    ctrl: "LCTL",
    alt: "LALT",
    logo: "LWIN",
    altgr: "RALT",
    shift: "LFSH"
}

function initialState() {
    var state = {}
    for (var i = 0; i < ORDER.length; i++) {
        state[ORDER[i]] = "idle"
    }
    return state
}

function isModifier(name) {
    return POSITIONS.hasOwnProperty(String(name || ""))
}

/// True while the modifier is doing something — latched or locked. What the
/// caps redraw and the "is this key lit" question both want.
function isActive(state, modifier) {
    var value = state[modifier]
    return value === "latched" || value === "locked"
}

function positionFor(modifier) {
    return POSITIONS[String(modifier || "")] || ""
}

function copy(state) {
    var out = {}
    for (var name in state) out[name] = state[name]
    return out
}

function unchanged(state) {
    return { state: state, lines: [] }
}

/// (state, event) -> { state, lines }
///
/// Events:
///   { type: "click",        modifier }
///   { type: "doubleClick",  modifier }
///   { type: "press",        position, letter, caps }
///   { type: "pageSwitch" }
///   { type: "languageSwitch" }
///   { type: "releaseAll" }
function reduce(state, event) {
    var type = event ? String(event.type) : ""
    switch (type) {
    case "click":
        return click(state, event.modifier)
    case "doubleClick":
        return doubleClick(state, event.modifier)
    case "press":
        return press(state, event)
    // A page switch changes what can be seen, not what is held: locked
    // modifiers stay down and latched ones stay armed, because neither is a
    // key press and only a key press consumes a latch. Same for a language
    // switch, which moves the group and touches nothing else.
    case "pageSwitch":
    case "languageSwitch":
        return unchanged(state)
    case "releaseAll":
        return releaseAll(state)
    }
    return unchanged(state)
}

function click(state, modifier) {
    if (!isModifier(modifier)) return unchanged(state)
    var next = copy(state)
    switch (state[modifier]) {
    case "locked":
        next[modifier] = "idle"
        return { state: next, lines: ["up " + POSITIONS[modifier]] }
    case "latched":
        // Straight back to idle. Promotion to locked is the double-click
        // path only, so a second single click undoes the first rather than
        // escalating it.
        next[modifier] = "idle"
        return { state: next, lines: [] }
    default:
        next[modifier] = "latched"
        return { state: next, lines: [] }
    }
}

function doubleClick(state, modifier) {
    if (!isModifier(modifier)) return unchanged(state)
    var next = copy(state)
    if (state[modifier] === "locked") {
        next[modifier] = "idle"
        return { state: next, lines: ["up " + POSITIONS[modifier]] }
    }
    next[modifier] = "locked"
    return { state: next, lines: ["down " + POSITIONS[modifier]] }
}

function press(state, event) {
    var position = String(event.position || "")
    if (!position) return unchanged(state)

    var next = copy(state)
    var wrap = []
    for (var i = 0; i < ORDER.length; i++) {
        var modifier = ORDER[i]
        if (state[modifier] !== "latched") continue
        next[modifier] = "idle"
        if (modifier === "shift" && !shiftWanted(event, true)) continue
        wrap.push(modifier)
    }

    // Caps Lock is emulated with Shift rather than by tapping the CAPS
    // position: on the owner's setup that position is the layout toggle
    // (grp:caps_toggle), so pressing it would switch language instead. The
    // emulation only reaches letter keys, since a shifted digit is a
    // different symbol rather than a capital.
    //
    // A locked Shift is already down at the device and cannot be lifted for
    // one key, so caps and a locked Shift do not cancel the way caps and a
    // latched Shift do. That combination is degenerate and left alone.
    if (state.shift !== "latched" && state.shift !== "locked" && shiftWanted(event, false)) {
        wrap.push("shift")
    }

    var lines = []
    for (var d = 0; d < ORDER.length; d++) {
        if (wrap.indexOf(ORDER[d]) !== -1) lines.push("down " + POSITIONS[ORDER[d]])
    }
    lines.push("tap " + position)
    for (var u = ORDER.length - 1; u >= 0; u--) {
        if (wrap.indexOf(ORDER[u]) !== -1) lines.push("up " + POSITIONS[ORDER[u]])
    }
    return { state: next, lines: lines }
}

/// Whether this press should carry Shift, given what Caps Lock is doing.
/// `shiftLatched` says whether the caller is asking about the latched Shift
/// (which Caps Lock cancels on a letter) or about Caps Lock alone.
function shiftWanted(event, shiftLatched) {
    if (!event.letter) return shiftLatched
    return event.caps ? !shiftLatched : shiftLatched
}

/// Lifts everything the device is holding for us and returns to idle. Used
/// when the panel closes or reconnects to a helper that no longer shares its
/// idea of what is down.
function releaseAll(state) {
    var lines = []
    for (var i = ORDER.length - 1; i >= 0; i--) {
        if (state[ORDER[i]] === "locked") lines.push("up " + POSITIONS[ORDER[i]])
    }
    return { state: initialState(), lines: lines }
}
