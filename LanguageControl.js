.pragma library

// The header language control's three shapes, and the chooser menu's
// entries. Pure data: the panel wires these to the layout facts
// Keyboard.qml already holds (layoutCodes, layoutTitles, groupCursor,
// switchKeyboards) and to the same absolute-group move stepLayout has
// always issued.
//
// Shapes:
//  - one layout: hidden. Nothing to switch; an inert chip is noise and a
//    false affordance.
//  - two layouts: direct. Click toggles to the other group — the shape
//    the panel always had, unchanged.
//  - three or more: menu. Click opens the chooser; picking an entry
//    moves every device in the switch set to that ABSOLUTE group.
// A count >= 2 with an empty switch set is visible but disabled: hidden
// means "nothing to switch", not "nobody safe to move" — the
// ingestSeatFacts caveat about guessed devices keeps its grey
// signal. The two facts are deliberately separate inputs so the QML never
// recombines them differently on the fill vs the click path.

function controlState(layoutCount, switchSetLength) {
    var count = typeof layoutCount === "number" ? layoutCount : 0
    if (count < 2) return "hidden"
    return switchSetLength > 0 ? (count > 2 ? "menu" : "direct") : "disabled"
}

// A language is named in its own language: the chip and the chooser show
// endonyms — English, Українська, Русский, Italiano — not base.lst's
// English descriptions. Curated and keyed by xkb
// layout code; a code the table does not carry falls back to base.lst and
// then to the code itself, so an exotic layout is never blank. `us` and
// `gb` stay distinct ("English" / "English (UK)") for seats carrying both.
var ENDONYMS = {
    us: "English", gb: "English (UK)",
    ua: "Українська", ru: "Русский", by: "Беларуская",
    pl: "Polski", cz: "Čeština", sk: "Slovenčina",
    si: "Slovenščina", hr: "Hrvatski", rs: "Српски", mk: "Македонски",
    bg: "Български", gr: "Ελληνικά", tr: "Türkçe", hu: "Magyar",
    ro: "Română", al: "Shqip",
    de: "Deutsch", fr: "Français", es: "Español", latam: "Español (Latinoamérica)",
    it: "Italiano", pt: "Português", br: "Português (Brasil)",
    nl: "Nederlands",
    se: "Svenska", no: "Norsk", da: "Dansk", fi: "Suomi",
    is: "Íslenska", ie: "Gaeilge",
    lt: "Lietuvių", lv: "Latviešu", et: "Eesti", kz: "Қазақша",
    jp: "日本語", cn: "中文", kr: "한국어",
    in: "हिन्दी", th: "ไทย", vn: "Tiếng Việt",
    il: "עברית", ara: "العربية", ir: "فارسی",
    eo: "Esperanto"
}

/// The display name for a layout code: its endonym when the table has one,
/// base.lst's title when it does not, the uppercased code as the last
/// resort. One truth for the header chip and the chooser rows alike.
function displayName(code, fallbackTitle) {
    var key = String(code || "").trim()
    if (key !== "" && Object.prototype.hasOwnProperty.call(ENDONYMS, key))
        return ENDONYMS[key]
    var title = String(fallbackTitle || "").trim()
    if (title !== "") return title
    return key !== "" ? key.toUpperCase() : ""
}

// Group order is the menu order: xkb group indices are the seat's truth,
// and the entries carry their group so the click switches by index —
// codes can repeat across variants ("us,us") and must never merge.
// Titles go through displayName: the endonym table first, base.lst and
// the bare code behind it.
function menuEntries(layoutCodes, titles, activeIndex) {
    var out = []
    var codes = Array.isArray(layoutCodes) ? layoutCodes : []
    for (var i = 0; i < codes.length; i++) {
        var code = String(codes[i])
        var title = titles ? titles[code] : ""
        out.push({
            group: i,
            code: code,
            title: displayName(code, title),
            active: i === activeIndex
        })
    }
    return out
}
