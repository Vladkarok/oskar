.pragma library

// The modifier and Caps state machine, kept out of QML on purpose: it is
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
    state.caps = false
    // A local display mode, not an XKB modifier. It belongs here so switching
    // the function row cannot accidentally consume or release a real modifier.
    state.fn = false
    // The key the mouse button is currently down on, and the modifiers wrapped
    // around it, so the release can lift them in the right order. Null between
    // presses; see `press` for why a press is not self-contained any more.
    state.pending = null
    // The two most recent clicks, newest in `lastClick`, each
    // `{ modifier, before }`. A double click arrives after its own two clicks
    // have already been applied, so `doubleClick` needs to know where the
    // gesture started rather than where those clicks left it — see there.
    state.lastClick = null
    state.prevClick = null
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
///   { type: "capsClick" }
///   { type: "fnClick" }
///   { type: "click",        modifier }
///   { type: "doubleClick",  modifier }
///   { type: "press",        position, letter, shift }
///   { type: "release" }
///
/// `shift` on a press means the cap draws the position's shift level and must
/// type that level — the symbols page (spec-v1 §4). Like Caps Lock it is
/// satisfied with a real Shift press around the key rather than by choosing a
/// character, because the compositor resolves the position through its own
/// layout and the panel does not get to decide what comes out.
///   { type: "pageSwitch" }
///   { type: "languageSwitch" }
///   { type: "releaseAll" }
function reduce(state, event) {
    var type = event ? String(event.type) : ""
    switch (type) {
    case "capsClick":
        var next = copy(state)
        next.caps = !state.caps
        return { state: next, lines: [] }
    case "fnClick":
        var fnNext = copy(state)
        fnNext.fn = !state.fn
        return { state: fnNext, lines: [] }
    case "click":
        return click(state, event.modifier)
    case "doubleClick":
        return doubleClick(state, event.modifier)
    case "press":
        return press(state, event)
    case "release":
        return release(state)
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

/// The protocol lines that carry a modifier from one state to another. Only
/// `locked` is held at the device, so only crossing that boundary is worth a
/// line: idle and latched are both "not down", and latching emits nothing.
///
/// Every transition goes through here rather than being spelled out at each
/// case, because `doubleClick` can now land on a modifier that the gesture's
/// own earlier clicks already moved. Emitting the difference against the
/// device is the only way to be sure the helper is not told to lift a key it
/// is not holding, or to press one it already is.
function transition(state, modifier, target) {
    var next = copy(state)
    next[modifier] = target
    var was = state[modifier] === "locked"
    var now = target === "locked"
    if (was === now) return { state: next, lines: [] }
    return { state: next, lines: [(now ? "down " : "up ") + POSITIONS[modifier]] }
}

function click(state, modifier) {
    if (!isModifier(modifier)) return unchanged(state)
    // Latched and locked both fall back to idle; idle latches. Promotion to
    // locked is the double-click path only, so a second single click undoes
    // the first rather than escalating it (spec-v1 §5).
    var target = state[modifier] === "idle" ? "latched" : "idle"
    var out = transition(state, modifier, target)
    out.state.prevClick = state.lastClick
    out.state.lastClick = { modifier: modifier, before: state[modifier] }
    return out
}

/// Where the gesture that is ending in this double click began.
///
/// Modifiers act on the way down (issue 17), so by the time Qt tells us the
/// gesture was a double click, both of its presses have already been applied
/// as clicks — the first latching, the second bouncing that latch back to
/// idle. The answer we want is the state before the *first* of them, which is
/// what `prevClick` holds. Two deep rather than one, because a single click
/// immediately before a double click would otherwise be mistaken for the
/// gesture's own first press.
///
/// The modifier has to match: a double click is always preceded by two clicks
/// on the same cap, so anything else is a stale record and the state we can
/// see is the better answer. That fallback is also what makes `doubleClick`
/// meaningful on its own, which is how the seam's other tests drive it.
function gestureOrigin(state, modifier) {
    if (state.prevClick && state.prevClick.modifier === modifier) {
        return state.prevClick.before
    }
    if (state.lastClick && state.lastClick.modifier === modifier) {
        return state.lastClick.before
    }
    return state[modifier]
}

function doubleClick(state, modifier) {
    if (!isModifier(modifier)) return unchanged(state)
    var origin = gestureOrigin(state, modifier)
    var out = transition(state, modifier, origin === "locked" ? "idle" : "locked")
    // The gesture is spent. Leaving it behind would let the next single click
    // roll back to it instead of acting on what is actually on screen.
    out.state.lastClick = null
    out.state.prevClick = null
    return out
}

function press(state, event) {
    var position = String(event.position || "")
    if (!position) return unchanged(state)

    var next = copy(state)
    var wrap = []
    var restore = []
    for (var i = 0; i < ORDER.length; i++) {
        var modifier = ORDER[i]
        if (state[modifier] !== "latched") continue
        next[modifier] = "idle"
        if (modifier === "shift" && !shiftWanted(state, event, true)) continue
        wrap.push(modifier)
    }

    // Caps Lock is emulated with Shift rather than by tapping the CAPS
    // position, because that position is rarely Caps Lock. Any `grp:caps_*`
    // makes it the layout toggle and any `compose:caps` makes it Compose —
    // between them they cover most setups worth supporting, and the owner has
    // run both. Either way, tapping it would do something other than lock. The
    // emulation only reaches letter keys, since a shifted digit is a
    // different symbol rather than a capital.
    //
    // A shift-level cap wants the same thing by a different route, and the
    // same guard covers it: whatever is already holding Shift — the latch
    // wrapped above, or a lock that is genuinely down at the device — is
    // enough, and pressing it a second time would emit a `down` for a code the
    // helper is already holding.
    if (state.shift !== "latched" && state.shift !== "locked"
            && (event.shift === true || shiftWanted(state, event, false))) {
        wrap.push("shift")
    }

    // Caps and Shift cancel for letters. A locked Shift is genuinely held at
    // the device, so lift it around this press and restore it on release. Its
    // semantic state remains locked throughout.
    if (state.caps && event.letter && state.shift === "locked") {
        restore.push("shift")
    }

    var lines = []
    for (var r = restore.length - 1; r >= 0; r--) {
        lines.push("up " + POSITIONS[restore[r]])
    }
    for (var d = 0; d < ORDER.length; d++) {
        if (wrap.indexOf(ORDER[d]) !== -1) lines.push("down " + POSITIONS[ORDER[d]])
    }
    // `down`, not `tap`: the key stays down for as long as the mouse button
    // does, and the compositor repeats it at the user's own repeat_delay and
    // repeat_rate (spec-v1 §6). A tap could only ever type once, and a panel
    // timer that made up the difference could not match the user's settings.
    lines.push("down " + position)
    next.pending = { position: position, wrap: wrap, restore: restore }
    return { state: next, lines: lines }
}

/// The other half of a press: lifts the key, then the modifiers wrapped around
/// it, in the reverse of the order they went down. A release with nothing
/// pending emits nothing, which is what makes it safe to call from both
/// `released` and `canceled`.
function release(state, restoreHeld) {
    if (!state.pending) return unchanged(state)
    var next = copy(state)
    next.pending = null
    var lines = ["up " + state.pending.position]
    for (var u = ORDER.length - 1; u >= 0; u--) {
        if (state.pending.wrap.indexOf(ORDER[u]) !== -1) {
            lines.push("up " + POSITIONS[ORDER[u]])
        }
    }
    if (restoreHeld !== false) {
        var restore = state.pending.restore || []
        for (var r = 0; r < ORDER.length; r++) {
            if (restore.indexOf(ORDER[r]) !== -1) {
                lines.push("down " + POSITIONS[ORDER[r]])
            }
        }
    }
    return { state: next, lines: lines }
}

/// Whether this press should carry Shift, given what Caps is doing.
/// `shiftLatched` says whether the caller is asking about the latched Shift
/// (which Caps Lock cancels on a letter) or about Caps Lock alone.
function shiftWanted(state, event, shiftLatched) {
    if (!event.letter) return shiftLatched
    return state.caps ? !shiftLatched : shiftLatched
}

/// Lifts everything the device is holding for us and returns to idle. Used
/// when the panel closes or reconnects to a helper that no longer shares its
/// idea of what is down.
function releaseAll(state) {
    // Whatever the mouse button is still down on goes first, with its own
    // wrap, before the locks: closing the panel mid-hold must not leave the
    // key repeating into whatever had focus.
    var alreadyUp = state.pending ? state.pending.restore || [] : []
    var lines = release(state, false).lines
    for (var i = ORDER.length - 1; i >= 0; i--) {
        if (state[ORDER[i]] === "locked" && alreadyUp.indexOf(ORDER[i]) === -1) {
            lines.push("up " + POSITIONS[ORDER[i]])
        }
    }
    var next = initialState()
    next.caps = state.caps
    next.fn = state.fn
    return { state: next, lines: lines }
}
