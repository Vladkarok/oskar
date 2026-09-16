.pragma library

// The modifier and Caps state machine, kept out of QML on purpose: it is
// the one piece of panel logic with enough branching to earn a test seam, and
// a seam that needs a running shell is not a seam. Events in, next state and
// the protocol lines to write out — nothing ambient is read, nothing is
// mutated in place.
//
// Why the states behave the way they do. One hand on a mouse cannot hold a
// modifier and click a key, so a click latches the modifier for exactly the
// next key press. Shift alone can be double-clicked to lock until clicked
// again; persistent Ctrl, Alt, or Super would turn ordinary typing into an
// unsafe run of shortcuts.
//
// Latched and locked reach the compositor by different routes, and the
// difference matters downstream. A latched modifier is pressed and released
// around the one key it applies to, so nothing is left held between clicks. A
// locked Shift is genuinely held down at the device from the moment it locks,
// which is what makes the lock indicator true.
//
// A latch is consumed by the next non-modifier press whether or not the
// compositor swallowed that press as a binding. The panel cannot know a bind
// fired, so "clear on the next key" is the only rule it can implement
// honestly, and it is what a physical keyboard does.

/// The roster, in the order modifiers are pressed around a key. Releases go in
/// the reverse order, the way a hand would let go.
///
/// `level5` is in the roster but on no cap: it is the reserved symbol block's
/// own level opener (decisions §33), asked for by an exact-level press and by
/// nothing else. It never latches and never locks, so every loop that reads a
/// modifier's state simply passes over it.
var ORDER = ["ctrl", "alt", "logo", "level5", "altgr", "shift"]

/// The roster minus `level5`: the modifiers a cap can name and a user click.
var CLICKABLE = ["ctrl", "alt", "logo", "altgr", "shift"]

/// The positions that carry each modifier. Positions rather than names because
/// the panel sends positions and the compositor decides what they mean; this
/// is the only table of them in the project.
var POSITIONS = {
    ctrl: "LCTL",
    alt: "LALT",
    logo: "LWIN",
    level5: "LVL5",
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
    // The two most recent Shift clicks, newest in `lastClick`, each
    // `{ modifier, before }`. A double click arrives after its own two clicks
    // have already been applied, so `doubleClick` needs to know where the
    // gesture started rather than where those clicks left it — see there.
    state.lastClick = null
    state.prevClick = null
    return state
}

/// Whether a cap key names a modifier the user can click.
///
/// Not `POSITIONS.hasOwnProperty`: `level5` is in that table because a press
/// has to know which position carries it, but it is on no cap and has no
/// click, latch or lock. Answering yes for it would let a cap named "level5"
/// latch a modifier that then joined every chord.
function isModifier(name) {
    return CLICKABLE.indexOf(String(name || "")) !== -1
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
///   { type: "press",        position, letter, shift, altgr, level5,
///                           level3Position, exact, configureStamp }
///   { type: "release",      dropRestore }
///   { type: "configureDrain", stamp }
///   { type: "pageSwitch" }
///   { type: "languageSwitch" }
///   { type: "releaseAll" }
///   { type: "paste",        ctrl, shift, position }
///
/// `shift` on a press means the cap draws the position's shift level and must
/// type that level — the symbols page (spec-v1 §4). Like Caps Lock it is
/// satisfied with a real Shift press around the key rather than by choosing a
/// character, because the compositor resolves the position through its own
/// layout and the panel does not get to decide what comes out. `altgr` is the
/// curated page's answer for the keymap's AltGr levels (spec-v1.1 §3): level
/// 3 carries AltGr alone, level 4 AltGr and Shift — the same real-modifier
/// press around the key, one boundary further into the keymap the user
/// already has, and never a new input mechanism.
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
        return release(state, event)
    // A configure that changed the keymap drained every key the helper
    // held. The panel settles to the device world WITHOUT emitting —
    // see configureDrain below.
    case "configureDrain":
        return configureDrain(state, event)
    // A page switch changes what can be seen, not what is held: locked
    // modifiers stay down and latched ones stay armed, because neither is a
    // key press and only a key press consumes a latch. Same for a language
    // switch, which moves the group and touches nothing else.
    case "pageSwitch":
    case "languageSwitch":
        return unchanged(state)
    case "releaseAll":
        return releaseAll(state)
    case "paste":
        return paste(state, event)
    }
    return unchanged(state)
}

/// Classes whose CLIPBOARD paste is Ctrl+Shift+V, not Shift+Insert.
/// Shift+Insert is PRIMARY in typical terminals (foot.ini primary-paste,
/// kitty paste_from_selection). Empty/stale class must not fail open to
/// that PRIMARY chord — prefer the terminal CLIPBOARD chord instead.
/// Reverse-DNS last components (org.kde.konsole → konsole) share the map.
var TERMINAL_CLIPBOARD_CLASSES = {
    "foot": true,
    "footclient": true,
    "kitty": true,
    "alacritty": true,
    "ghostty": true,
    "wezterm": true,
    "kgx": true,
    "console": true,
    "gnome-terminal": true,
    "gnome-terminal-server": true,
    "terminal": true,
    "konsole": true,
    "xfce4-terminal": true,
    "agterm": true
}

/// The paste chord the header control sends for a focused client class.
/// CLIPBOARD, not PRIMARY: terminals bind Shift+Insert to primary-paste and
/// Ctrl+Shift+V to clipboard-paste; GTK binds Shift+Insert to paste-clipboard.
/// Ctrl+V is not universal (terminals type a literal). Unknown non-empty
/// classes keep the GTK chord, which is the native and XWayland path already
/// proven. Empty class uses the terminal CLIPBOARD chord so a stale lookup
/// cannot send PRIMARY into a terminal.
///
/// Wine/Proton binds paste to plain Ctrl+V: Shift+Insert reaches the game
/// as an unbound key and the terminal CLIPBOARD chord is not Wine's binding
/// either — the owner's Proton report on ticket 28's acceptance day, where
/// only manual Ctrl+V pasted.
///
/// V is AB04 (z x c v). AB06 is N. Ctrl+Shift+N opens a new window in
/// kitty, ghostty, and agterm — the chord this used to send.
function pasteChordForClass(wmClass) {
    var cls = String(wmClass || "").toLowerCase()
    if (usesWinePasteChord(cls))
        return { ctrl: true, shift: false, position: "AB04" }
    if (!cls || usesTerminalClipboardChord(cls))
        return { ctrl: true, shift: true, position: "AB04" }
    return { ctrl: false, shift: true, position: "INS" }
}

function usesWinePasteChord(cls) {
    // Proton game windows carry the Windows executable's name as their
    // class ("football.exe"); Hyprland reports Steam Proton titles as
    // "steam_proton" or "steam_app_<id>" (the owner's "Last War" is
    // "steam_proton"), and Wine's own surfaces carry "wine"
    // ("wine64-preloader").
    if (cls.indexOf("wine") !== -1 || cls.indexOf("proton") !== -1) return true
    if (cls.indexOf("steam_app") === 0) return true
    return cls.slice(-4) === ".exe"
}

function usesTerminalClipboardChord(cls) {
    if (TERMINAL_CLIPBOARD_CLASSES[cls]) return true
    var dot = cls.lastIndexOf(".")
    if (dot < 0) return false
    return TERMINAL_CLIPBOARD_CLASSES[cls.slice(dot + 1)] === true
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
    if (modifier === "shift") {
        out.state.prevClick = state.lastClick
        out.state.lastClick = { modifier: modifier, before: state[modifier] }
    } else {
        out.state.lastClick = null
        out.state.prevClick = null
    }
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
    if (modifier !== "shift") {
        var canceled = transition(state, modifier, "idle")
        canceled.state.lastClick = null
        canceled.state.prevClick = null
        return canceled
    }
    var origin = gestureOrigin(state, modifier)
    var out = transition(state, modifier, origin === "locked" ? "idle" : "locked")
    // The gesture is spent. Leaving it behind would let the next single click
    // roll back to it instead of acting on what is actually on screen.
    out.state.lastClick = null
    out.state.prevClick = null
    return out
}

/// What to do with Shift around this press: "wrap" (down before, up after),
/// "leave-down" (a lock the level wants — no line, it is already down),
/// "lift-around" (a lock the press does not want: up before, back down
/// after), or "ignore" (nothing held, nothing wanted). Ordinary presses
/// follow §5: Caps interplay on letters, a latched Shift wrapping every
/// non-letter press, Caps Lock emulated with a real Shift press because the
/// CAPS position is rarely Caps Lock (`grp:caps_*` and `compose:caps` own
/// it). An exact-level press (the curated page's caps, `exact` on the event)
/// answers only from the level it carries: Shift wraps when the level is 2
/// or 4, a lock the level does not want is lifted around the press, and a
/// latch never decides the chord — a latched Shift or AltGr is not applied
/// by an exact press, but it is still consumed by one, as §2 spends the
/// latches of any non-modifier key.
function shiftForPress(state, event) {
    if (event.exact === true) {
        if (state.shift === "locked") {
            return event.shift === true ? "leave-down" : "lift-around"
        }
        return event.shift === true ? "wrap" : "ignore"
    }
    if (state.shift === "locked") {
        return state.caps && event.letter ? "lift-around" : "leave-down"
    }
    if (state.shift === "latched") {
        return shiftWanted(state, event, true) ? "wrap" : "ignore"
    }
    return event.shift === true || shiftWanted(state, event, false) ? "wrap" : "ignore"
}

function press(state, event) {
    var position = String(event.position || "")
    if (!position) return unchanged(state)

    // An exact-level press (the curated page's caps, `exact` on the event)
    // types exactly the level it draws: the chord is the level's decision —
    // Shift and AltGr wrap when and only when the level wants them, never
    // because a latch is armed. What the level does not decide is the
    // latch's lifetime. A curated cap is an ordinary non-modifier key to
    // §2, so it spends latched Shift/AltGr exactly as an ordinary press
    // would — never applied, always consumed — or the latch would sit armed
    // past a symbol and shift the next ordinary key behind the user's back.
    var exact = event.exact === true

    var next = copy(state)
    // The chord is built as a SET (`wants`), never a push-list: Shift's plan
    // is decided once below and the latch loop only consumes, so no
    // modifier can be planned twice. The old shape pushed Shift from the
    // latch loop and again from its own plan step (and AltGr from the latch
    // loop and again from the level flag), so an exact level-4 press with
    // both latched could list each twice — masked by the later indexOf
    // scans, but the plan the pending record carried was a lie.
    var wants = {}
    var restore = []

    // Shift around the key, decided in exactly one place — see
    // shiftForPress. "wrap" joins the chord, "lift-around" lands in
    // `restore` (lifted before the key, back down after it, its semantic
    // lock untouched), "leave-down" and "ignore" stay out of both.
    var shiftPlan = shiftForPress(state, event)
    if (shiftPlan === "wrap") wants.shift = true
    if (shiftPlan === "lift-around") restore.push("shift")

    for (var i = 0; i < ORDER.length; i++) {
        var modifier = ORDER[i]
        if (state[modifier] !== "latched") continue
        // Every latch is spent by a non-modifier press, exact or not (§2).
        next[modifier] = "idle"
        // Whether a spent latch also joins the chord: Shift had its say
        // above and is never decided twice; AltGr on an exact press follows
        // the level flag — the chord is the level's, not the latch's — and
        // Ctrl, Alt and Super are ordinary modifiers on every press and
        // wrap as §5 says.
        if (modifier === "shift") continue
        if (exact && modifier === "altgr") {
            if (event.altgr === true) wants.altgr = true
            continue
        }
        wants[modifier] = true
    }

    // Level 3 or 4 needs AltGr held around the key the same way level 2
    // needs Shift: a real press of the position's own modifier, never a
    // character chosen by the panel — latch or no latch, the wrap is what
    // selects the level. A locked AltGr cannot happen (§16 — only Shift
    // locks) and is left alone regardless.
    if (event.altgr === true
            && (exact || (state.altgr !== "latched" && state.altgr !== "locked"))) {
        wants.altgr = true
    }

    // Levels five to eight the same way, one modifier further out: <LVL5> is
    // ISO_Level5_Shift in every group of every compiled keymap, and only an
    // exact-level press ever asks for it. There is no cap and no latch to
    // weigh — the level either wants it or does not.
    if (event.level5 === true) wants.level5 = true

    var wrap = []
    for (var d = 0; d < ORDER.length; d++) {
        if (wants[ORDER[d]]) wrap.push(ORDER[d])
    }

    // Which key actually carries each modifier for THIS press. AltGr is the
    // one that can move: the panel's AltGr cap means RALT, whatever the
    // layout makes of it, but a cap resolved at level 3 or 4 of the reserved
    // symbol block (ticket 18) needs a position that is ISO_Level3_Shift in
    // every group — RALT is not, on `us`. The event names it; nothing else
    // about the chord changes, and the release below lifts what was pressed
    // rather than what POSITIONS says today.
    var positions = {}
    if (typeof event.level3Position === "string" && event.level3Position !== "") {
        positions.altgr = event.level3Position
    }
    var positionOf = function (modifier) {
        return positions[modifier] || POSITIONS[modifier]
    }

    var lines = []
    for (var r = restore.length - 1; r >= 0; r--) {
        lines.push("up " + positionOf(restore[r]))
    }
    for (var k = 0; k < wrap.length; k++) {
        lines.push("down " + positionOf(wrap[k]))
    }
    // `down`, not `tap`: the key stays down for as long as the mouse button
    // does, and the compositor repeats it at the user's own repeat_delay and
    // repeat_rate (spec-v1 §6). A tap could only ever type once, and a panel
    // timer that made up the difference could not match the user's settings.
    lines.push("down " + position)
    // The configure-send count when this chord went down. A configure queued
    // after this number reaches the helper AHEAD of the release lines (the
    // socket is ordered), which is what lets the panel tell a chord a drain
    // ran past from one it did not touch — see configureDrain and the
    // release's dropRestore below.
    next.pending = {
        position: position,
        wrap: wrap,
        restore: restore,
        // The override travels with the chord: a release that recomputed it
        // would lift RALT for a key that went down on LVL3.
        positions: positions,
        configureStamp: typeof event.configureStamp === "number"
            ? event.configureStamp : 0
    }
    return { state: next, lines: lines }
}

/// The other half of a press: lifts the key, then the modifiers wrapped around
/// it, in the reverse of the order they went down. A release with nothing
/// pending emits nothing, which is what makes it safe to call from both
/// `released` and `canceled`.
///
/// `event !== false` is the ordinary call shape; `releaseAll` passes `false`
/// for the internal call because it plans its own lifts. `event.dropRestore`
/// is the mid-chord-drain answer: `up` lines for keys the helper no longer
/// holds are forwarded and dropped by the compositor, but a restorative
/// `down` would genuinely re-press a modifier the device world lost — a lock
/// resurrected behind the panel's back. The panel knows when a draining
/// configure sits ahead of these lines in the socket queue and says so.
function release(state, event) {
    if (!state.pending) return unchanged(state)
    var next = copy(state)
    next.pending = null
    var held = state.pending.positions || {}
    var lifted = function (modifier) {
        return held[modifier] || POSITIONS[modifier]
    }
    var lines = ["up " + state.pending.position]
    for (var u = ORDER.length - 1; u >= 0; u--) {
        if (state.pending.wrap.indexOf(ORDER[u]) !== -1) {
            lines.push("up " + lifted(ORDER[u]))
        }
    }
    if (event !== false && !(event && event.dropRestore === true)) {
        var restore = state.pending.restore || []
        for (var r = 0; r < ORDER.length; r++) {
            if (restore.indexOf(ORDER[r]) !== -1) {
                lines.push("down " + lifted(ORDER[r]))
            }
        }
    }
    return { state: next, lines: lines }
}

/// The panel-side twin of the helper's install_config drain: state only,
/// never lines. Everything the device held is idle again; Caps and Fn stay —
/// they are semantic panel controls, never held at the device. One chord may
/// outlive the drain it was stamped against: the panel's send counter
/// increments when a configure is WRITTEN, so a chord whose stamp is equal
/// to or greater than the draining configure's seq (`pending.configureStamp
/// >= stamp`) was pressed at or after the send — the drain ran before the
/// press lines — and really holds its key at the device, so its pending
/// record survives and the later mouse-up still lifts it, minus the restore
/// plan, whose downs would re-press a lock the device no longer holds. A
/// strictly earlier stamp means the press lines precede the configure in
/// the queue and were drained with everything else; a pending without a
/// stamp (0) predates every configure seq and is dropped whole. A FAILED
/// configure passes stamp -1: whatever the failure mode, the panel settles
/// to idle and explicitly lifts what it had locked, so no stamp can read as
/// "before" the failure — every pending record survives (minus restore),
/// because the chord's own hold is real in the never-drained case and its
/// mouse-up is a forwarded no-op in the drained one.
function configureDrain(state, event) {
    var stamp = typeof event.stamp === "number" ? event.stamp : 0
    var next = initialState()
    next.caps = state.caps
    next.fn = state.fn
    var pending = state.pending
    if (pending && typeof pending.configureStamp === "number"
            && pending.configureStamp >= stamp) {
        next.pending = {
            position: pending.position,
            wrap: pending.wrap,
            restore: [],
            // The per-chord AltGr key survives the drain with everything else
            // it describes. Dropping it here sent `up RALT` for a key that
            // went down on LVL3 — and a refused configure is exactly the path
            // where the helper did NOT drain, so that key really is still
            // held. Mod5 would then stay asserted for the rest of the
            // session: the cap is exempt from the fifteen-second lift
            // (modifiers are), AltGr can never be locked so the err handler's
            // lock sweep misses it, and the helper re-derives its mask from
            // what it holds, so `mods 0` cannot clear it either.
            positions: pending.positions || {},
            configureStamp: pending.configureStamp
        }
    }
    return { state: next, lines: [] }
}

/// Whether this press should carry Shift, given what Caps is doing.
/// `shiftLatched` says whether the caller is asking about the latched Shift
/// (which Caps Lock cancels on a letter) or about Caps Lock alone.
function shiftWanted(state, event, shiftLatched) {
    if (!event.letter) return shiftLatched
    return state.caps ? !shiftLatched : shiftLatched
}

/// An explicit current-content paste (spec-v1.1 §1): a complete exact chord
/// in one event, never a held cap. `ctrl`/`shift`/`position` are the chord
/// the caller chose; latched Ctrl/Alt/Super are spent and never mixed in,
/// and locked Shift is lifted around a chord that does not want it so a
/// lock cannot silently turn Ctrl+V into Ctrl+Shift+V. A key already held
/// is left alone — paste does not interleave with a press still down.
function paste(state, event) {
    var position = String(event && event.position || "")
    if (!position || state.pending) return unchanged(state)

    var next = copy(state)
    for (var i = 0; i < ORDER.length; i++) {
        if (next[ORDER[i]] === "latched") next[ORDER[i]] = "idle"
    }

    var wantCtrl = event.ctrl === true
    var wantShift = event.shift === true
    var shiftLocked = state.shift === "locked"
    var lines = []
    if (shiftLocked && !wantShift) lines.push("up " + POSITIONS.shift)
    if (wantCtrl) lines.push("down " + POSITIONS.ctrl)
    if (wantShift && !shiftLocked) lines.push("down " + POSITIONS.shift)
    lines.push("down " + position)
    lines.push("up " + position)
    if (wantShift && !shiftLocked) lines.push("up " + POSITIONS.shift)
    if (wantCtrl) lines.push("up " + POSITIONS.ctrl)
    if (shiftLocked && !wantShift) lines.push("down " + POSITIONS.shift)
    return { state: next, lines: lines }
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
