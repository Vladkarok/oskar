.pragma library

// Each key: { t: base char, s: shifted char } for typed keys,
// or { label, key: keysym/modifier-name, w: width factor } for special keys.
//
// A third shape belongs to the symbols page: { k: position, lvl: 1 | 2 } draws
// exactly one level of one position and types that level, rather than the
// base/shift pair a main-page cap carries. It has no built-in character at
// all, because a fixed ASCII table is the lie this project exists to avoid —
// an unresolved level draws blank and is reported like any other fallback.
var functionRow = [
    { label: "esc", key: "Escape", w: 1.25 },
    { label: "F1", key: "F1" }, { label: "F2", key: "F2" }, { label: "F3", key: "F3" },
    { label: "F4", key: "F4" }, { label: "F5", key: "F5" }, { label: "F6", key: "F6" },
    { label: "F7", key: "F7" }, { label: "F8", key: "F8" }, { label: "F9", key: "F9" },
    { label: "F10", key: "F10" }, { label: "F11", key: "F11" }, { label: "F12", key: "F12" },
    { label: "Delete", key: "Delete", w: 1.25 }
]

// The row both pages end on, identical but for the page key's own label. It is
// the row the pointer returns to most, so it is the one that must not move
// between pages: same caps, same widths, same place (see the height pin in
// Keyboard.qml).
function commandRow(pageLabel) {
    return [
        { label: "Ctrl", key: "ctrl", w: 1.25 },
        { label: "Super", key: "logo", w: 1.25 },
        { label: "Alt", key: "alt", w: 1.25 },
        { label: "", key: "emoji", w: 1.25 },
        // The page switch (spec-v1 §4). A key, never a modifier: it changes
        // what can be seen and nothing about what is held, and the label names
        // where the next press goes rather than where you are.
        { label: pageLabel, key: "page", w: 1.25 },
        { t: " ", label: "", w: 4.25, k: "SPCE" },
        { label: "AltGr", key: "altgr", w: 1.25 },
        { label: "Super", key: "logo", w: 1.25 },
        { label: "Ctrl", key: "ctrl", w: 1.25 },
        // The four arrows sit together at the end of the row and are ordinary
        // full-height caps, not a nested cluster of half-height ones. Arrows
        // are the keys clicked most times in a row, so each one has to be a
        // target the pointer can hit five times without re-aiming; the stacked
        // up/down pair this replaces was a little under half the height of
        // every other key on the panel. Being ordinary caps also puts them on
        // the delegate's `onPressed` path rather than their own `onClicked`
        // MouseAreas, so they act on the way down like everything else.
        { label: "◀", key: "Left" },
        { label: "▲", key: "Up" },
        { label: "▼", key: "Down" },
        { label: "▶", key: "Right" }
    ]
}

var rows = [
    functionRow,
    [
        { t: "`", s: "~", k: "TLDE" }, { t: "1", s: "!", k: "AE01" }, { t: "2", s: "@", k: "AE02" }, { t: "3", s: "#", k: "AE03" },
        { t: "4", s: "$", k: "AE04" }, { t: "5", s: "%", k: "AE05" }, { t: "6", s: "^", k: "AE06" }, { t: "7", s: "&", k: "AE07" },
        { t: "8", s: "*", k: "AE08" }, { t: "9", s: "(", k: "AE09" }, { t: "0", s: ")", k: "AE10" }, { t: "-", s: "_", k: "AE11" },
        { t: "=", s: "+", k: "AE12" }, { label: "Backspace", key: "BackSpace", w: 1.5 }
    ],
    [
        { label: "Tab", key: "Tab", w: 1.4 },
        { t: "q", s: "Q", k: "AD01" }, { t: "w", s: "W", k: "AD02" }, { t: "e", s: "E", k: "AD03" }, { t: "r", s: "R", k: "AD04" },
        { t: "t", s: "T", k: "AD05" }, { t: "y", s: "Y", k: "AD06" }, { t: "u", s: "U", k: "AD07" }, { t: "i", s: "I", k: "AD08" },
        { t: "o", s: "O", k: "AD09" }, { t: "p", s: "P", k: "AD10" }, { t: "[", s: "{", k: "AD11" }, { t: "]", s: "}", k: "AD12" },
        { t: "\\", s: "|", k: "BKSL" }
    ],
    [
        { label: "Caps Lock", key: "caps", w: 1.75 },
        { t: "a", s: "A", k: "AC01" }, { t: "s", s: "S", k: "AC02" }, { t: "d", s: "D", k: "AC03" }, { t: "f", s: "F", k: "AC04" },
        { t: "g", s: "G", k: "AC05" }, { t: "h", s: "H", k: "AC06" }, { t: "j", s: "J", k: "AC07" }, { t: "k", s: "K", k: "AC08" },
        { t: "l", s: "L", k: "AC09" }, { t: ";", s: ":", k: "AC10" }, { t: "'", s: "\"", k: "AC11" },
        { label: "Enter", key: "Return", w: 1.75 }
    ],
    [
        { label: "Shift", key: "shift", w: 2.2 },
        { t: "z", s: "Z", k: "AB01" }, { t: "x", s: "X", k: "AB02" }, { t: "c", s: "C", k: "AB03" }, { t: "v", s: "V", k: "AB04" },
        { t: "b", s: "B", k: "AB05" }, { t: "n", s: "N", k: "AB06" }, { t: "m", s: "M", k: "AB07" }, { t: ",", s: "<", k: "AB08" },
        { t: ".", s: ">", k: "AB09" }, { t: "/", s: "?", k: "AB10" },
        { label: "Shift", key: "shift", w: 2.2 }
    ],
    commandRow("&123")
]

// The symbols page (spec-v1 §4). What it holds is a rule rather than a list:
// the shift level of every non-letter position on the main page — which is
// exactly what the alphanumeric block cannot reach in one press — plus the
// base level of the punctuation cluster, which is one press on the main page
// but a page switch out and back once you are here.
//
// Which characters those positions carry is the keymap's business, not ours.
// On `us` the top row reads ~!@#$%^&*()_+; on a layout whose symbols sit
// elsewhere it reads whatever that layout puts there, and a position with
// nothing at that level draws blank and says so in the log rather than
// borrowing a US character.
//
// The nav caps fill out the rows the symbol positions do not reach across.
// They are fixed-label caps like the arrows, and they are the other thing a
// pointer cannot otherwise get at.
var punctuationPositions = ["AD11", "AD12", "BKSL", "AC10", "AC11", "AB08", "AB09", "AB10"]

function levelCaps(positions, level) {
    var out = []
    for (var i = 0; i < positions.length; i++) {
        out.push({ k: positions[i], lvl: level })
    }
    return out
}

var symbolRows = [
    functionRow,
    levelCaps(["TLDE", "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07",
               "AE08", "AE09", "AE10", "AE11", "AE12"], 2)
        .concat([{ label: "Backspace", key: "BackSpace", w: 1.5 }]),
    [{ label: "Tab", key: "Tab", w: 1.4 }]
        .concat(levelCaps(punctuationPositions, 1))
        .concat([
            { label: "Home", key: "Home" },
            { label: "End", key: "End" },
            { label: "Ins", key: "Insert" }
        ]),
    // Shift is on this row because it is the one modifier the main page keeps
    // outside the command row, and a locked modifier has to stay *indicated* as
    // locked across a page switch, not merely stay held (spec-v1 §5).
    [{ label: "Shift", key: "shift", w: 2.2 }]
        .concat(levelCaps(punctuationPositions, 2))
        .concat([
            { label: "PgUp", key: "Prior" },
            { label: "PgDn", key: "Next" },
            { label: "Enter", key: "Return", w: 1.75 }
        ]),
    commandRow("ABC")
]


var tokenCharMap = {
    space: " ",
    grave: "`",
    asciitilde: "~",
    exclam: "!",
    at: "@",
    numbersign: "#",
    dollar: "$",
    percent: "%",
    asciicircum: "^",
    ampersand: "&",
    asterisk: "*",
    parenleft: "(",
    parenright: ")",
    minus: "-",
    underscore: "_",
    equal: "=",
    plus: "+",
    bracketleft: "[",
    braceleft: "{",
    bracketright: "]",
    braceright: "}",
    backslash: "\\",
    bar: "|",
    semicolon: ";",
    colon: ":",
    apostrophe: "'",
    quotedbl: "\"",
    comma: ",",
    less: "<",
    period: ".",
    greater: ">",
    slash: "/",
    question: "?",
    guillemotleft: "\u00ab",
    guillemotright: "\u00bb",
    ccedilla: "\u00e7",
    Ccedilla: "\u00c7",
    ntilde: "\u00f1",
    Ntilde: "\u00d1",
    adiaeresis: "\u00e4",
    Adiaeresis: "\u00c4",
    odiaeresis: "\u00f6",
    Odiaeresis: "\u00d6",
    udiaeresis: "\u00fc",
    Udiaeresis: "\u00dc",
    eacute: "\u00e9",
    Eacute: "\u00c9",
    aacute: "\u00e1",
    Aacute: "\u00c1",
    iacute: "\u00ed",
    Iacute: "\u00cd",
    oacute: "\u00f3",
    Oacute: "\u00d3",
    uacute: "\u00fa",
    Uacute: "\u00da",
    ssharp: "\u00df",
    section: "\u00a7",
    degree: "\u00b0",
    idotless: "\u0131",
    numerosign: "\u2116",
    endash: "\u2013",
    emdash: "\u2014",
    doublelowquotemark: "\u201e",
    leftdoublequotemark: "\u201c",
    rightdoublequotemark: "\u201d",
    brokenbar: "\u00a6",
    currency: "\u00a4",
    EuroSign: "\u20ac"
}

// X11 Cyrillic keysym names -> characters. Cyrillic layouts (ua, ru, bg,
// by, rs, mk) spell their symbols as named keysyms rather than U#### escapes,
// so without this every key falls back to its Latin label.
var cyrillicCharMap = {
    Cyrillic_IO: "\u0401",
    Serbian_DJE: "\u0402",
    Macedonia_GJE: "\u0403",
    Ukrainian_IE: "\u0404",
    Macedonia_DSE: "\u0405",
    Ukrainian_I: "\u0406",
    Ukrainian_YI: "\u0407",
    Cyrillic_JE: "\u0408",
    Cyrillic_LJE: "\u0409",
    Cyrillic_NJE: "\u040a",
    Serbian_TSHE: "\u040b",
    Macedonia_KJE: "\u040c",
    Byelorussian_SHORTU: "\u040e",
    Cyrillic_DZHE: "\u040f",
    Cyrillic_A: "\u0410",
    Cyrillic_BE: "\u0411",
    Cyrillic_VE: "\u0412",
    Cyrillic_GHE: "\u0413",
    Cyrillic_DE: "\u0414",
    Cyrillic_IE: "\u0415",
    Cyrillic_ZHE: "\u0416",
    Cyrillic_ZE: "\u0417",
    Cyrillic_I: "\u0418",
    Cyrillic_SHORTI: "\u0419",
    Cyrillic_KA: "\u041a",
    Cyrillic_EL: "\u041b",
    Cyrillic_EM: "\u041c",
    Cyrillic_EN: "\u041d",
    Cyrillic_O: "\u041e",
    Cyrillic_PE: "\u041f",
    Cyrillic_ER: "\u0420",
    Cyrillic_ES: "\u0421",
    Cyrillic_TE: "\u0422",
    Cyrillic_U: "\u0423",
    Cyrillic_EF: "\u0424",
    Cyrillic_HA: "\u0425",
    Cyrillic_TSE: "\u0426",
    Cyrillic_CHE: "\u0427",
    Cyrillic_SHA: "\u0428",
    Cyrillic_SHCHA: "\u0429",
    Cyrillic_HARDSIGN: "\u042a",
    Cyrillic_YERU: "\u042b",
    Cyrillic_SOFTSIGN: "\u042c",
    Cyrillic_E: "\u042d",
    Cyrillic_YU: "\u042e",
    Cyrillic_YA: "\u042f",
    Cyrillic_a: "\u0430",
    Cyrillic_be: "\u0431",
    Cyrillic_ve: "\u0432",
    Cyrillic_ghe: "\u0433",
    Cyrillic_de: "\u0434",
    Cyrillic_ie: "\u0435",
    Cyrillic_zhe: "\u0436",
    Cyrillic_ze: "\u0437",
    Cyrillic_i: "\u0438",
    Cyrillic_shorti: "\u0439",
    Cyrillic_ka: "\u043a",
    Cyrillic_el: "\u043b",
    Cyrillic_em: "\u043c",
    Cyrillic_en: "\u043d",
    Cyrillic_o: "\u043e",
    Cyrillic_pe: "\u043f",
    Cyrillic_er: "\u0440",
    Cyrillic_es: "\u0441",
    Cyrillic_te: "\u0442",
    Cyrillic_u: "\u0443",
    Cyrillic_ef: "\u0444",
    Cyrillic_ha: "\u0445",
    Cyrillic_tse: "\u0446",
    Cyrillic_che: "\u0447",
    Cyrillic_sha: "\u0448",
    Cyrillic_shcha: "\u0449",
    Cyrillic_hardsign: "\u044a",
    Cyrillic_yeru: "\u044b",
    Cyrillic_softsign: "\u044c",
    Cyrillic_e: "\u044d",
    Cyrillic_yu: "\u044e",
    Cyrillic_ya: "\u044f",
    Cyrillic_io: "\u0451",
    Serbian_dje: "\u0452",
    Macedonia_gje: "\u0453",
    Ukrainian_ie: "\u0454",
    Macedonia_dse: "\u0455",
    Ukrainian_i: "\u0456",
    Ukrainian_yi: "\u0457",
    Cyrillic_je: "\u0458",
    Cyrillic_lje: "\u0459",
    Cyrillic_nje: "\u045a",
    Serbian_tshe: "\u045b",
    Macedonia_kje: "\u045c",
    Byelorussian_shortu: "\u045e",
    Cyrillic_dzhe: "\u045f",
    Ukrainian_GHE_WITH_UPTURN: "\u0490",
    Ukrainian_ghe_with_upturn: "\u0491",
    Cyrillic_GHE_bar: "\u0492",
    Cyrillic_ghe_bar: "\u0493",
    Cyrillic_ZHE_descender: "\u0496",
    Cyrillic_zhe_descender: "\u0497",
    Cyrillic_KA_descender: "\u049a",
    Cyrillic_ka_descender: "\u049b",
    Cyrillic_KA_vertstroke: "\u049c",
    Cyrillic_ka_vertstroke: "\u049d",
    Cyrillic_EN_descender: "\u04a2",
    Cyrillic_en_descender: "\u04a3",
    Cyrillic_U_straight: "\u04ae",
    Cyrillic_u_straight: "\u04af",
    Cyrillic_U_straight_bar: "\u04b0",
    Cyrillic_u_straight_bar: "\u04b1",
    Cyrillic_HA_descender: "\u04b2",
    Cyrillic_ha_descender: "\u04b3",
    Cyrillic_CHE_descender: "\u04b6",
    Cyrillic_che_descender: "\u04b7",
    Cyrillic_CHE_vertstroke: "\u04b8",
    Cyrillic_che_vertstroke: "\u04b9",
    Cyrillic_SHHA: "\u04ba",
    Cyrillic_shha: "\u04bb",
    Cyrillic_SCHWA: "\u04d8",
    Cyrillic_schwa: "\u04d9",
    Cyrillic_I_macron: "\u04e2",
    Cyrillic_i_macron: "\u04e3",
    Cyrillic_O_bar: "\u04e8",
    Cyrillic_o_bar: "\u04e9",
    Cyrillic_U_macron: "\u04ee",
    Cyrillic_u_macron: "\u04ef"
}

function cloneKey(keyData) {
    var out = {}
    for (var field in keyData) {
        out[field] = keyData[field]
    }
    return out
}

function cloneRows(sourceRows) {
    var out = []
    for (var r = 0; r < sourceRows.length; r++) {
        var row = sourceRows[r]
        var clonedRow = []
        for (var c = 0; c < row.length; c++) {
            clonedRow.push(cloneKey(row[c]))
        }
        out.push(clonedRow)
    }
    return out
}

function tokenToText(token, fallback) {
    var normalized = String(token || "").trim()
    if (normalized === "") return fallback
    if (tokenCharMap.hasOwnProperty(normalized)) return tokenCharMap[normalized]
    if (cyrillicCharMap.hasOwnProperty(normalized)) return cyrillicCharMap[normalized]
    if (/^U[0-9A-Fa-f]{4,6}$/.test(normalized)) {
        return String.fromCodePoint(parseInt(normalized.slice(1), 16))
    }
    // 0x0100XXXX is the X11 "Unicode keysym" form (0x01000000 + codepoint),
    // used by ru and others. Passing it to fromCodePoint raw would throw.
    if (/^0x0100[0-9A-Fa-f]{4}$/.test(normalized)) {
        return String.fromCodePoint(parseInt(normalized.slice(6), 16))
    }
    if (/^0x[0-9A-Fa-f]{2,6}$/.test(normalized)) {
        return String.fromCodePoint(parseInt(normalized, 16))
    }
    if (normalized.length === 1) return normalized
    if (/^[A-Za-z0-9]$/.test(normalized)) return normalized
    return fallback
}

// A cap that draws a fixed label — Esc, Enter, the arrows, and Space, whose
// label is deliberately empty — shows the same thing on every layout and has
// no keymap symbol to miss. Only the caps that are supposed to come out of the
// compiled keymap can fall back to a built-in value, and only those are worth
// reporting.
function drawsFixedLabel(keyData) {
    return keyData.hasOwnProperty("label")
}

// A missing token is a marker, not a character: `tokenToText` is asked for it
// so that a keymap that really does resolve to an empty string cannot be
// mistaken for a failure.
var UNRESOLVED = " unresolved"

function applyLanguage(rowsSource, layoutCode, symbolMap) {
    var layoutRows = cloneRows(rowsSource)
    var label = String(layoutCode || "us").toUpperCase()
    var fallbacks = []

    for (var r = 0; r < layoutRows.length; r++) {
        for (var c = 0; c < layoutRows[r].length; c++) {
            var keyData = layoutRows[r][c]
            if (keyData.key === "lang") {
                keyData.label = label
                continue
            }
            if (!keyData.k) continue

            var symbols = symbolMap ? symbolMap[keyData.k] : null
            var haveSymbols = Array.isArray(symbols) && symbols.length > 0

            // A symbols-page cap draws exactly one level and carries no
            // built-in character, so there is nothing to fall back *to*: an
            // unresolved level leaves the cap blank and is reported, which is
            // the §11 rule with the silent substitution removed entirely.
            if (keyData.lvl) {
                var index = keyData.lvl - 1
                var token = haveSymbols && index < symbols.length ? symbols[index] : ""
                var resolved = tokenToText(token, UNRESOLVED)
                if (resolved === UNRESOLVED) {
                    keyData.t = ""
                    fallbacks.push(keyData.k + (index > 0 ? "^" : "") + "="
                        + (haveSymbols ? (String(token).trim() || "<no symbol at this level>")
                                       : "<no keymap entry>"))
                } else {
                    keyData.t = resolved
                }
                // A latched or locked Shift applies to every press, including
                // one on a base-level cap, so a base-level cap has to be able
                // to show what Shift would actually produce — otherwise the
                // page would draw `[` while typing `{`, which is the one thing
                // this keyboard is for. It still draws as a single glyph (see
                // isDualKey): the stacked pair belongs to the main page, and
                // the shift level has a cap of its own here.
                if (index === 0) {
                    var paired = tokenToText(haveSymbols && symbols.length > 1 ? symbols[1] : "", UNRESOLVED)
                    if (paired !== UNRESOLVED) keyData.s = paired
                }
                continue
            }

            if (!haveSymbols) {
                if (!drawsFixedLabel(keyData)) fallbacks.push(keyData.k + "=<no keymap entry>")
                continue
            }

            var base = tokenToText(symbols[0], UNRESOLVED)
            if (base === UNRESOLVED) {
                if (!drawsFixedLabel(keyData)) fallbacks.push(keyData.k + "=" + symbols[0])
            } else {
                keyData.t = base
            }

            if (symbols.length > 1 && String(symbols[1] || "").trim() !== "") {
                var shifted = tokenToText(symbols[1], UNRESOLVED)
                if (shifted === UNRESOLVED) {
                    if (!drawsFixedLabel(keyData)) fallbacks.push(keyData.k + "^=" + symbols[1])
                } else {
                    keyData.s = shifted
                }
            }
        }
    }

    // A silent substitution is the failure mode decisions.md §11 records: the
    // awk program broke, the map came back empty, and the built-in US table
    // stayed on screen for days while the label said "Ukrainian". One line per
    // rebuild rather than one per key, so a wholly empty map is loud without
    // being sixty lines of noise.
    if (fallbacks.length > 0) {
        var shown = fallbacks.slice(0, 12).join(" ")
        if (fallbacks.length > 12) shown += " … and " + (fallbacks.length - 12) + " more"
        console.error("[osk] keycap fallback to built-in table for " + layoutCode
            + ": " + fallbacks.length + " cap(s): " + shown)
    }

    return layoutRows
}

// The rows label special keys by keysym ("Return", "BackSpace"). The daemon
// speaks key positions instead, so the compositor decides what a position
// means — which is what lets one keystroke work on any layout and reach
// XWayland clients. This maps the keysyms already present in the layout table
// onto xkb positions.
var keysymPositions = {
    Escape: "ESC",
    Tab: "TAB",
    Return: "RTRN",
    BackSpace: "BKSP",
    Delete: "DELE",
    Left: "LEFT",
    Right: "RGHT",
    Up: "UP",
    Down: "DOWN",
    Home: "HOME",
    End: "END",
    Prior: "PGUP",
    Next: "PGDN",
    Insert: "INS"
}

// Modifier positions are not here: they belong to ModifierReducer.js, which
// is the only thing that presses one, and a second table of them is a second
// thing to keep in step.

function positionForKeysym(keysym) {
    var name = String(keysym || "")
    if (keysymPositions.hasOwnProperty(name)) return keysymPositions[name]
    // F1..F12 sit at FK01..FK12.
    var fkey = /^F([1-9]|1[0-2])$/.exec(name)
    if (fkey) {
        var index = fkey[1]
        return "FK" + (index.length < 2 ? "0" + index : index)
    }
    return ""
}
