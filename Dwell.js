.pragma library
.import "HoldColumn.js" as HoldColumn

// Ticket 50: dwell-to-type — hover a cap for D milliseconds and it types,
// press+release as one click. The pure state machine, kept out of QML so
// the host suite can pin it (tests/dwell.qml), the ModifierReducer.js and
// HoldColumn.js discipline. The QML side delivers enter/move/leave events,
// runs one deadline timer, and maps the returned action onto the SAME
// press paths a physical click takes — the machine owns every
// timing-shaped decision and reads no clock of its own: `now` is always
// injected, which is what makes the seam testable.
//
// Three decisions live here beside the machine:
//
//   eligible — which caps dwell at all. Dwell is an INPUT affordance:
//     character caps (Space included — its fixed label is the panel's own
//     drawing of a real character), the sticky modifiers (a dwell on Shift
//     latches Shift, exactly what a click does), and the keysym caps
//     (BackSpace, Enter, Tab, the arrows — the nav caps exist because they
//     are pointer-unreachable, and for a dwell user they are the point).
//     The panel's own chrome never dwells: the gear, the language chip,
//     the paste chip and the emoji page's cells are not caps and never
//     route through this rule, and the grid's own command caps (close,
//     page, emoji, fn, caps) are named excluded so that edge is a
//     decision, not an accident — resting the pointer while traversing the
//     board must never close the panel, flip the page, open a picker, or
//     toggle a semantic layer under the pointer's feet, because those
//     actions re-render or destroy the surface the pointer is resting on.
//     A gated keyboard dwells nothing (spec-v1.1 §6: no press path), and
//     the emoji search arm never dwells — the page is excluded chrome, and
//     its search is immediate by contract (ticket 37 refused the defer for
//     the same reason).
//
//   holdDefers — the 37 interplay. In dwell mode no cap defers its typing
//     to mouse-release: the dwell IS the click, a press types immediately,
//     and the column menu is reached by dwelling PAST the type, never by
//     holding a button. With dwell off, holdDefers is HoldColumn.shouldDefer
//     unchanged — today's press/release/menu behaviour is regression-pinned
//     by tests/hold-column.qml and tests/dwell.qml together.
//
//   the menu window — the span between the type and the menu is DERIVED
//     from HoldColumn.HOLD_THRESHOLD_MS, not copied: one hold vocabulary,
//     and the two numbers cannot drift.
//
//   the menu's own entries (slice two) — a pure-dwell user opened the
//     column menu by resting past the type; the entries are dwell targets
//     too, or one click is still owed to PICK. An entry is not a cap, so
//     eligibility is its own rule, and the rest has no second threshold:
//     the pick is the destination.

/// The delay's designed window, in milliseconds: 400 is faster than a
/// deliberate pause, 2000 slower than anyone would wait, ~800 reads as
/// "rest", not "brush". The setting is off by default; the delay only
/// matters to someone who turned it on.
var DELAY_MIN_MS = 400
var DELAY_MAX_MS = 2000
var DELAY_DEFAULT_MS = 800

/// How long the continued rest after a type keeps arming ticket 37's
/// column menu. Read from HoldColumn so it stays 37's own window by
/// construction — see the module header.
var MENU_WINDOW_MS = HoldColumn.HOLD_THRESHOLD_MS

/// The caps that are the panel's own commands rather than input. This
/// restates triggerSpecial's fixed cases (close, emoji, page, fn, caps),
/// the HoldColumn "restated, not re-derived, so the two cannot drift"
/// discipline; everything else carrying a `key` is a modifier or a keysym
/// cap, and both are input.
var COMMAND_CAPS = { close: true, page: true, emoji: true, fn: true, caps: true }

/// Clamp a delay into the designed window. Validation owns the file
/// (Config.js); this owns the timer, for whatever the QML boundary hands
/// over — the effectiveKeyRadius pattern.
function delayFor(value) {
    var n = Number(value)
    if (!isFinite(n)) n = DELAY_DEFAULT_MS
    if (n < DELAY_MIN_MS) n = DELAY_MIN_MS
    if (n > DELAY_MAX_MS) n = DELAY_MAX_MS
    return Math.round(n)
}

/// The menu deadline for a delay: the delay plus the hold window.
function menuDelayFor(delay) {
    return delayFor(delay) + MENU_WINDOW_MS
}

/// Whether a cap dwells at all — see the module header for the whole
/// rule. `capData` is the resolved cap, `searchMode` the keyboard's search
/// interception state, `inputReady` its typing gate.
function eligible(capData, searchMode, inputReady) {
    if (inputReady !== true) return false
    if (searchMode === true) return false
    if (!capData) return false
    if (capData.spacer === true) return false
    if (capData.unavailable === true) return false
    if (!capData.key) return true
    return COMMAND_CAPS[capData.key] !== true
}

/// Whether ticket 37's release-defer stands for this cap: never in dwell
/// mode (the dwell is the click), exactly HoldColumn.shouldDefer outside
/// it. The composition is here, not in the QML, so the interplay is a
/// pinned decision rather than an untestable wiring detail.
function holdDefers(dwellEnabled, capData, entries, searchMode, inputReady) {
    if (dwellEnabled === true) return false
    return HoldColumn.shouldDefer(capData, entries, searchMode, inputReady)
}

/// Whether a hold-menu ENTRY is a dwell target (ticket 50, slice two):
/// a pure-dwell user OPENED the column menu by resting past the type,
/// and needing one click to PICK breaks the click-free promise. An
/// entry is not a cap — no xkb position, no key, no chrome exclusion —
/// so this is its own rule, not `eligible`'s: dwell must be on, and the
/// pick's own gate applies (pickHoldEntry's guard, restated — a gated
/// entry draws dim and refuses its click, and its dwell refuses
/// identically). The menu's padding and the gaps between entries are
/// not entries: the hover shield (0105888) swallows a rest there whole,
/// and only the entry hit areas ever carry an entry here.
function entryEligible(entry, dwellEnabled, searchMode, inputReady) {
    if (!entry) return false
    if (dwellEnabled !== true) return false
    if (searchMode === true) return false
    if (inputReady !== true) return false
    return true
}

/// The entry arm, composed the holdDefers way — the interplay pinned in
/// the module, not the QML: eligibility plus the machine's enter, with
/// no column by construction (an entry's rest has no second threshold;
/// the pick IS the destination, so the state is spent-proof and the
/// menu window is never consulted). Answers null when nothing armed,
/// which is the wiring's cue to leave the previous rest dead and arm
/// nothing.
function enterEntry(entry, now, delay, dwellEnabled, searchMode, inputReady) {
    if (!entryEligible(entry, dwellEnabled, searchMode, inputReady))
        return null
    var d = delayFor(delay)
    return enter(now, d, menuDelayFor(d), false)
}

/// Arm a rest. `now` is the caller's clock; `delay`/`menuDelay` come from
/// delayFor/menuDelayFor; `hasColumn` is whether the cap's position offers
/// a hold column (the only cap whose continued rest opens the menu). The
/// state is a plain object the caller holds and hands back — nothing
/// ambient is read, nothing is mutated in place.
function enter(now, delay, menuDelay, hasColumn) {
    return {
        t0: now,
        delay: delay,
        menuDelay: menuDelay,
        hasColumn: hasColumn === true,
        phase: "armed"
    }
}

/// One deadline crossing. Actions: "press" (the cap types — press+release
/// as one click), "menu" (the continued rest opens the hold column menu),
/// "none". Phases: "armed" (below the delay), "spent" (typed, menu arming
/// — only reachable for a column cap), "done" (nothing further will ever
/// fire; the wiring drops the state on leave).
function tick(state, now) {
    if (!state) return { action: "none", state: state }
    var elapsed = now - state.t0
    if (state.phase === "armed" && elapsed >= state.delay) {
        return {
            action: "press",
            state: {
                t0: state.t0, delay: state.delay, menuDelay: state.menuDelay,
                hasColumn: state.hasColumn,
                phase: state.hasColumn ? "spent" : "done"
            }
        }
    }
    if (state.phase === "spent" && elapsed >= state.menuDelay) {
        return {
            action: "menu",
            state: {
                t0: state.t0, delay: state.delay, menuDelay: state.menuDelay,
                hasColumn: state.hasColumn, phase: "done"
            }
        }
    }
    return { action: "none", state: state }
}

/// Motion inside the cap. Deliberately inert: cancellation is on LEAVE,
/// not on move — a trembling pointer (the exact user dwell is for) must be
/// able to rest on a key while its hand shakes, and the deadline keeps
/// counting from the enter. The event exists in the API so the seam can
/// say that, and so a future jitter rule has one place to land.
function move(state, now) {
    return { action: "none", state: state }
}

/// The pointer left the cap. "cancel" while anything is still pending —
/// the rest below the delay, or the menu arm above it (the character a
/// spent rest already typed is out and stays out); "none" once nothing is
/// owed. A cancel carries a DEAD state (null): the machine owns the
/// transition, so a late timer tick after a leave cannot fire — the wiring
/// stops the timer, but the seam does not trust that.
function leave(state) {
    if (state && (state.phase === "armed" || state.phase === "spent"))
        return { action: "cancel", state: null }
    return { action: "none", state: state }
}

/// The affordance's fraction: 0 at enter, 1 at the deadline, clamped
/// beyond. This is PROGRESS, not state — the quiet underline it drives
/// must never read as a second unavailable/dim treatment, which is why it
/// only grows and only while a rest is live.
function progress(state, now) {
    if (!state) return 0
    var fraction = (now - state.t0) / state.delay
    if (!isFinite(fraction) || fraction < 0) return 0
    if (fraction > 1) return 1
    return fraction
}
