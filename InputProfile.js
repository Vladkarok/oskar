.pragma library
.import "Dwell.js" as Dwell

// Ticket 58: the input profile — the panel knows which pointer world is
// talking to it. Two decisions live here, both pure data so the host suite
// can pin them (tests/input-profile.qml, the Dwell.js/HoldColumn.js
// discipline) and the QML only wires:
//
//   resolve — the effective profile. The setting is "auto" (default) /
//     "mouse" / "touch"; auto activates the touch affordances when the
//     panel OBSERVED touch events, so a 2-in-1 flipping modes never visits
//     Settings (the owner's framing). An explicit mouse/touch wins over
//     the observation; anything else (a value that slipped past the file's
//     validation) degrades to auto's semantics — observed decides.
//
//   affordances — what each profile switches, as a table: which caps type
//     on release, whether dwell may arm, what a tooltip does without
//     hover, the chrome hit-area floor, and whether our own surfaces may
//     steal a sliding finger. The QML never re-derives a value the table
//     already owns.
//
// Three decisions inside it:
//
//   Stickiness: ONCE SEEN, panel lifetime. The observation is a monotonic
//     fact the caller holds (the panel's touchObserved flips true exactly
//     once); there is no decay. A touchscreen laptop's stray mouse click
//     must not flap the profile back mid-session — a flip the other way is
//     the explicit setting's job. A panel restart forgets, and the next
//     observed touch re-teaches it.
//
//   The observation itself: Qt synthesizes the mouse events a MouseArea
//     sees from touch (and tablet) input, and the event's `source` is the
//     only thing that tells a finger from a button. A synthesized event is
//     a touch observation — pens included, deliberately: a pen is a
//     hover-less pointer the same way a finger is, and the touch
//     affordances (release-typing, no dwell) are what it wants too.
//
//   Tooltips, decided per control (the ticket's pin): the header's GLYPH
//     chrome (gear, close, paste) answers a touch-and-hold with its
//     tooltip — "hold" — and the release still acts, help-then-action as
//     one gesture; the TEXT chrome (the mode chip) hides it — "hidden" —
//     because its label already states what it is, and the hold vocabulary
//     stays reserved for input. Everything else that is hover-only today
//     (the emoji cells' names, the settings rows) is hidden on touch by
//     absence: touch synthesizes no hover, so the wiring needs no change
//     and the decision is this comment.

/// The setting's value space. One list here, so validation (Config.js),
/// the popover's segments and the tests cannot disagree — the SUPER_MARKS
/// rule.
var PROFILES = ["auto", "mouse", "touch"]

/// Qt.MouseEventNotSynthesized's value, restated as a number because a
/// .pragma library has no Qt global: the raw `mouse.source` a MouseArea
/// hands over is this when a button produced the event, and anything else
/// when a touch or tablet device did. Pinned against the real enum in the
/// suite.
var MOUSE_SOURCE_NOT_SYNTHESIZED = 0

/// The effective profile: an explicit override wins over the observation,
/// auto (and any junk that degraded to it) follows the observed fact —
/// EXCEPT that dwell answers first (the touch council's a11y guard,
/// ticket 62): a user who ENABLED dwell chose their access method, and
/// one stray touch (theirs, a caregiver's, the cat's) must not disarm
/// it for the panel's life while the recovery path needs the very
/// input that was lost. Auto never flips away from mouse while dwell
/// is on; an explicit touch pin still wins (a deliberate choice).
function resolve(setting, touchObserved, dwellEnabled) {
    if (setting === "mouse") return "mouse"
    if (setting === "touch") return "touch"
    if (dwellEnabled === true) return "mouse"
    return touchObserved === true ? "touch" : "mouse"
}

/// Whether a MouseArea's `mouse.source` was synthesized from a non-mouse
/// device — the one observation the profile is built on.
function isTouchSource(mouseSource) {
    if (mouseSource === undefined || mouseSource === null) return false
    return mouseSource !== MOUSE_SOURCE_NOT_SYNTHESIZED
}

/// The mouse world, byte-today: press-typing with 37's column-only defer
/// (composed through Dwell.holdDefers), a deferred cap's release typing
/// wherever it lands, dwell following its own setting, hover tooltips, hit
/// areas exactly as drawn, no stealing guarantees. The regression pin as
/// data — tests/input-profile.qml deepEquals this whole table.
var MOUSE_AFFORDANCES = {
    profile: "mouse",
    typesOnRelease: false,
    slideOffCancels: false,
    dwellPossible: true,
    tooltipGlyphChrome: "hover",
    tooltipTextChrome: "hover",
    hoverHighlight: true,
    minChromeTargetPx: 0,
    preventStealing: false,
    // Explicit, never 'by absence' (the touch council's finding): hover
    // shows tooltips only in the mouse profile — Qt may synthesize hover
    // from a stationary finger, and the touch answer is hold, not hover.
    tooltipHoverShows: true
}

/// The touch world: character caps type on RELEASE with slide-off cancel,
/// dwell never arms (a finger cannot hover), glyph chrome tooltips move to
/// touch-and-hold, text chrome tooltips hide, hover highlight is inert by
/// absence, chrome hit areas grow invisibly to the 44px floor, and our own
/// surfaces never steal a sliding finger.
var TOUCH_AFFORDANCES = {
    profile: "touch",
    // Explicit, never "by absence" (the touch council): hover never
    // shows a tooltip in touch — possibly-synthesized hover included;
    // the glyph chrome answer is touch-and-hold, text stays hidden.
    tooltipHoverShows: false,
    typesOnRelease: true,
    slideOffCancels: true,
    dwellPossible: false,
    tooltipGlyphChrome: "hold",
    tooltipTextChrome: "hidden",
    hoverHighlight: false,
    minChromeTargetPx: 44,
    preventStealing: true
}

/// The affordance table for an effective profile. An unknown value
/// degrades to the mouse table — the same degrade resolve() owns, so the
/// wiring cannot meet a profile the table does not know.
function affordances(profile) {
    if (profile === "touch") return TOUCH_AFFORDANCES
    return MOUSE_AFFORDANCES
}

/// Whether this cap defers its typing to the pointer's RELEASE — the
/// one typing decision the profile owns. Mouse: Dwell.holdDefers verbatim
/// (ticket 37's column-only defer, ticket 50's dwell veto over it — the
/// composition lives here so the interplay is pinned, not re-wired). Touch:
/// every character cap defers, on the rule below.
function defersTyping(profile, dwellEnabled, capData, entries,
    searchMode, inputReady) {
    if (affordances(profile).typesOnRelease !== true)
        return Dwell.holdDefers(dwellEnabled, capData, entries,
            searchMode, inputReady)
    return touchDefers(capData, searchMode, inputReady)
}

/// The touch defer rule. Touch fingers drift and land imprecisely, so
/// press-typing strands phantom characters — a character cap sends NOTHING
/// at press and types at the lift; leaving the cap before the lift cancels
/// (the wiring's slide-off check, affordances().slideOffCancels). What
/// keeps press semantics is what repeat is the point of: `key` caps
/// (BackSpace, the arrows, the modifiers — the compositor's own repeat,
/// spec-v1 §6) and fixed-label caps (Space, the most-held key on the
/// board). The hold-menu threshold rides the same machinery (beginCapHold
/// / endCapHold): a columnless hold stays pending past the threshold and
/// the release then types, exactly 37's columnless shape. The moment gates
/// (readiness, the press-fed emoji search, availability, spacers) are the
/// gates the press path already keeps, restated here so the two cannot
/// drift.
function touchDefers(capData, searchMode, inputReady) {
    if (inputReady !== true) return false
    if (searchMode === true) return false
    if (!capData) return false
    if (capData.spacer === true) return false
    if (capData.unavailable === true) return false
    if (capData.key) return false
    // drawsFixedLabel's own test (Space's empty label is the panel's own
    // drawing of a real character), restated the HoldColumn way.
    if (Object.prototype.hasOwnProperty.call(capData, "label")) return false
    return true
}

/// Whether dwell may arm at all: the user's setting AND a profile that
/// has hover. In touch the answer is simply never — a finger cannot rest
/// without pressing, and a synthesized press supersedes the rest anyway;
/// a leftover dwell_enabled override must not strand anything.
function dwellArms(profile, dwellEnabled) {
    if (dwellEnabled !== true) return false
    return affordances(profile).dwellPossible === true
}

/// Invisible hit-area growth (px per side) that raises a chrome control's
/// effective target toward the profile's floor: vertical growth takes the
/// full need bounded by the room the caller passes, horizontal growth is
/// additionally capped at the MIDPOINT of the gap to the neighbouring
/// surface — the capHit discipline, so two grown areas tile the gap
/// instead of fighting over it. `minTarget` 0 (mouse) grows nothing
/// anywhere, and a chip already at the floor grows nothing either: the
/// drawn chrome never moves.
function chromeHitGrowth(chipSize, gap, roomUp, roomDown, minTarget) {
    var need = boundedSide((Number(minTarget) - Number(chipSize)) / 2)
    var up = Math.min(need, boundedSide(Number(roomUp)))
    var down = Math.min(need, boundedSide(Number(roomDown)))
    var horizontal = Math.min(need, boundedSide(Number(gap)) / 2)
    return { left: horizontal, right: horizontal, up: up, down: down }
}

function boundedSide(value) {
    if (!isFinite(value) || value < 0) return 0
    return value
}
