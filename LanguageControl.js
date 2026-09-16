.pragma library

// The header language control's three shapes, and the chooser menu's
// entries. Pure data: the panel wires these to the layout facts
// Keyboard.qml already holds (layoutCodes, layoutTitles, groupCursor,
// switchKeyboards) and to the same absolute-group move stepLayout has
// always issued.
//
// Shapes (owner's 2026-09-13 call, ticket 35):
//  - one layout: hidden. Nothing to switch; an inert chip is noise and a
//    false affordance.
//  - two layouts: direct. Click toggles to the other group — the shape
//    the panel always had, unchanged.
//  - three or more: menu. Click opens the chooser; picking an entry
//    moves every device in the switch set to that ABSOLUTE group.
// A count >= 2 with an empty switch set is visible but disabled: hidden
// means "nothing to switch", not "nobody safe to move" — the
// pullLayoutsFromCompositor caveat about guessed devices keeps its grey
// signal. The two facts are deliberately separate inputs so the QML never
// recombines them differently on the fill vs the click path.

function controlState(layoutCount, switchSetLength) {
    var count = typeof layoutCount === "number" ? layoutCount : 0
    if (count < 2) return "hidden"
    return switchSetLength > 0 ? (count > 2 ? "menu" : "direct") : "disabled"
}

// Group order is the menu order: xkb group indices are the seat's truth,
// and the entries carry their group so the click switches by index —
// codes can repeat across variants ("us,us") and must never merge.
function menuEntries(layoutCodes, titles, activeIndex) {
    var out = []
    var codes = Array.isArray(layoutCodes) ? layoutCodes : []
    for (var i = 0; i < codes.length; i++) {
        var code = String(codes[i])
        var title = titles ? titles[code] : ""
        out.push({
            group: i,
            code: code,
            title: title ? String(title) : code.toUpperCase(),
            active: i === activeIndex
        })
    }
    return out
}
