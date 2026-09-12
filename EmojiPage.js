.pragma library

// Pure logic behind the panel's own emoji page (ticket 24). The suites
// cannot load QML (decisions §36), so everything the page computes — the
// tab model over the catalogue's groups, the group slice the grid shows,
// the step-3 rule that turns one intercepted keyboard cap into the next
// search query, and the column arithmetic that fits the grid to the page —
// lives here, where tests/emoji-page.qml can drive it. Ranked search itself
// is the catalogue's (EmojiCatalog.js); delivery is step 4.

// Tab labels shorten at the ampersand: nine full group names cannot share
// one card-sized row of chips, and the full name stays one tab away from
// the title it abbreviates ("Smileys & Emotion" -> "Smileys"). A group
// without an ampersand ("Flags") is already short enough to stand as is.
function tabLabel(group) {
    var text = String(group === undefined || group === null ? "" : group)
    var at = text.indexOf(" &")
    return at > 0 ? text.slice(0, at) : text
}

// One tab per catalogue group, in catalogue order — emoji-test.txt's own
// order, which the grid's slice order then follows.
function tabs(groups) {
    var out = []
    for (var i = 0; i < groups.length; i++)
        out.push({ value: groups[i], label: tabLabel(groups[i]) })
    return out
}

// The grid shows one group's slice, catalogue order kept. Skin-tone
// variants sit directly beside their base in the catalogue, so they land
// next to it here as their own cells — no re-linking needed.
function groupEntries(entries, group) {
    var out = []
    for (var i = 0; i < entries.length; i++) {
        if (entries[i].group === group) out.push(entries[i])
    }
    return out
}

// Step 3's seam: one intercepted keyboard cap applied to the standing
// query. The keyboard resolves what a cap draws (Layout.resolvedTypedChar —
// what you see is what the search gets, in every configured layout and
// group) and names the action; this only updates the string.
//
// "char" appends the resolved character verbatim — case included, because
// the field shows what was typed and search() lowercases its side. "space"
// appends the separator (the space cap arrives as "char" with " " — its
// drawn character — so the action exists for the seam, not because the
// keyboard needs a special arm). "backspace" deletes the last code unit;
// the query is typed text, not composed input. Every other action — Enter,
// Tab, the arrows, anything swallowed — changes nothing. Backspace past
// empty stays empty.
function nextQuery(query, action, text) {
    var q = String(query === undefined || query === null ? "" : query)
    if (action === "backspace")
        return q.slice(0, Math.max(0, q.length - 1))
    if (action === "char")
        return q + String(text === undefined || text === null ? "" : text)
    if (action === "space")
        return q + " "
    return q
}

// Widest column count whose cells fit width: a column's pitch is cell + gap,
// so n columns need n*pitch - gap. Clamped to [1, maximum] — a narrow output
// narrows the grid instead of spilling cells past the page edge, and a wide
// one never widens the page past its natural column count.
function columnsFor(width, cell, gap, maximum) {
    var w = isFinite(width) ? width : 0
    var c = isFinite(cell) && cell > 0 ? cell : 0
    var g = isFinite(gap) && gap >= 0 ? gap : 0
    if (w <= 0 || c <= 0) return 1
    var fit = Math.floor((w + g) / (c + g))
    var cap = isFinite(maximum) && maximum >= 1 ? maximum : fit
    return Math.max(1, Math.min(fit, cap))
}
