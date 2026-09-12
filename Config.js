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

var CONFIG_FIELDS = [
    { file: "mode", value: "mode" },
    { file: "size_preset", value: "sizePreset" },
    { file: "sound", value: "sound" },
    { file: "follow_theme", value: "followTheme" },
    { file: "emoji_app", value: "emojiApp" },
    { file: "key_radius", value: "keyRadius" },
    { file: "panel_radius", value: "panelRadius" },
    { file: "key_background", value: "keyBackground" },
    { file: "panel_background", value: "panelBackground" },
    { file: "text_color", value: "textColor" },
    { file: "accent_color", value: "accentColor" },
    { file: "border_color", value: "borderColor" }
]

var APPEARANCE_FIELDS = ["keyRadius", "panelRadius", "keyBackground",
    "panelBackground", "textColor", "accentColor", "borderColor"]

function maintainerDefaults() {
    return {
        mode: MODE_DOCKED,
        sizePreset: "medium",
        sound: false,
        followTheme: true,
        // What Omarchy 4.0.2 itself ships as its emoji picker: its
        // omarchy-menu-emoji launcher toggles the shell's own emoji overlay
        // (verified against /usr/share/omarchy/bin on 2026-09-05; the
        // pre-v1.1 plugin called the same script). The popover's Emoji app
        // row offers every picker found on PATH; this default stands until
        // one is chosen.
        emojiApp: "omarchy-menu-emoji",
        keyRadius: 8,
        panelRadius: 12,
        keyBackground: "#303030",
        panelBackground: "#202020",
        textColor: "#f5f5f5",
        accentColor: "#7aa2f7",
        borderColor: "#5a5a5a"
    }
}

function stateDefaults() {
    return { center: null }
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
    if (field.file === "sound" || field.file === "follow_theme")
        return typeof value === "boolean"
    // The emoji picker is a bare PATH name the panel execs — never a path,
    // never arguments. Empty (or padding-only) is not a name.
    if (field.file === "emoji_app")
        return typeof value === "string" && value.trim() !== ""
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
        // the §5 preservation semantics, so `{"key_radius":8,"keyRadius":-20}`
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
        // serialization. The emoji app name trims for the same reason — a
        // padded name is still that name.
        if (isColor(value) || field.file === "emoji_app") value = value.trim()
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
    if (!owns(parsed.value, "center")) return { value: state, error: "" }
    var center = parsePoint(parsed.value.center)
    if (center === undefined)
        return { value: null, error: "Invalid value for center" }
    state.center = center
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
    if (typeof color.a === "number" && color.a < 1) out += colorByte(color.a)
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

function serializeState(state) {
    return JSON.stringify({
        center: state.center
            ? { x: state.center.x, y: state.center.y }
            : null
    }, null, 2) + "\n"
}
