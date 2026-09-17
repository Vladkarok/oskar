.pragma library

// Each key: { chr, chrShift } for typed keys (see typedRow),
// or { label, key: keysym/modifier-name, w: width units } for special keys.
// Keys without w are one unit wide, every width is a multiple of 0.5, and
// every row's widths sum to 15.5 exactly: the panel lays all rows out on one
// shared cell pitch (Keyboard.qml) and loudly reports any row that misses
// it, because under a shared pitch a short row stops short of the card edge
// instead of merely shrinking. The widths sit on a half-unit lattice in the
// owner-measured Windows stagger; what that buys is the grid comment in
// Keyboard.qml, and this is not the place to say it twice.
//
// A second shape belongs to `&123`: { glyph: "£", shiftGlyph: "€" } names
// CHARACTERS and lets the keymap say which position and level carries each.
// It has no built-in character at all, because a fixed ASCII table is the lie
// this project exists to avoid — a character no keymap carries draws dim and
// refuses its press. Such a cap is `exact`: it draws its own level under
// every modifier combination (see charUnderModifiers), because the chord is
// the level's decision and not the latch's.
// A typed cap names a character: `chr` is what an unshifted press
// produces, `chrShift` its shifted form (omitted when the shift of a
// letter is simply its uppercase), `xkb` the evdev position the press
// is sent to. The rows below declare characters only; a row builder
// derives the xkb positions from the row's own index, because the evdev
// alphabetic block numbers them AE/AD/AC/AB by row and 01..NN left to
// right — the one numbering every layout shares.
function typedRow(chrSpec, rowNo, extra) {
    var prefixes = ["AE", "AD", "AC", "AB"]
    // Row 0 opens on TLDE, so its numbered block starts at the SECOND
    // cap; the letter row closes past its block on BKSL. A bare letter's
    // shift is its uppercase — stated once here instead of once per cap.
    var caps = chrSpec.split(" ").map(function (pair, i) {
        var n = rowNo === 0 ? i : i + 1
        var cap = { chr: pair.charAt(0), xkb: prefixes[rowNo] + two(n) }
        if (pair.length > 1) cap.chrShift = pair.charAt(1)
        else if (pair.length === 1 && /[a-z]/.test(pair))
            cap.chrShift = pair.toUpperCase()
        return cap
    })
    if (rowNo === 0) caps[0].xkb = "TLDE"
    if (rowNo === 1) caps[caps.length - 1].xkb = "BKSL"
    return extra ? caps.concat(extra) : caps
}

function two(n) {
    return (n < 10 ? "0" : "") + n
}

var functionRow = [{
    label: "esc", key: "Escape", w: 1.0
}].concat(typedRow("`~", 0), fCaps(12), [{
    label: "⌫", key: "BackSpace", w: 1.5
}])

function fCaps(n) {
    var caps = []
    for (var i = 1; i <= n; i++)
        caps.push({ label: "F" + i, key: "F" + i })
    return caps
}

// ---- the Super cap's mark (ticket 22, decisions §27 as amended) ----
//
// Which arm of the settings choice the Super cap draws. Pure so the host
// suite can drive it: `mark` is the setting string, `omarchyFontPresent` the
// packaged-TTF gate, and the answer names the one arm Keyboard.qml shows.
//
// The word is the default and the landing place for everything undrawable:
// an unknown setting string (the store rejects them, but the QML treats one
// as the word anyway so nothing can ever draw a blank cap) and the Omarchy
// choice when the private font is absent (§27: the gate stays attached to
// that arm alone — an absent file never requests U+E900).
function superMarkArm(mark, omarchyFontPresent) {
    if (mark === "omarchy") return omarchyFontPresent ? "omarchy" : "word"
    if (mark === "windows" || mark === "macos" || mark === "penguin") return mark
    return "word"
}

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
        // Super's cap draws this label by default (ticket 22): the word is
        // the default arm of the mark setting, this label is the accessible
        // name of every arm, and it is the missing-font fallback of the
        // Omarchy glyph arm (spec-v1.1 §1, decisions §27 as amended).
        { label: "Super", key: "logo" },
        { label: "Alt", key: "alt" },
        // The emoji cap (spec-v1.1 §1): a fixed label for the cap that
        // opens the panel's own emoji page. Like the arrows, it is artwork,
        // not a character any level of the keymap produces.
        { label: "☺", key: "emoji" },
        { chr: " ", label: "", w: 4.5, xkb: "SPCE" },
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
    ].concat(
        typedRow("`~ 1! 2@ 3# 4$ 5% 6^ 7& 8* 9( 0) -_ =+", 0),
        [{ label: "⌫", key: "BackSpace", w: 1.5 }]
    ),
    [
        { label: "Tab", key: "Tab", w: 1.5 },
    ].concat(
        typedRow("q w e r t y u i o p [{ ]} \\|", 1),
        // Windows' reference ends this row in Del; the keysym mapping and the
        // symbols-page cap below already existed.
        [{ label: "Del", key: "Delete" }]
    ),
    [
        { label: "Caps Lock", key: "caps", w: 2.0 },
    ].concat(
        typedRow("a s d f g h j k l ;: '\"", 2),
        [{ label: "Enter", key: "Return", w: 2.5 }]
    ),
    [
        // Alignment invariant shared with the symbols page: the units left of
        // ↑ (2.5 Shift + 10 letters here; 2.5 Shift + 8 punctuation + PgUp +
        // PgDn there) come to 12.5, and so do the units left of ↓ on the
        // command row (Ctrl+Fn+Super+Alt+emoji = 5, Space 4.5, AltGr + Ctrl +
        // ← = 3). Under the panel's one shared cell pitch a cap's x depends
        // only on the cumulative units before it, so ↑ sits exactly above ↓
        // at every preset by arithmetic rather than by tuning.
        { label: "Shift", key: "shift", w: 2.5 },
    ].concat(
        typedRow("z x c v b n m ,< .> /?", 3),
        [{ label: "↑", key: "Up" }],
        // Spans exactly → plus the page key on the row below (see the lattice
        // note above). The 0.75 trailing Shift this row used to end on was a
        // flex-model hack whose label clipped at the panel edge.
        { label: "Shift", key: "shift", w: 2.0 }
    ),
    commandRow("&123")
]

// One direct punctuation page. The ten familiar number-row symbols occupy
// the top row and Shift reaches digits 1–0 on those same caps; every other
// ASCII punctuation mark gets its own one-click cap. The fixed controls keep
// their exact main-page coordinates and wider punctuation/nav caps consume
// the former empty centre. Every character cap resolves by glyph through the
// helper's reserved block, so neither ASCII nor digits depend on a `us` group.
function glyphCap(ch, width, shifted) {
    var cap = { glyph: ch }
    if (width) cap.w = width
    if (shifted) cap.shiftGlyph = shifted
    return cap
}

function symbolDigit(symbol, digit) {
    return glyphCap(symbol, 0, digit)
}


function symbolRows(pageLabel) {
    return [
        [
            { label: "esc", key: "Escape", w: 1.0 },
            symbolDigit("!", "1"), symbolDigit("@", "2"),
            symbolDigit("#", "3"), symbolDigit("$", "4"),
            symbolDigit("%", "5"), symbolDigit("^", "6"),
            symbolDigit("&", "7"), symbolDigit("*", "8"),
            symbolDigit("(", "9"), symbolDigit(")", "0"),
            glyphCap("`"), glyphCap("-"), glyphCap("="),
            { label: "⌫", key: "BackSpace", w: 1.5 }
        ],
        [
            { label: "Tab", key: "Tab", w: 1.5 },
            glyphCap("[", 1.5), glyphCap("]", 1.5),
            glyphCap("{", 1.5), glyphCap("}", 1.5),
            glyphCap("\\", 1.5), glyphCap("|", 1.5),
            glyphCap(";"), glyphCap(":"), glyphCap("'"), glyphCap("\""),
            { label: "Del", key: "Delete" }
        ],
        [
            glyphCap(",", 1.5), glyphCap(".", 1.5),
            glyphCap("/", 1.5), glyphCap("_", 1.5),
            glyphCap("+", 1.5), glyphCap("<", 1.5),
            glyphCap(">", 1.5), glyphCap("?", 1.5),
            glyphCap("~"),
            { label: "Enter", key: "Return", w: 2.5 }
        ],
        // Five symbol slots and the navigation caps at one unit each. The
        // navigation labels were 1.5 to 2.0 units and are pointer targets for
        // keys nobody hunts for, so they gave up the width — but none of them
        // could be dropped: Home, End, Ins, PgUp and PgDn exist on this page
        // and nowhere else in the panel.
        //
        // Five is what the row yields, and it is the arithmetic that decides
        // it: 2.5 + 5 + 5 leaves ↑ starting at 12.5, which is where the
        // command row's ↓ starts, and the two have to line up.
        //
        // Every slot is a dual glyph cap — the more used character on the
        // base, the rarer one drawn dim above it under Shift, so a symbol
        // behind Shift is still visibly there. Pairs are grouped by meaning:
        // currency with currency, measurement with measurement, maths with
        // maths.
        //
        // Six characters want the base and there are five places, so one is
        // on a Shift half: `€`, because it is the only one of the six the
        // active layout may already carry on its own AltGr level, and the
        // glyph index resolves it there when it does.
        [
            { label: "Shift", key: "shift", w: 2.5 },
            { glyph: "£", shiftGlyph: "€" },
            { glyph: "¥", shiftGlyph: "¢" },
            { glyph: "°", shiftGlyph: "±" },
            { glyph: "×", shiftGlyph: "≈" },
            { glyph: "÷", shiftGlyph: "≠" },
            { label: "Home", key: "Home" },
            { label: "End", key: "End" },
            { label: "Ins", key: "Insert" },
            { label: "PgUp", key: "Prior" },
            { label: "PgDn", key: "Next" },
            { label: "↑", key: "Up" },
            { label: "Shift", key: "shift", w: 2.0 }
        ],
        commandRow(pageLabel)
    ]
}

// Fn on the symbols page exposes explicit media controls without changing
// the main Fn row. They occupy Home/End's two-unit slots, so every fixed edge
// and all F1–F12 remain where they already are.
function symbolFunctionRows(pageLabel) {
    var result = symbolRows(pageLabel)
    result[0] = functionRow
    // Home and End give up their slots, and they are found by label rather
    // than by index: the row's shape moved once already when the symbol slots
    // arrived, and an index silently replaced two glyph caps instead.
    var row = result[3].slice()
    var media = { Home: { label: "⏮", key: "XF86AudioPrev" },
                  End: { label: "⏭", key: "XF86AudioNext" } }
    for (var i = 0; i < row.length; i++) {
        var swap = media[row[i].key]
        if (swap) row[i] = { label: swap.label, key: swap.key, w: row[i].w || 1 }
    }
    result[3] = row
    return result
}


// Positions whose facts the panel asks for on top of the ones its pages
// declare, because the reserved symbol block may be hosted there (§33) and a
// glyph cap names a character rather than a position.
//
// This is a REQUEST list, not a map: which of these the helper actually hosts
// on depends on the layout, and nothing here needs to know — `buildGlyphIndex`
// asks the facts where each character lives. Asking for one the helper left
// alone costs an empty record.
//
// The digit row and the other rows' non-letter positions, which every
// application's keycode table carries, plus the two free positions ticket 20
// measured through. The exotic free keycodes this list used to hold are gone:
// Chromium's Ozone/Wayland DomCode table drops them and Wine substitutes for
// them, so the symbols typed in a terminal and produced nothing in Electron.
var reservedPositions = [
    "AE01", "AE02", "AE03", "AE04", "AE05", "AE06",
    "AE07", "AE08", "AE09", "AE10", "AE11", "AE12",
    "AD11", "AD12", "AC10", "AC11", "AB08",
    "AB09", "AB10", "TLDE", "BKSL", "LSGT",
    "AB11", "AE13"
]


/// Every positioned cap the panel can draw, in declaration order — the
/// position list a caps request carries. Built from the page declarations
/// (typedRow names each cap's `xkb`), plus RALT and the reserved block,
/// which no page declares. Lives here, beside the declarations it reads,
/// so the field name cannot drift away from the panel's copy of it: the
/// caller that read a renamed field (`k` after the `xkb` rename) got a
/// one-position list back, the helper honestly answered just that
/// position, and twenty-six letter caps drew the built-in tables.
function declaredPositions() {
    var seen = {}
    var out = []
    var pages = [rows, symbolRows("")]
    for (var p = 0; p < pages.length; p++) {
        for (var r = 0; r < pages[p].length; r++) {
            for (var c = 0; c < pages[p][r].length; c++) {
                var pos = pages[p][r][c].xkb
                if (pos && !seen[pos]) {
                    seen[pos] = true
                    out.push(pos)
                }
            }
        }
    }
    if (!seen.RALT) out.push("RALT")
    for (var i = 0; i < reservedPositions.length; i++) {
        var reserved = reservedPositions[i]
        if (!seen[reserved]) {
            seen[reserved] = true
            out.push(reserved)
        }
    }
    return out
}

/// Which real modifiers an exact-level cap holds around its key.
///
/// Levels five to eight are the reserved block's (decisions §33): `<LVL5>`
/// opens them, and Shift and `<LVL3>` choose among the four exactly as they
/// choose among the four below. One table, so a cap, a press and a test
/// cannot disagree about what level 7 means.
function levelChord(level) {
    var value = Number(level) || 1
    return {
        shift: value === 2 || value === 4 || value === 6 || value === 8,
        level3: value === 3 || value === 4 || value === 7 || value === 8,
        level5: value > 4
    }
}

/// Where each drawable character lives in the active keymap: character ->
/// { position, level }.
///
/// By CHARACTER, not by keysym token. The helper's caps facts carry resolved
/// text (`t<text>`) for anything drawable and a keysym name only for symbols
/// that produce no character, so "sterling" is not a thing to look up — "£"
/// is. That turns out to be the better question anyway: a cap wants a
/// character, and it does not care whether the active layout already carried
/// it or the reserved block supplied it.
///
/// First occurrence wins, in LEVEL then position order, so a character the
/// keymap offers twice always resolves to the same chord and the cap does not
/// move when something unrelated changes.
///
/// Level-major, and that is the whole point of the ordering. The block lives
/// on levels five to eight of ordinary positions now (decisions §33), so a
/// position-major scan would find `@` on `AE01`'s catalogue level before
/// `AE02`'s own Shift level and send `<LVL5>`+`<LVL3>` for a character plain
/// Shift already types. Level-major asks the layout first and reaches for the
/// block only for what the layout does not carry — which on `us` is the ten
/// special glyphs and nothing else.
///
/// Eight levels, not four: the block moved above the layout's own levels
/// rather than onto positions of its own.
function buildGlyphIndex(capsFacts) {
    var index = {}
    if (!capsFacts) return index
    var positions = []
    for (var position in capsFacts) positions.push(position)
    positions.sort()
    for (var i = 0; i < 8; i++) {
        for (var p = 0; p < positions.length; p++) {
            var levels = capsFacts[positions[p]]
            if (!Array.isArray(levels) || i >= levels.length) continue
            var entry = levels[i]
            if (!entry || typeof entry.text !== "string" || entry.text === "") continue
            if (index.hasOwnProperty(entry.text)) continue
            index[entry.text] = { position: positions[p], level: i + 1 }
        }
    }
    return index
}


/// A spacer slot: declared, not sniffed — `spacer: true` plus the width
/// that keeps its row on the grid, and nothing else. The panel leaves a
/// declared spacer undrawn and inert; anything that merely happens to
/// carry no key stays a drawing decision, not a layout one.
function isSpacer(capData) {
    return capData.spacer === true
}


// A cap that draws a fixed label — Esc, Enter, the arrows, and Space, whose
// label is deliberately empty — shows the same thing on every layout and has
// no keymap symbol to miss. Only the caps that are supposed to come out of the
// compiled keymap can fall back to a built-in value, and only those are worth
// reporting.
function drawsFixedLabel(capData) {
    return capData.hasOwnProperty("label")
}

// "No answer", distinct from a level that really does resolve to the empty
// string. Spelled with an escape rather than a literal NUL: the literal made
// every `grep` treat this file as binary and skip it silently, which cost two
// separate investigations an afternoon each.
var UNRESOLVED = "\u0000unresolved"

// Whether a two-level cap is a letter pair — the shifted level is simply the
// capital of the base — which holds in any script and needs no per-alphabet
// table. `/^[a-z]$/` recognised only Latin, so Cyrillic and Greek letters were
// treated as punctuation: Caps Lock did nothing on them and they rendered as
// stacked dual keys. Asking merely whether the base has a capital is not
// enough either — French AZERTY carries é on the same key as 2, and é does
// have a capital, so Caps Lock would type 2 instead of É.
function isLetterKey(capData) {
    var base = capData.chr || ""
    var shifted = capData.chrShift || ""
    return base.length > 0 && shifted.length > 0 && shifted === base.toUpperCase()
}

// The character one cap resolves to, given what Caps and Shift are doing.
// Moved here from Keyboard.qml (ticket 03) so that the rule deciding what a
// cap SHOWS lives in the same module as the rules deciding what its press
// TYPES, and the two can only move together, tested at the pure seam: caps
// must match actual typed output, and this function is where they meet.
//
// An exact cap — `&123`'s glyph caps — answers only to the level it carries:
// its press types that level whatever the modifiers are doing (a latched
// Shift or AltGr is spent by it, never applied to it; a locked Shift is
// lifted around the press and restored; Caps affects letters only), so the
// display follows the same rule and never redraws as another
// symbol just because Shift is active. Letters swap on Caps XOR Shift, exactly
// as the panel always drew them. Every other paired cap shifts with Shift
// alone.
function charUnderModifiers(capData, capsOn, shiftOn) {
    if (capData.exact === true) return capData.chr || ""
    if (isLetterKey(capData)) {
        return capsOn !== shiftOn && capData.chrShift ? capData.chrShift : capData.chr
    }
    return shiftOn && capData.chrShift ? capData.chrShift : capData.chr
}

/// What the compiled keymap has to say about one cap, expressed as the fields
/// to lay over it — never as an edit to the cap itself. Positions the keymap
/// does not cover are appended to `misses` and left for the caller to report;
/// a miss is a reporting matter, not an error (§11).
///
/// Entries are the helper's keycap facts (decisions §23, ticket 04): already
/// resolved level answers, `{ text }` for drawable character text and
/// `{ none }` for a level with nothing to draw. There is no second reading —
/// the §11 pipeline compiled keysym tokens with its own `xkbcli` and this
/// function had to know both; ticket 05 retired it, and with it the last
/// place where two authorities could disagree about what a position carries.
function capOverlay(capData, symbols, misses) {
    var levels = Array.isArray(symbols) ? symbols : []
    var textAt = function (index) {
        if (index >= levels.length) return UNRESOLVED
        var answer = levels[index]
        return answer && typeof answer.text === "string" ? answer.text : UNRESOLVED
    }
    // The miss text for one level: what the keymap actually has there, or the
    // honest name for the hole — a level past the entry's length is "no symbol
    // at this level", a position with no entry at all is the plainer "no
    // keymap entry".
    var missToken = function (index) {
        if (levels.length === 0) return "<no keymap entry>"
        var answer = levels[index]
        if (answer && answer.none !== undefined)
            return answer.none === "" ? "<no symbol at this level>" : answer.none
        return "<no symbol at this level>"
    }

    // The symbols page's dual cap (2026-09-05, the owner's symbols-page v2
    // round): both levels from the keymap, no built-in character behind
    // either. Whichever level resolves is carried as t (base) / s (shifted)
    // and the panel draws the stacked pair with Shift-swapped emphasis, so
    // the page SHOWS what Shift does to every cap. A level that does not
    // resolve is a miss; a cap with neither resolving is marked unavailable —
    // dim, press-refusing, never a silent blank (spec-v1.1 §3). What a cap
    // does with a latched Shift is the main page's own pairing semantics
    // (non-exact press in Keyboard.qml), decided by ModifierReducer.js;
    // nothing here changes a reducer fact.
    if (capData.dual) {
        var dual = {}
        var dualBase = textAt(0)
        if (dualBase !== UNRESOLVED) dual.chr = dualBase
        else misses.push(capData.xkb + "=" + missToken(0))
        var dualShifted = textAt(1)
        if (dualShifted !== UNRESOLVED) dual.chrShift = dualShifted
        else misses.push(capData.xkb + "^=" + missToken(1))
        if (dual.chr === undefined && dual.chrShift === undefined)
            dual.unavailable = true
        return dual
    }

    if (levels.length === 0) {
        if (!drawsFixedLabel(capData)) misses.push(capData.xkb + "=<no keymap entry>")
        return {}
    }

    // A main-page cap keeps whichever of its two built-in characters the
    // keymap failed to supply, so the overlay carries only the levels that
    // resolved.
    var overlay = {}
    var base = textAt(0)
    if (base !== UNRESOLVED) overlay.chr = base
    else if (!drawsFixedLabel(capData)) misses.push(capData.xkb + "=" + missToken(0))

    if (levels.length > 1) {
        var shifted = textAt(1)
        if (shifted !== UNRESOLVED) overlay.chrShift = shifted
        else if (!drawsFixedLabel(capData)) misses.push(capData.xkb + "^=" + missToken(1))
    }
    return overlay
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
    reportOnce("[oskar] keycap fallback to built-in table for " + layoutCode
        + ": " + misses.length + " cap(s): " + shown)
}

/// The same complaint, said once.
///
/// `applyLanguage` runs on every facts change AND on every page toggle, and
/// it runs before the caller's identity check can decide the rows did not
/// change. Toggling to `&123` and back on a keymap that is missing something
/// used to print the same line each time. What is worth knowing is that the
/// keymap is short, not how many times the user pressed a key.
var lastReport = ""
function reportOnce(line) {
    if (line === lastReport) return
    lastReport = line
    console.error(line)
}

/// The page's declared rows, resolved against a compiled keymap.
///
/// `rows` and `symbolRows` are module-level declarations that outlive every
/// layout change, so this returns a fresh cap for each one rather than writing
/// into them: a pass that edited them in place would leave the previous
/// language's characters on any cap the new keymap does not cover. Deep-copying
/// the whole table first would also do that, but building each cap as source
/// plus overlay means there is no copy to keep in step with the declaration.
function applyLanguage(rowsSource, layoutCode, capsFacts) {
    // One fact source: the helper's acknowledged keycap facts, resolved by
    // libxkbcommon against the very keymap that types (decisions §23). The
    // second source — the §11 xkbcli pipeline's `symbolMap`, which fed `token`
    // and `lvl` caps — went with ticket 18: every cap is a glyph cap or a
    // positioned cap now, and keeping a compile that nothing drew from cost a
    // process per layout change and could raise "keymap unavailable" over caps
    // that were perfectly good.
    //
    // With `capsFacts` absent — facts still in flight, or an unresolved
    // mismatch — the built-in table draws as the gated last-resort fallback
    // (spec-v1 §3.5) while the panel's status owns saying why; that window
    // is deliberately NOT reported per cap, or every group switch would log
    // a forty-line miss report for facts that are milliseconds away. With
    // facts in hand, a position they do not answer is a loud per-cap miss,
    // exactly as before.
    var misses = []
    var glyphIndex = null
    // Glyph caps asked for and glyph caps answered. A page where NONE of them
    // resolved is not fifty independent misses — it is the reserved block
    // missing (decisions §33), and saying so once is the only useful thing to
    // print. The panel used to infer this from a hand-mirrored copy of the
    // helper's host list, which could not tell a hosted position from one
    // that natively has eight levels; this asks the question the user cares
    // about instead, which is whether any symbol cap can type.
    var glyphCaps = 0
    var glyphHits = 0
    var resolved = rowsSource.map(function (row) {
        return row.map(function (capData) {
            var overlay
            if (capData.glyph) {
                // A cap that asks for a character and lets the keymap say
                // where it lives. Unresolved means the active keymap cannot
                // produce it at all: dim and press-refusing, never a blank
                // cap that looks typeable (spec-v1.1 §3).
                //
                // `shiftGlyph` makes it a dual cap, drawn by the panel the
                // way every other dual cap is — the Shift character dim on
                // top, the base bright below — so a symbol hidden behind
                // Shift is still visibly THERE. The two halves resolve
                // independently: one can sit at level 1 of a position the
                // active layout owns while the other sits at level 3 of the
                // reserved block, and the press follows whichever is typed.
                if (!glyphIndex) glyphIndex = buildGlyphIndex(capsFacts)
                var glyphHit = glyphIndex[capData.glyph]
                glyphCaps += 1
                if (glyphHit) {
                    glyphHits += 1
                    // `level3` says this chord needs the <LVL3> POSITION
                    // rather than RALT, which is not something the level
                    // alone decides — a pair cap at level 3 wants RALT. The
                    // rest of the chord is the level's, and `typeCap` reads
                    // it from `levelChord`; a second copy here would be one
                    // more thing to keep in step.
                    overlay = { chr: capData.glyph, xkb: glyphHit.position,
                                baseLvl: glyphHit.level, exact: true,
                                level3: levelChord(glyphHit.level).level3 }
                    if (capData.shiftGlyph) {
                        var shiftHit = glyphIndex[capData.shiftGlyph]
                        if (shiftHit) {
                            overlay.dual = true
                            overlay.chrShift = capData.shiftGlyph
                            overlay.xkbShift = shiftHit.position
                            overlay.slvl = shiftHit.level
                            overlay.shiftLevel3 = levelChord(shiftHit.level).level3
                        } else {
                            // A Shift half the keymap cannot produce is simply
                            // absent: drawing it grey would promise a keystroke
                            // that does nothing. The base half still types.
                            misses.push(capData.shiftGlyph + " (shift of "
                                + capData.glyph + ") is not in this keymap")
                        }
                    }
                } else {
                    // The base did not resolve, so the whole cap is refused —
                    // including a Shift half that did. `disabled` gates the
                    // press for the cap as a whole, so attaching the upper
                    // glyph here would draw a character the cap cannot type,
                    // which is the exact promise spec-v1.1 §3 forbids. Both
                    // halves are reported: a page quietly losing caps on a
                    // keymap with fewer free positions is how this goes
                    // unnoticed.
                    overlay = { chr: capData.glyph, unavailable: true }
                    misses.push(capData.glyph + " is not in this keymap")
                    if (capData.shiftGlyph)
                        misses.push(capData.shiftGlyph + " (shift of "
                            + capData.glyph + ") is unreachable: its base is not")
                }
            } else if (!capData.xkb)
                // No position, no keymap question. (The retired §3 curated
                // page's `fixedGlyph`/`latin` test went with ticket 40:
                // fields nothing in the tree has set since that page died —
                // the declared-vocabulary pin in tests/keyboard-layout.qml
                // keeps them from coming back by accident.)
                overlay = {}
            else if (capsFacts)
                overlay = capOverlay(capData, capsFacts[capData.xkb], misses)
            else
                overlay = {}
            return Object.assign({}, capData, overlay)
        })
    })
    // Both, not one or the other: the cause line explains a page with no
    // symbols, and the miss list is still the only place a positioned cap's
    // own miss is named.
    if (capsFacts && glyphCaps > 0 && glyphHits === 0)
        reportOnce("[oskar] not one character this page draws is in the keymap"
            + " the helper installed: the reserved symbol block did not land"
            + " (decisions §33), so every symbol cap draws unavailable."
            + " " + glyphCaps + " cap(s) affected. A layout option that puts"
            + " Hyper or ISO_Level5_Shift on a real key keeps the block off"
            + " ordinary positions, which is the usual cause.")
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
    Insert: "INS",
    XF86AudioPrev: "I173",
    XF86AudioNext: "I171"
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
