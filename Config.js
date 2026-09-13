.pragma library

// The settings store: one authority for the three configuration roles in
// spec-v1.1 §5 — complete shipped defaults, sparse user overrides, and
// geometry/state — and the one home of their validation, reload and
// serialization policy. The panel's popover consumes effective values and
// issues changes through the panel's set/clear/commit operations; it holds
// no persistence policy of its own. Filesystem watching and atomic
// replacement belong to the FileViews in Panel.qml; all interpretation and
// serialization stays here.

var MODE_DOCKED = "docked"
var MODE_FLOATING = "floating"

// The Super cap's mark (ticket 22, 2026-09-09): what the modifier cap draws.
// The word is the default; the others are one mark each — the Omarchy glyph
// (U+E900 in the private font, decisions §27's mechanism), two inline
// vectors and the owner's original Tux SVG. `macos` draws the macOS command mark
// (⌘), which is what that key carries on an Apple keyboard — not an apple.
// One list here, so validation, the popover's segments and the tests cannot
// disagree about the value space.
var SUPER_MARKS = ["word", "omarchy", "windows", "macos", "penguin"]
var EMOJI_SKIN_TONES = ["", "🏻", "🏼", "🏽", "🏾", "🏿"]
// Ticket 28: "direct" types the pick (decisions §39/§40); "clipboard"
// publishes the exact sequence and sends the paste chord — the mode the
// owner chose for Chromium-family clients such as ZCode.
var EMOJI_DELIVERY_MODES = ["direct", "clipboard"]

var CONFIG_FIELDS = [
    { file: "mode", value: "mode" },
    { file: "size_preset", value: "sizePreset" },
    { file: "sound", value: "sound" },
    { file: "follow_theme", value: "followTheme" },
    { file: "emoji_close_after_pick", value: "emojiCloseAfterPick" },
    { file: "emoji_page_size", value: "emojiPageSize" },
    { file: "emoji_delivery", value: "emojiDelivery" },
    { file: "super_mark", value: "superMark" },
    { file: "key_radius", value: "capCorner" },
    { file: "panel_radius", value: "panelRadius" },
    { file: "key_background", value: "keyBackground" },
    { file: "panel_background", value: "panelBackground" },
    { file: "text_color", value: "textColor" },
    { file: "accent_color", value: "accentColor" },
    { file: "border_color", value: "borderColor" }
]

var APPEARANCE_FIELDS = ["capCorner", "panelRadius", "keyBackground",
    "panelBackground", "textColor", "accentColor", "borderColor"]

function maintainerDefaults() {
    return {
        mode: MODE_DOCKED,
        sizePreset: "medium",
        sound: false,
        followTheme: true,
        emojiCloseAfterPick: false,
        emojiPageSize: "medium",
        // Ticket 28: typing is the default delivery (decisions §39/§40);
        // clipboard compatibility is the explicit user's choice for the
        // clients that drop it — never a silent swap.
        emojiDelivery: "direct",
        // The Super cap says what the key is (ticket 22): the Omarchy glyph
        // stops being the unconditional drawing and becomes one chosen mark.
        // Sparse-store semantics mean this key never appears in the file
        // unless the user picked something.
        superMark: "word",
        capCorner: 8,
        panelRadius: 12,
        keyBackground: "#303030",
        panelBackground: "#202020",
        textColor: "#f5f5f5",
        accentColor: "#7aa2f7",
        borderColor: "#5a5a5a"
    }
}

function stateDefaults() {
    return { center: null, emojiUsage: [], emojiSkinTone: "", layoutGroup: 0,
        layoutDevice: "" }
}

function owns(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key)
}

function copyObject(object) {
    var copy = {}
    for (var key in object) {
        if (owns(object, key)) copy[key] = object[key]
    }
    return copy
}

function parseObject(text, role) {
    // Existing but unreadable — including a file truncated to zero bytes —
    // is malformed with the §5 preservation semantics, never an empty
    // override map: reading `{}` here would let a truncated file silently
    // clear every override. A MISSING file takes defaults, and that case is
    // the FileViews' to identify (they alone can tell absent from empty);
    // callers hand this function only text from a file that exists.
    var raw
    try {
        raw = JSON.parse(text)
    } catch (error) {
        return { value: null, error: "Invalid " + role + " JSON" }
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return { value: null, error: "Invalid " + role + " JSON" }
    return { value: raw, error: "" }
}

// Radii are whole pixels: the popover's steppers step by one, and a fractional
// radius from an external edit would round invisibly at the QML boundary.
// Negative or non-finite values are malformed with the §5 preservation
// semantics, not clamped guesses.
function isRadius(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
        && value === Math.floor(value)
}

// Colours are hex only — #RGB, #RGBA, #RRGGBB, #AARRGGBB. The popover's
// picker and swatches write this form, and the typed-hex entry — the panel's
// one sanctioned focus exception (spec-v1.1 §5) — is held to the same rule:
// a named colour or rgb() expression is a malformed value the panel reports
// inline and preserves, not a silently accepted guess.
function isColor(value) {
    return typeof value === "string"
        && /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value.trim())
}

function configField(fileName) {
    for (var i = 0; i < CONFIG_FIELDS.length; i++) {
        if (CONFIG_FIELDS[i].file === fileName) return CONFIG_FIELDS[i]
    }
    return null
}

function configFieldByValue(valueName) {
    for (var i = 0; i < CONFIG_FIELDS.length; i++) {
        if (CONFIG_FIELDS[i].value === valueName) return CONFIG_FIELDS[i]
    }
    return null
}

// The predicate is the field's, not the key spelling's: a snake_case file
// name and the camelCase runtime name of the same field are the same field
// and are held to the same rule (spec-v1.1 §5, review finding R5). An
// unrecognised key is not a setting and has no predicate — it is an unknown
// field, carried verbatim, never applied.
function validFieldValue(field, value) {
    if (field.file === "mode") return value === MODE_DOCKED || value === MODE_FLOATING
    if (field.file === "size_preset")
        return value === "medium" || value === "large" || value === "x-large"
    if (field.file === "sound" || field.file === "follow_theme"
        || field.file === "emoji_close_after_pick")
        return typeof value === "boolean"
    if (field.file === "emoji_page_size")
        return value === "medium" || value === "large" || value === "x-large"
    if (field.file === "emoji_delivery")
        return EMOJI_DELIVERY_MODES.indexOf(value) !== -1
    // Exactly the five marks the popover offers: anything else is a
    // malformed edit with the §5 preservation semantics, never a guess. The
    // QML side independently treats an unknown string as the word, so a
    // value that could not reach the file can never blank the cap either.
    if (field.file === "super_mark")
        return SUPER_MARKS.indexOf(value) !== -1
    if (field.file === "key_radius" || field.file === "panel_radius")
        return isRadius(value)
    if (field.file === "key_background" || field.file === "panel_background"
        || field.file === "text_color" || field.file === "accent_color"
        || field.file === "border_color")
        return isColor(value)
    return true
}

// Verbatim carriage for an unknown key: store it only if the engine will
// hold it as an own property of a plain object, and drop it if it will not.
// The rehearsal on a throwaway keeps the store's own prototype untouchable —
// assigning "__proto__" re-points it (object value) or throws (non-object),
// and V4 silently loses plain assignments for names inherited from
// Object.prototype, "hasOwnProperty" and friends — while the owns() probe
// needs no maintained list of ill-behaved names.
function storeUnknown(map, key, value) {
    var scratch = {}
    try {
        scratch[key] = value
    } catch (error) {
        return
    }
    if (!owns(scratch, key)) return
    map[key] = value
}

function parseOverrides(text) {
    var parsed = parseObject(text, "configuration")
    if (parsed.error) return parsed
    var overrides = {}
    var canonicalSeen = {}
    for (var key in parsed.value) {
        if (!owns(parsed.value, key)) continue
        // A key may name a field canonically (snake_case), by its runtime
        // spelling (camelCase — an alias of the same field), or not at all
        // (an unknown field). Canonical and alias are validated identically:
        // an invalid value under either spelling is a malformed edit with
        // the §5 preservation semantics, so `{"key_radius":8,"capCorner":-20}`
        // cannot smuggle -20 past validation in either JSON order.
        var field = configField(key)
        var isAlias = false
        if (!field) {
            field = configFieldByValue(key)
            isAlias = field !== null
        }
        if (!field) {
            // Unknown fields ride verbatim so a future version's keys
            // survive reload and the panel's own saves. A key the engine
            // will not hold as this map's own property cannot round-trip
            // and is dropped: "__proto__" re-points the prototype instead
            // of storing (or refuses a non-object outright), and V4
            // silently loses plain assignments for a few Object.prototype
            // names such as "hasOwnProperty".
            storeUnknown(overrides, key, parsed.value[key])
            continue
        }
        var value = parsed.value[key]
        if (!validFieldValue(field, value))
            return { value: null, error: "Invalid value for " + key }
        // Validation trims colours (#... with stray padding is accepted), so
        // storage trims them too: what the file would round-trip as a valid
        // override must not come back padded from the panel's own reads and
        // serialization.
        if (isColor(value)) value = value.trim()
        // Duplicate semantic names resolve deterministically: the canonical
        // spelling wins regardless of JSON order. An alias never overwrites
        // a canonical value, and a later canonical value overwrites an
        // earlier alias in place.
        if (isAlias && owns(canonicalSeen, field.value)) continue
        overrides[field.value] = value
        if (!isAlias) canonicalSeen[field.value] = true
    }
    return { value: overrides, error: "" }
}

function parsePoint(value) {
    if (value === null) return null
    if (!value || typeof value !== "object" || Array.isArray(value)) return undefined
    if (typeof value.x !== "number" || typeof value.y !== "number") return undefined
    if (!isFinite(value.x) || !isFinite(value.y)) return undefined
    return { x: value.x, y: value.y }
}

// The deterministic floating anchor (spec-v1.1 §4, decisions §21). The saved
// placement is the card centre in output-local coordinates, and restoring
// derives the top-left from it, clamped only enough to keep the complete card
// on its output. An unchanged centre, card and output therefore restore to
// the exact same top-left every time; a changed preset or output moves the
// card by no more than the clamp demands, instead of the jump a saved
// top-left produces near an edge. A card larger than its output pins to the
// top-left corner rather than inverting the clamp.
function floatingAnchor(center, cardWidth, cardHeight, outputWidth, outputHeight) {
    var x = center.x - cardWidth / 2
    var y = center.y - cardHeight / 2
    var maxX = Math.max(0, outputWidth - cardWidth)
    var maxY = Math.max(0, outputHeight - cardHeight)
    return {
        x: Math.min(Math.max(x, 0), maxX),
        y: Math.min(Math.max(y, 0), maxY)
    }
}

function parseState(text) {
    var parsed = parseObject(text, "state")
    if (parsed.error) return parsed
    var state = stateDefaults()
    if (owns(parsed.value, "center")) {
        var center = parsePoint(parsed.value.center)
        if (center === undefined)
            return { value: null, error: "Invalid value for center" }
        state.center = center
    }
    if (owns(parsed.value, "emoji_usage")) {
        var records = parsed.value.emoji_usage
        if (!Array.isArray(records) || records.length > 64)
            return { value: null, error: "Invalid value for emoji_usage" }
        var seen = []
        for (var i = 0; i < records.length; i++) {
            var record = records[i]
            if (!record || typeof record !== "object" || Array.isArray(record)
                || typeof record.emoji !== "string" || record.emoji === ""
                || typeof record.count !== "number" || !isFinite(record.count)
                || record.count < 1 || record.count !== Math.floor(record.count)
                || typeof record.lastUsed !== "number" || !isFinite(record.lastUsed)
                || record.lastUsed < 1 || record.lastUsed !== Math.floor(record.lastUsed)
                || seen.indexOf(record.emoji) !== -1)
                return { value: null, error: "Invalid value for emoji_usage" }
            seen.push(record.emoji)
            state.emojiUsage.push({ emoji: record.emoji, count: record.count,
                lastUsed: record.lastUsed })
        }
    }
    if (owns(parsed.value, "emoji_skin_tone")) {
        if (EMOJI_SKIN_TONES.indexOf(parsed.value.emoji_skin_tone) < 0)
            return { value: null, error: "Invalid value for emoji_skin_tone" }
        state.emojiSkinTone = parsed.value.emoji_skin_tone
    }
    // The remembered layout group (LayoutDevices' restart fallback): a
    // whole index XKB can carry (0-3), anything else is a malformed edit
    // with the §5 preservation semantics.
    if (owns(parsed.value, "layout_group")) {
        var remembered = parsed.value.layout_group
        if (typeof remembered !== "number" || !isFinite(remembered)
                || remembered < 0 || remembered > 3
                || remembered !== Math.floor(remembered))
            return { value: null, error: "Invalid value for layout_group" }
        state.layoutGroup = remembered
    }
    // The remembered identity of the seat's last typing keyboard: any
    // string (it is matched against the helper's safe inventory later, so
    // a stale name simply never matches), anything but a string is
    // malformed with the §5 preservation semantics.
    if (owns(parsed.value, "layout_device")) {
        if (typeof parsed.value.layout_device !== "string")
            return { value: null, error: "Invalid value for layout_device" }
        state.layoutDevice = parsed.value.layout_device
    }
    return { value: state, error: "" }
}

// Reload results deliberately carry the previous object by identity on error.
// The panel can show the error while leaving runtime state and bad text alone.
function reloadOverrides(previous, text) {
    var parsed = parseOverrides(text)
    return parsed.error ? { value: previous, error: parsed.error } : parsed
}

function reloadState(previous, text) {
    var parsed = parseState(text)
    return parsed.error ? { value: previous, error: parsed.error } : parsed
}

// Non-appearance settings are override then maintained default. Appearance is
// override, then a live shared-theme token while following, then shipped fallback.
// The map form below is the configuration fact the host suite pins; the live,
// reactive application of the same rule is Theme.qml's, which reads the user
// overrides over the tokens it already holds.
function merge(defaults, overrides, theme) {
    var effective = copyObject(defaults)
    var follows = owns(overrides, "followTheme") ? overrides.followTheme : defaults.followTheme
    if (follows && theme) {
        for (var i = 0; i < APPEARANCE_FIELDS.length; i++) {
            var appearance = APPEARANCE_FIELDS[i]
            if (owns(theme, appearance)) effective[appearance] = theme[appearance]
        }
    }
    for (var j = 0; j < CONFIG_FIELDS.length; j++) {
        var valueName = CONFIG_FIELDS[j].value
        if (owns(overrides, valueName)) effective[valueName] = overrides[valueName]
    }
    return effective
}

// File form: the known fields (held under their runtime names, every one of
// them validated at parse or written by the panel's own controls) map back
// to their canonical snake_case names, and every other key is an unknown
// field that serializes verbatim under its own name. Name-mapping is
// therefore impossible for anything validation has not seen — the R5 hole
// where an unvalidated camelCase alias serialized as a canonical
// `key_radius` cannot reopen (spec-v1.1 §5).
function serializeOverrides(overrides) {
    var out = {}
    for (var key in overrides) {
        if (!owns(overrides, key)) continue
        var field = configFieldByValue(key)
        out[field ? field.file : key] = overrides[key]
    }
    return JSON.stringify(out, null, 2) + "\n"
}

// Hex serialization for the popover's colour rows, which compare it against
// each swatch to light the one now in force — an override, or the live/frozen
// token when none. QML colours and plain {r,g,b,a} objects
// (what the host suite passes) both carry 0..1 channels, so one implementation
// serves the runtime and the tests. Opaque colours serialize as #RRGGBB; a
// translucent one keeps its alpha as #AARRGGBB, so a round trip through this
// form never drops a channel the file would have to restore.
function colorByte(value) {
    var n = Math.round(Math.max(0, Math.min(1, Number(value))) * 255)
    var s = n.toString(16)
    return s.length < 2 ? "0" + s : s
}

function toHex(color) {
    if (!color || typeof color !== "object") return ""
    var out = "#"
    // Float channels land just under 1; treat that as opaque so Apply does
    // not write #FE… / reject a colour the HS square just produced.
    var a = typeof color.a === "number" ? color.a : 1
    if (a < 254.5 / 255) out += colorByte(a)
    out += colorByte(color.r) + colorByte(color.g) + colorByte(color.b)
    return out
}

// ---- the colour rows' recommended swatches (2026-09-06 amendment) ----

// Maintained fallbacks for the four swatch sources, used when a theme token
// is unanswered — the same rule Theme.colorAnswered applies (transparent or
// absent is no answer). The shipped palette's own values: a swatch the user
// cannot see is not a recommendation, so outside a shell session the shipped
// colours stand in.
var SWATCH_FALLBACKS = {
    background: "#202020",
    foreground: "#f5f5f5",
    accent: "#7aa2f7",
    muted: "#5a5a5a"
}

function answeredColor(value) {
    return value && typeof value === "object"
        && typeof value.a === "number" && value.a > 0
}

// Up to four distinct swatches derived from the current theme's background,
// foreground, accent and muted colour, in that fixed order, duplicates of
// the resolved colours removed. "Up to": a theme whose four sources resolve
// to fewer distinct colours recommends fewer. Choosing one writes the
// resolved hex as an explicit override — the recommendation is never
// re-resolved behind the user's back after a theme change.
function recommendedSwatches(themeColors) {
    var order = ["background", "foreground", "accent", "muted"]
    var out = []
    for (var i = 0; i < order.length; i++) {
        var name = order[i]
        var candidate = answeredColor(themeColors ? themeColors[name] : null)
            ? toHex(themeColors[name]).toLowerCase()
            : SWATCH_FALLBACKS[name]
        if (out.indexOf(candidate) === -1) out.push(candidate)
    }
    return out
}

// The hex field's one normal form between the draft and the override write:
// trimmed, bare digits prefixed with '#', then the same grammar every other
// colour write passes. `ok` is the commit decision; `value` is what an ok
// draft commits. Not a validation change — isColor stays the single rule.
function normalizeHexDraft(text) {
    var candidate = String(text === null || text === undefined ? "" : text).trim()
    if (candidate.length > 0 && candidate.charAt(0) !== "#")
        candidate = "#" + candidate
    return { ok: isColor(candidate), value: candidate }
}

// Enter and Apply share this decision so a keypress cannot bypass the
// malformed-file guard the buttons carry. `reject` leaves the field
// editable with an error; `hold` keeps a valid draft uncommitted;
// `commit` is the only write.
function commitHexDraft(text, configHealthy) {
    var result = normalizeHexDraft(text)
    if (!result.ok) return { action: "reject", value: result.value }
    if (!configHealthy) return { action: "hold", value: result.value }
    return { action: "commit", value: result.value }
}

// Spec-v1.1 §5: ending the typed-hex exception. The surface returns to
// WlrKeyboardFocus.None, and item focus must be dropped onto a
// non-TextInput: a still-focused hex field is what lets hide hand Qt
// focus to a row field (recapture) or leaves a caret after the pad is
// gone (keystrokes to the previous app). Custom, Cancel and outside
// clicks are dismissals too.
function hexEditRelease() {
    return { hexEditing: false, hexEditField: "", dropItemFocus: true }
}

// Key hover/press are a mix of the resting cap toward the theme foreground,
// never a translucent replacement fill that IS the foreground. The theme's
// hover/press alphas are overlay weights for small chrome; used as the key
// fill they bleach a follow-theme cap to near-white. Clamp so hover stays a
// modest lift, press is stronger, and neither approaches white.
function keyHoverMix(themeHoverAlpha) {
    var a = Number(themeHoverAlpha)
    if (!isFinite(a) || a < 0) a = 0.12
    if (a < 0.08) a = 0.08
    if (a > 0.16) a = 0.16
    return a
}

function keyPressMix(themePressAlpha, hoverMix) {
    var a = Number(themePressAlpha)
    if (!isFinite(a) || a < 0) a = 0.24
    var floor = Number(hoverMix)
    if (!isFinite(floor) || floor < 0) floor = 0.08
    if (a < floor + 0.08) a = floor + 0.08
    if (a > 0.32) a = 0.32
    return a
}

// #RGB / #RGBA / #RRGGBB / #AARRGGBB (alpha-first, same as toHex).
function hexToRgb(hex) {
    var s = String(hex || "").trim()
    if (s.charAt(0) === "#") s = s.slice(1)
    var n = s.length
    if (n !== 3 && n !== 4 && n !== 6 && n !== 8) return null
    function pair(i) {
        return parseInt(s.slice(i, i + 2), 16) / 255
    }
    function nibble(i) {
        var c = s.charAt(i)
        return parseInt(c + c, 16) / 255
    }
    if (n === 3 || n === 4)
        return {
            r: nibble(0), g: nibble(1), b: nibble(2),
            a: n === 4 ? nibble(3) : 1
        }
    if (n === 6)
        return { r: pair(0), g: pair(2), b: pair(4), a: 1 }
    return { a: pair(0), r: pair(2), g: pair(4), b: pair(6) }
}

function colorChannels(value) {
    if (typeof value === "string") {
        var parsed = normalizeHexDraft(value)
        return hexToRgb(parsed.ok ? parsed.value : value)
    }
    if (!value || typeof value !== "object") return null
    var r = Number(value.r), g = Number(value.g), b = Number(value.b)
    if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return null
    var a = typeof value.a === "number" ? Number(value.a) : 1
    if (!isFinite(a)) a = 1
    return { r: r, g: g, b: b, a: a }
}

// Paint `overlay` (possibly translucent, or a hex string from setOverride)
// onto opaque `base`. A hex string has no .r/.g/.b — treating it as a colour
// object produced #000000 in the settings row after Custom Apply.
function compositeOnto(base, overlay) {
    var under = colorChannels(base) || { r: 0, g: 0, b: 0, a: 1 }
    var over = colorChannels(overlay)
    if (!over) return { r: under.r, g: under.g, b: under.b, a: 1 }
    var oa = over.a
    if (oa < 0) oa = 0
    if (oa > 1) oa = 1
    if (oa >= 1) return { r: over.r, g: over.g, b: over.b, a: 1 }
    if (oa <= 0) return { r: under.r, g: under.g, b: under.b, a: 1 }
    return {
        r: over.r * oa + under.r * (1 - oa),
        g: over.g * oa + under.g * (1 - oa),
        b: over.b * oa + under.b * (1 - oa),
        a: 1
    }
}

// Opaque RGB mix of `base` toward `target` at `amount` (0–1). QML colors and
// {r,g,b} objects both carry 0..1 channels. The result is always opaque so
// a follow-theme cap cannot composite to a white square.
function mixRgb(base, target, amount) {
    var a = Number(amount)
    if (!isFinite(a) || a < 0) a = 0
    if (a > 1) a = 1
    var br = Number(base && base.r)
    var bg = Number(base && base.g)
    var bb = Number(base && base.b)
    var tr = Number(target && target.r)
    var tg = Number(target && target.g)
    var tb = Number(target && target.b)
    if (!isFinite(br)) br = 0
    if (!isFinite(bg)) bg = 0
    if (!isFinite(bb)) bb = 0
    if (!isFinite(tr)) tr = 0
    if (!isFinite(tg)) tg = 0
    if (!isFinite(tb)) tb = 0
    return {
        r: tr * a + br * (1 - a),
        g: tg * a + bg * (1 - a),
        b: tb * a + bb * (1 - a),
        a: 1
    }
}

// Size-preset multipliers (spec-v1.1 §4). Key radius is stored as a 0–24
// proportion of a medium key; the drawn radius is stored × this scale so
// 24 stays a circle at L and XL. Panel radius does not use this.
var SIZE_PRESET_SCALES = { "medium": 1.0, "large": 1.2, "x-large": 1.45 }

function effectiveKeyRadius(stored, scale) {
    var n = Number(stored)
    var s = Number(scale)
    if (!isFinite(n) || n < 0) n = 0
    if (!isFinite(s) || s <= 0) s = 1
    return n * s
}

// wl-paste --list-types classification for the header paste chip. Empty
// CLIPBOARD hides the chip; text shows a preview; anything else keeps the
// glyph. `text/html` without text/plain is not a preview (no bogus markup).
function clipboardKind(typesText, exitCode) {
    var raw = String(typesText || "")
    if (exitCode && exitCode !== 0 && raw.replace(/^\s+|\s+$/g, "") === "")
        return "empty"
    var lines = raw.split(/\r?\n/)
    var hasAny = false
    var hasText = false
    var hasImage = false
    for (var i = 0; i < lines.length; i++) {
        var t = lines[i].replace(/^\s+|\s+$/g, "")
        if (!t) continue
        if (/^nothing is copied/i.test(t)) continue
        hasAny = true
        var lower = t.toLowerCase()
        if (lower.indexOf("image/") === 0)
            hasImage = true
        if (lower === "text/plain" || lower.indexOf("text/plain;") === 0
            || lower === "text" || lower === "string"
            || lower === "utf8_string" || lower === "text/uri-list")
            hasText = true
    }
    if (!hasAny) return "empty"
    // Screenshots often advertise text/plain plus image/png; the text
    // offer is empty or garbage. Prefer the glyph over a broken preview.
    if (hasImage) return "other"
    return hasText ? "text" : "other"
}

// Beginning of CLIPBOARD as a single line. Visual ellipsis is the chip's
// ElideRight; this only flattens breaks and caps a huge payload.
function pastePreviewText(raw) {
    var s = String(raw === null || raw === undefined ? "" : raw)
    s = s.replace(/[\r\n\t]+/g, " ").replace(/^\s+|\s+$/g, "")
    if (s.length > 240) s = s.slice(0, 240)
    return s
}

// Chip kind from types classification, the preview string, and whether
// wl-paste --no-newline succeeded. Empty and other apply immediately;
// text stays empty (hidden) until a non-empty preview exists.
function pasteChipKind(typesKind, preview, textExitOk) {
    if (typesKind === "other") return "other"
    if (typesKind !== "text") return "empty"
    if (!textExitOk) return "empty"
    return pastePreviewText(preview) ? "text" : "empty"
}

function clamp01(value) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) return 0
    if (n > 1) return 1
    return n
}

// HSV and RGB channels are 0–1. Hue wraps; a grey reports h = 0.
function hsvToRgb(h, s, v) {
    var hue = Number(h)
    if (!isFinite(hue)) hue = 0
    hue = ((hue % 1) + 1) % 1
    s = clamp01(s)
    v = clamp01(v)
    var i = Math.floor(hue * 6)
    var f = hue * 6 - i
    var p = v * (1 - s)
    var q = v * (1 - f * s)
    var t = v * (1 - (1 - f) * s)
    var r, g, b
    switch (i % 6) {
    case 0: r = v; g = t; b = p; break
    case 1: r = q; g = v; b = p; break
    case 2: r = p; g = v; b = t; break
    case 3: r = p; g = q; b = v; break
    case 4: r = t; g = p; b = v; break
    default: r = v; g = p; b = q; break
    }
    return { r: r, g: g, b: b, a: 1 }
}

function rgbToHsv(r, g, b) {
    r = clamp01(r)
    g = clamp01(g)
    b = clamp01(b)
    var max = Math.max(r, g, b), min = Math.min(r, g, b)
    var d = max - min
    var h = 0
    var s = max === 0 ? 0 : d / max
    if (d > 0) {
        if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6
        else if (max === g) h = ((b - r) / d + 2) / 6
        else h = ((r - g) / d + 4) / 6
    }
    return { h: h, s: s, v: max }
}

// Integer channel for the RGB/HSV fields. `max` is 255, 360 or 100.
function parseChannel(text, max) {
    var raw = String(text === null || text === undefined ? "" : text).trim()
    if (raw === "" || !/^\d+$/.test(raw)) return { ok: false, value: 0 }
    var n = parseInt(raw, 10)
    var ceiling = Number(max)
    if (!isFinite(n) || !isFinite(ceiling) || n < 0 || n > ceiling)
        return { ok: false, value: n }
    return { ok: true, value: n }
}

function channelUnit(value, max) {
    var ceiling = Number(max)
    if (!isFinite(ceiling) || ceiling <= 0) return 0
    return clamp01(Number(value) / ceiling)
}

// Draft insert used by current-content paste into a focused colour field.
// Operates on a TextInput-shaped object so the host suite can drive it.
function fieldInsert(field, text) {
    if (!field || !text) return
    var start = field.selectionStart, end = field.selectionEnd
    if (start >= 0 && end > start) field.remove(start, end)
    var room = field.maximumLength > 0 ? field.maximumLength - field.length : -1
    if (room === 0) return
    if (room > 0 && text.length > room) text = text.slice(0, room)
    field.insert(field.cursorPosition, text)
}

function fieldSelectAll(field) {
    if (field && field.selectAll) field.selectAll()
}

function serializeState(state) {
    return JSON.stringify({
        center: state.center
            ? { x: state.center.x, y: state.center.y }
            : null,
        emoji_usage: state.emojiUsage || [],
        emoji_skin_tone: EMOJI_SKIN_TONES.indexOf(state.emojiSkinTone) >= 0
            ? state.emojiSkinTone : "",
        layout_group: typeof state.layoutGroup === "number"
            && state.layoutGroup >= 0 && state.layoutGroup <= 3
            ? Math.floor(state.layoutGroup) : 0,
        layout_device: typeof state.layoutDevice === "string"
            ? state.layoutDevice : ""
    }, null, 2) + "\n"
}
