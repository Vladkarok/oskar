.pragma library

// The one configuration file: $XDG_CONFIG_HOME/omarchy-osk/config.json. It is
// both the documented user config and the persisted state, because two files
// that can disagree is a bug class this project has already met. The keys and
// their defaults are spec-v1 §10:
//
//   mode          "docked" | "floating"          default "docked"
//   position      {x, y}, floating mode only     default unset (null)
//   size_preset   preset name                    default "medium"
//   sound         true | false                   default false
//   follow_theme  true | false                   default true
//
// Nothing else in v1; every key is one to support forever once the repo is
// public. Unknown keys are still carried through the round trip rather than
// eaten by the next write — a hand-edited file should not lose what v1 does
// not know about.
//
// A missing file, a malformed file, or a key with a missing or malformed
// value all fall back to the defaults rather than failing to start: config
// problems must never take the keyboard down. The fallback is per key, so
// one typo cannot discard the other four settings.

var MODE_DOCKED = "docked"
var MODE_FLOATING = "floating"

// The five names as they appear in the JSON file. Also the round-trip
// allowlist: anything outside this list is preserved verbatim as extra.
var KNOWN_KEYS = ["mode", "position", "size_preset", "sound", "follow_theme"]

function defaults() {
    return {
        mode: MODE_DOCKED,
        position: null,
        sizePreset: "medium",
        sound: false,
        followTheme: true,
        extra: {}
    }
}

// {x, y} with finite numbers, or null. JSON has no NaN literal but a number
// literal can still overflow to Infinity ("1e999"), which would poison every
// arithmetic the position later feeds into — finite means finite.
function parsePosition(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    if (typeof value.x !== "number" || typeof value.y !== "number") return null
    if (!isFinite(value.x) || !isFinite(value.y)) return null
    return { x: value.x, y: value.y }
}

function collectExtra(raw) {
    var extra = {}
    for (var key in raw) {
        if (KNOWN_KEYS.indexOf(key) === -1) extra[key] = raw[key]
    }
    return extra
}

// Text in, a validated config out. Never throws, never returns anything but
// a full config object.
function parse(text) {
    var config = defaults()
    if (!text || !String(text).trim()) return config
    var raw
    try {
        raw = JSON.parse(text)
    } catch (error) {
        return config
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return config

    if (raw.mode === MODE_DOCKED || raw.mode === MODE_FLOATING) {
        config.mode = raw.mode
    }
    config.position = parsePosition(raw.position)
    if (typeof raw.size_preset === "string" && raw.size_preset.length > 0) {
        config.sizePreset = raw.size_preset
    }
    if (typeof raw.sound === "boolean") {
        config.sound = raw.sound
    }
    if (typeof raw.follow_theme === "boolean") {
        config.followTheme = raw.follow_theme
    }
    config.extra = collectExtra(raw)
    return config
}

// A config object back to file text. The documented keys are written
// explicitly and win over same-named extras; `position` is written as an
// explicit null while unset so the file always shows all five documented
// keys, floating state included.
function serialize(config) {
    var out = {}
    var extra = config.extra || {}
    for (var key in extra) out[key] = extra[key]
    out.mode = config.mode
    out.position = config.position ? { x: config.position.x, y: config.position.y } : null
    out.size_preset = config.sizePreset
    out.sound = config.sound
    out.follow_theme = config.followTheme
    return JSON.stringify(out, null, 2) + "\n"
}
