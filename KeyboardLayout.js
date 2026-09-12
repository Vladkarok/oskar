.pragma library

// Each key: { t: base char, s: shifted char } for typed keys,
// or { label, key: keysym/modifier-name, w: width units } for special keys.
// Keys without w are one unit wide, every width is a multiple of 0.5, and
// every row's widths sum to 15.5 exactly: the panel lays all rows out on one
// shared cell pitch (Keyboard.qml) and loudly reports any row that misses
// it, because under a shared pitch a short row stops short of the card edge
// instead of merely shrinking. The widths sit on a half-unit lattice in the
// owner-measured Windows stagger; what that buys is the grid comment in
// Keyboard.qml, and this is not the place to say it twice.
//
// A third shape belongs to the symbols page: { k: position, lvl: 1 | 2 } draws
// exactly one level of one position and types that level, rather than the
// base/shift pair a main-page cap carries. It has no built-in character at
// all, because a fixed ASCII table is the lie this project exists to avoid —
// an unresolved level draws blank and is reported like any other fallback.
var functionRow = [
    { label: "esc", key: "Escape", w: 1.0 },
    { t: "`", s: "~", k: "TLDE" },
    { label: "F1", key: "F1" }, { label: "F2", key: "F2" }, { label: "F3", key: "F3" },
    { label: "F4", key: "F4" }, { label: "F5", key: "F5" }, { label: "F6", key: "F6" },
    { label: "F7", key: "F7" }, { label: "F8", key: "F8" }, { label: "F9", key: "F9" },
    { label: "F10", key: "F10" }, { label: "F11", key: "F11" }, { label: "F12", key: "F12" },
    { label: "⌫", key: "BackSpace", w: 1.5 }
]

// The row both pages end on, identical but for the page key's own label. It is
// the row the pointer returns to most, so it is the one that must not move
// between pages: same caps, same widths, same place (see the height pin in
// Keyboard.qml) — the page key included, which has sat in the bottom-right
// slot since owner round 6.
function commandRow(pageLabel) {
    return [
        { label: "Ctrl", key: "ctrl" },
        // Fn is a panel display control: it swaps the top row in place and
        // never emits a key position or participates in modifier latching.
        { label: "Fn", key: "fn" },
        { label: "Super", key: "logo" },
        { label: "Alt", key: "alt" },
        { label: "", key: "emoji" },
        { t: " ", label: "", w: 4.5, k: "SPCE" },
        { label: "AltGr", key: "altgr" },
        { label: "Ctrl", key: "ctrl" },
        { label: "←", key: "Left" },
        { label: "↓", key: "Down" },
        { label: "→", key: "Right" },
        // The page switch (spec-v1 §4). A key, never a modifier: it changes
        // what can be seen and nothing about what is held, and the label names
        // where the next press goes rather than where you are. It holds the
        // bottom-right corner — Windows' ENG slot — since owner round 6.
        { label: pageLabel, key: "page" }
    ]
}

// Half-unit lattice with the classic stagger (owner round 6, laid out like
// the measured Windows reference): every width is a multiple of 0.5 and
// adjacent rows' gap lines are offset by exactly half a unit, so every gap
// falls mid-key of the neighbouring rows — rows 1 and 3 land their
// boundaries on whole units, rows 2 and 4 on half units, and the command
// row is whole across its left block and half across its right block.
// Consequences: Caps Lock spans exactly Ctrl+Fn, ↑ sits exactly above ↓
// (12.5 units left of each — see the fourth row), Enter's left edge
// (2 + 11 = 13.0) lands exactly at ↑/↓'s middle, and the 2-unit right Shift
// here, like symbols Enter on the other page, spans exactly → plus the page
// key.
var rows = [
    [
        { label: "esc", key: "Escape", w: 1.0 },
        { t: "`", s: "~", k: "TLDE" }, { t: "1", s: "!", k: "AE01" }, { t: "2", s: "@", k: "AE02" }, { t: "3", s: "#", k: "AE03" },
        { t: "4", s: "$", k: "AE04" }, { t: "5", s: "%", k: "AE05" }, { t: "6", s: "^", k: "AE06" }, { t: "7", s: "&", k: "AE07" },
        { t: "8", s: "*", k: "AE08" }, { t: "9", s: "(", k: "AE09" }, { t: "0", s: ")", k: "AE10" }, { t: "-", s: "_", k: "AE11" },
        { t: "=", s: "+", k: "AE12" }, { label: "⌫", key: "BackSpace", w: 1.5 }
    ],
    [
        { label: "Tab", key: "Tab", w: 1.5 },
        { t: "q", s: "Q", k: "AD01" }, { t: "w", s: "W", k: "AD02" }, { t: "e", s: "E", k: "AD03" }, { t: "r", s: "R", k: "AD04" },
        { t: "t", s: "T", k: "AD05" }, { t: "y", s: "Y", k: "AD06" }, { t: "u", s: "U", k: "AD07" }, { t: "i", s: "I", k: "AD08" },
        { t: "o", s: "O", k: "AD09" }, { t: "p", s: "P", k: "AD10" }, { t: "[", s: "{", k: "AD11" }, { t: "]", s: "}", k: "AD12" },
        { t: "\\", s: "|", k: "BKSL" },
        // Windows' reference ends this row in Del; the keysym mapping and the
        // symbols-page cap below already existed.
        { label: "Del", key: "Delete" }
    ],
    [
        { label: "Caps Lock", key: "caps", w: 2.0 },
        { t: "a", s: "A", k: "AC01" }, { t: "s", s: "S", k: "AC02" }, { t: "d", s: "D", k: "AC03" }, { t: "f", s: "F", k: "AC04" },
        { t: "g", s: "G", k: "AC05" }, { t: "h", s: "H", k: "AC06" }, { t: "j", s: "J", k: "AC07" }, { t: "k", s: "K", k: "AC08" },
        { t: "l", s: "L", k: "AC09" }, { t: ";", s: ":", k: "AC10" }, { t: "'", s: "\"", k: "AC11" },
        { label: "Enter", key: "Return", w: 2.5 }
    ],
    [
        // Alignment invariant shared with the symbols page: the units left of
        // ↑ (2.5 Shift + 10 letters here; 2.5 Shift + 8 punctuation + PgUp +
        // PgDn there) come to 12.5, and so do the units left of ↓ on the
        // command row (Ctrl+Fn+Super+Alt+emoji = 5, Space 4.5, AltGr + Ctrl +
        // ← = 3). Under the panel's one shared cell pitch a cap's x depends
        // only on the cumulative units before it, so ↑ sits exactly above ↓
        // at every preset by arithmetic rather than by tuning.
        { label: "Shift", key: "shift", w: 2.5 },
        { t: "z", s: "Z", k: "AB01" }, { t: "x", s: "X", k: "AB02" }, { t: "c", s: "C", k: "AB03" }, { t: "v", s: "V", k: "AB04" },
        { t: "b", s: "B", k: "AB05" }, { t: "n", s: "N", k: "AB06" }, { t: "m", s: "M", k: "AB07" }, { t: ",", s: "<", k: "AB08" },
        { t: ".", s: ">", k: "AB09" }, { t: "/", s: "?", k: "AB10" },
        { label: "↑", key: "Up" },
        // Spans exactly → plus the page key on the row below (see the lattice
        // note above). The 0.75 trailing Shift this row used to end on was a
        // flex-model hack whose label clipped at the panel edge.
        { label: "Shift", key: "shift", w: 2.0 }
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

// A function of the page key's label rather than a fixed table, because the
// label names the page the next press goes to: the main page when the curated
// page does not exist, the curated page when it does. The rows themselves are
// the declaration they always were.
function symbolRows(pageLabel) {
    return [
    [{ label: "esc", key: "Escape", w: 1.0 }]
        .concat(levelCaps(["TLDE", "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07",
               "AE08", "AE09", "AE10", "AE11", "AE12"], 2))
        .concat([{ label: "⌫", key: "BackSpace", w: 1.5 }]),
    [{ label: "Tab", key: "Tab", w: 1.5 }]
        .concat(levelCaps(punctuationPositions, 1))
        .concat([
            // Del is a nav cap like its neighbours: pointer-unreachable, and
            // keysymPositions already maps Delete. It has stood on this row
            // since round 4, and the owner's round-6 measured Windows
            // reference puts Del at the end of the main page's second row
            // too, where it now exists as a plain unit cap. All four nav
            // caps here are 1.5 units wide: 1.5 Tab + 8 punctuation + 4 ×
            // 1.5 nav is the 15.5 every row is declared to.
            { label: "Del", key: "Delete", w: 1.5 },
            { label: "Home", key: "Home", w: 1.5 },
            { label: "End", key: "End", w: 1.5 },
            { label: "Ins", key: "Insert", w: 1.5 }
        ]),
    // Shift is on this row because it is the one modifier the main page keeps
    // outside the command row, and a locked modifier has to stay *indicated* as
    // locked across a page switch, not merely stay held (spec-v1 §5).
    [{ label: "Shift", key: "shift", w: 2.5 }]
        .concat(levelCaps(punctuationPositions, 2))
        .concat([
            { label: "PgUp", key: "Prior" },
            { label: "PgDn", key: "Next" },
            // Same units-left invariant as the main page's fourth row
            // (2.5 + 8 + 1 + 1 = 12.5), so this ↑ also sits exactly above
            // the command row's ↓.
            { label: "↑", key: "Up" },
            { label: "Enter", key: "Return", w: 2.0 }
        ]),
        commandRow(pageLabel)
    ]
}

// The curated page (spec-v1.1 §3, decisions §17). An entry is declared as a
// keysym token, never a character: it is enabled only when some position and
// level of the complete active keymap carries that token, and typing it is
// the symbols page's own level-cap press with whatever real modifiers that
// level asks for — AltGr for levels 3 and 4, the way level 2 uses Shift.
// Nothing here widens the input boundary: no clipboard, no Unicode-entry
// chord, no IME, no keymap of its own.
//
// "Stable" is the palette, not a promise of availability (the ticket's own
// warning): the category sequence never reorders, and a symbol the active
// keymap cannot produce is simply absent — on plain `us` that is most of
// them, which is why the page exists only at eight or more available.
//
// Every name shipped here is a real keysym, checked against xkbcommon's
// keysym header (libxkbcommon 1.13): `logicalnot` is spelled `notsign`,
// `lessequal`/`greaterequal` are `lessthanequal`/`greaterthanequal`, and the
// single angle quotes are `leftsingleanglequotemark`/`rightsingleanglequotemark`.
// Plain `bullet` is not a keysym (the 0x0aXX legacy name for U+2022 is
// `enfilledcircbullet`), so the typography category runs without it.
// `rublesign` does not exist in xkbcommon 1.13 and is omitted. Hryvnia has
// no Latin keysym name in xkbcommon's list at all; the keymap spells it
// `U20B4` — keysym 0x10020b4 in xkbcommon's own Unicode-notation form,
// which is exactly how the keycap pipeline reports it — so that is the
// token declared here.
var curatedTokens = [
    // currency
    "EuroSign", "sterling", "yen", "cent", "currency", "U20B4",
    // mathematics
    "plusminus", "multiply", "division", "degree", "notsign", "approximate",
    "notequal", "lessthanequal", "greaterthanequal", "onehalf", "onequarter",
    "threequarters", "twosuperior", "threesuperior", "infinity",
    // typographic punctuation
    "guillemotleft", "guillemotright", "emdash", "endash", "ellipsis",
    "leftsinglequotemark", "rightsinglequotemark", "leftdoublequotemark",
    "rightdoublequotemark",
    // brackets: the single angle quotes
    "leftsingleanglequotemark", "rightsingleanglequotemark",
    // legal marks
    "copyright", "registered", "trademark", "section", "numerosign",
    // common
    "mu", "brokenbar"
]

// Show page 2 only at eight or more available symbols (spec-v1.1 §3).
var curatedMinimum = 8

/// token -> { position, level } over the keycap pipeline's own answer. The
/// whole point of building it here, from symbolMap, is that availability is
/// the keymap's claim about itself: a symbol is enabled because the keymap
/// carries it somewhere, at whatever level that is — including the AltGr
/// levels a main-page cap never shows. Empty levels and NoSymbol are nothing
/// to index.
function buildTokenIndex(symbolMap) {
    var index = {}
    for (var position in symbolMap) {
        var levels = symbolMap[position]
        if (!Array.isArray(levels)) continue
        for (var i = 0; i < levels.length; i++) {
            var token = String(levels[i] || "").trim()
            if (token === "" || token === "NoSymbol") continue
            // First occurrence wins: a token the keymap carries twice types
            // the same either way, and one fixed answer keeps the cap stable.
            if (index.hasOwnProperty(token)) continue
            index[token] = { position: position, level: i + 1 }
        }
    }
    return index
}

// The slot plan, sized for the full palette and never reshaped: the available
// symbols fill the slots in curatedTokens' order, and a slot nothing resolves
// to becomes an invisible spacer ({ w } alone) so the row still sums to the
// grid without drawing a blank cap. A content row nothing at all resolves to
// is left out entirely.
//
// Row shapes, on the shared 15.5-unit half-lattice: esc + 13 + ⌫ like every
// page's first row; a free row of 15 closed by an invisible half-unit pad;
// then Shift + 11 + Enter like the symbols page's third row — Shift
// because a locked Shift must stay indicated across a page switch (spec-v1
// §5), Enter because a symbols page without one strands the user.
// 13 + 15 + 11 = 39 slots, one per curated token; the command row closes the
// page as on every other page, labelled for the main page it returns to.
var curatedShape = [
    {
        before: [{ label: "esc", key: "Escape", w: 1.0 }],
        slots: 13,
        after: [{ label: "⌫", key: "BackSpace", w: 1.5 }]
    },
    {
        before: [],
        slots: 15,
        // Fifteen unit slots leave half a unit short of the grid; the pad
        // keeps the row on it without widening any cap.
        after: [{ w: 0.5 }]
    },
    {
        before: [{ label: "Shift", key: "shift", w: 2.5 }],
        slots: 11,
        after: [{ label: "Enter", key: "Return", w: 2.0 }]
    }
]

// The tallest this page can be: the full palette's three content rows plus
// the command row. The panel pins its height to the tallest page — the
// main page, four content rows plus the command row — so a page switch
// never resizes the panel.
var curatedMaxRows = curatedShape.length + 1

/// The page's rows and its availability count, both derived from the keymap's
/// own answer. Recomputed whenever symbolMap reloads — never per click.
function curatedPageRows(symbolMap) {
    var index = buildTokenIndex(symbolMap)
    var caps = []
    for (var i = 0; i < curatedTokens.length; i++) {
        var hit = index[curatedTokens[i]]
        if (hit) caps.push({ k: hit.position, lvl: hit.level })
    }
    var rows = []
    var next = 0
    for (var r = 0; r < curatedShape.length; r++) {
        var row = curatedShape[r].before.slice()
        var filled = 0
        for (var s = 0; s < curatedShape[r].slots; s++) {
            if (next < caps.length) {
                row.push(caps[next])
                next += 1
                filled += 1
            } else {
                row.push({ w: 1 })
            }
        }
        row = row.concat(curatedShape[r].after)
        if (filled > 0) rows.push(row)
    }
    rows.push(commandRow("ABC"))
    return { rows: rows, available: caps.length }
}

/// A spacer slot: width for the grid and nothing else — no key, no
/// position, no character, no label — so the panel can leave it undrawn
/// and inert.
function isBlank(keyData) {
    return !keyData.key && !keyData.k && !keyData.label
        && !keyData.t && !keyData.s
}


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
    EuroSign: "\u20ac",
    // The curated page's tokens (spec-v1.1 §3). A page-2 cap is only ever
    // created because the keymap itself carries the token — see
    // buildTokenIndex — so this table is the drawn half of the same claim:
    // what the keymap resolved is what the cap must show.
    sterling: "\u00a3",
    yen: "\u00a5",
    cent: "\u00a2",
    plusminus: "\u00b1",
    multiply: "\u00d7",
    division: "\u00f7",
    notsign: "\u00ac",
    approximate: "\u2248",
    notequal: "\u2260",
    lessthanequal: "\u2264",
    greaterthanequal: "\u2265",
    onehalf: "\u00bd",
    onequarter: "\u00bc",
    threequarters: "\u00be",
    twosuperior: "\u00b2",
    threesuperior: "\u00b3",
    infinity: "\u221e",
    ellipsis: "\u2026",
    leftsinglequotemark: "\u2018",
    rightsinglequotemark: "\u2019",
    leftsingleanglequotemark: "\u2039",
    rightsingleanglequotemark: "\u203a",
    copyright: "\u00a9",
    registered: "\u00ae",
    trademark: "\u2122",
    mu: "\u00b5"
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

/// What the compiled keymap has to say about one cap, expressed as the fields
/// to lay over it — never as an edit to the cap itself. Positions the keymap
/// does not cover are appended to `misses` and left for the caller to report;
/// a miss is a reporting matter, not an error (§11).
function capOverlay(keyData, symbols, misses) {
    var levels = Array.isArray(symbols) ? symbols : []
    var textAt = function (index) {
        return tokenToText(index < levels.length ? levels[index] : "", UNRESOLVED)
    }

    // A symbols-page cap draws exactly one level and carries no built-in
    // character, so there is nothing to fall back *to*: an unresolved level
    // leaves the cap blank and is reported, which is the §11 rule with the
    // silent substitution removed entirely.
    if (keyData.lvl) {
        var index = keyData.lvl - 1
        var drawn = textAt(index)
        var overlay = { t: drawn === UNRESOLVED ? "" : drawn }
        if (drawn === UNRESOLVED) {
            var token = index < levels.length ? String(levels[index]).trim() : ""
            misses.push(keyData.k + (index > 0 ? "^" : "") + "="
                + (levels.length > 0 ? (token || "<no symbol at this level>")
                                     : "<no keymap entry>"))
        }
        // A latched or locked Shift applies to every press, including one on a
        // base-level cap, so a base-level cap has to be able to show what Shift
        // would actually produce — otherwise the page would draw `[` while
        // typing `{`, which is the one thing this keyboard is for. It still
        // draws as a single glyph (see isDualKey): the stacked pair belongs to
        // the main page, and the shift level has a cap of its own here.
        if (index === 0) {
            var paired = textAt(1)
            if (paired !== UNRESOLVED) overlay.s = paired
        }
        return overlay
    }

    if (levels.length === 0) {
        if (!drawsFixedLabel(keyData)) misses.push(keyData.k + "=<no keymap entry>")
        return {}
    }

    // A main-page cap keeps whichever of its two built-in characters the keymap
    // failed to supply, so the overlay carries only the levels that resolved.
    var pair = {}
    var base = tokenToText(levels[0], UNRESOLVED)
    if (base !== UNRESOLVED) pair.t = base
    else if (!drawsFixedLabel(keyData)) misses.push(keyData.k + "=" + levels[0])

    if (levels.length > 1 && String(levels[1] || "").trim() !== "") {
        var shifted = tokenToText(levels[1], UNRESOLVED)
        if (shifted !== UNRESOLVED) pair.s = shifted
        else if (!drawsFixedLabel(keyData)) misses.push(keyData.k + "^=" + levels[1])
    }
    return pair
}

/// A silent substitution is the failure mode decisions.md §11 records: the awk
/// program broke, the map came back empty, and the built-in US table stayed on
/// screen for days while the label said "Ukrainian". One line per rebuild
/// rather than one per key, so a wholly empty map is loud without being sixty
/// lines of noise.
function reportMisses(misses, layoutCode) {
    if (misses.length === 0) return
    var shown = misses.slice(0, 12).join(" ")
    if (misses.length > 12) shown += " … and " + (misses.length - 12) + " more"
    console.error("[osk] keycap fallback to built-in table for " + layoutCode
        + ": " + misses.length + " cap(s): " + shown)
}

/// The page's declared rows, resolved against a compiled keymap.
///
/// `rows` and `symbolRows` are module-level declarations that outlive every
/// layout change, so this returns a fresh cap for each one rather than writing
/// into them: a pass that edited them in place would leave the previous
/// language's characters on any cap the new keymap does not cover. Deep-copying
/// the whole table first would also do that, but building each cap as source
/// plus overlay means there is no copy to keep in step with the declaration.
function applyLanguage(rowsSource, layoutCode, symbolMap) {
    var misses = []
    var resolved = rowsSource.map(function (row) {
        return row.map(function (keyData) {
            var overlay = keyData.k
                ? capOverlay(keyData, symbolMap ? symbolMap[keyData.k] : null, misses)
                : {}
            return Object.assign({}, keyData, overlay)
        })
    })
    reportMisses(misses, layoutCode)
    return resolved
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
