.pragma library

// One authority for the three configuration roles in spec-v1.1 §5:
// complete shipped defaults, sparse user overrides, and geometry/state.
// Filesystem watching and atomic replacement belong to the FileViews in
// Panel.qml; all interpretation and serialization stays here.

var MODE_DOCKED = "docked"
var MODE_FLOATING = "floating"

var CONFIG_FIELDS = [
    { file: "mode", value: "mode" },
    { file: "size_preset", value: "sizePreset" },
    { file: "sound", value: "sound" },
    { file: "follow_theme", value: "followTheme" },
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
    return { position: null }
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
    if (!text || !String(text).trim()) return { value: {}, error: "" }
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

function isRadius(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
}

function isColor(value) {
    return typeof value === "string" && value.trim().length > 0
}

function configField(fileName) {
    for (var i = 0; i < CONFIG_FIELDS.length; i++) {
        if (CONFIG_FIELDS[i].file === fileName) return CONFIG_FIELDS[i]
    }
    return null
}

function validOverride(key, value) {
    if (key === "mode") return value === MODE_DOCKED || value === MODE_FLOATING
    if (key === "size_preset")
        return value === "medium" || value === "large" || value === "x-large"
    if (key === "sound" || key === "follow_theme") return typeof value === "boolean"
    if (key === "key_radius" || key === "panel_radius") return isRadius(value)
    if (key === "key_background" || key === "panel_background"
        || key === "text_color" || key === "accent_color" || key === "border_color")
        return isColor(value)
    return true
}

function parseOverrides(text) {
    var parsed = parseObject(text, "configuration")
    if (parsed.error) return parsed
    var overrides = {}
    for (var key in parsed.value) {
        if (!owns(parsed.value, key)) continue
        if (!validOverride(key, parsed.value[key]))
            return { value: null, error: "Invalid value for " + key }
        var field = configField(key)
        overrides[field ? field.value : key] = parsed.value[key]
    }
    return { value: overrides, error: "" }
}

function parsePosition(value) {
    if (value === null) return null
    if (!value || typeof value !== "object" || Array.isArray(value)) return undefined
    if (typeof value.x !== "number" || typeof value.y !== "number") return undefined
    if (!isFinite(value.x) || !isFinite(value.y)) return undefined
    return { x: value.x, y: value.y }
}

function parseState(text) {
    var parsed = parseObject(text, "state")
    if (parsed.error) return parsed
    var state = stateDefaults()
    if (!owns(parsed.value, "position")) return { value: state, error: "" }
    var position = parsePosition(parsed.value.position)
    if (position === undefined)
        return { value: null, error: "Invalid value for position" }
    state.position = position
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

function serializeOverrides(overrides) {
    var out = {}
    for (var key in overrides) {
        if (!owns(overrides, key)) continue
        var fileName = key
        for (var i = 0; i < CONFIG_FIELDS.length; i++) {
            if (CONFIG_FIELDS[i].value === key) {
                fileName = CONFIG_FIELDS[i].file
                break
            }
        }
        out[fileName] = overrides[key]
    }
    return JSON.stringify(out, null, 2) + "\n"
}

function serializeState(state) {
    return JSON.stringify({
        position: state.position
            ? { x: state.position.x, y: state.position.y }
            : null
    }, null, 2) + "\n"
}
