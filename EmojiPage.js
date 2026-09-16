.pragma library

// Pure logic behind the panel's own emoji page (ticket 24). The suites
// cannot load QML (decisions §36), so everything the page computes — the
// tab model over the catalogue's groups, the group slice the grid shows,
// the step-3 rule that turns one intercepted keyboard cap into the next
// search query, and the column arithmetic that fits the grid to the page —
// lives here, where tests/emoji-page.qml can drive it. Ranked search itself
// is the catalogue's (EmojiCatalog.js); delivery is step 4.

var CATEGORY_ICONS = {
    "Smileys & Emotion": "😀",
    "People & Body": "👋",
    "Animals & Nature": "🐻",
    "Food & Drink": "🍔",
    "Travel & Places": "🚗",
    "Activities": "⚽",
    "Objects": "💡",
    "Symbols": "🔣",
    "Flags": "🏁"
}

var SKIN_TONES = [
    { value: "", label: "Default skin tone", hand: "🖐️" },
    { value: "🏻", label: "Light skin tone", hand: "🖐🏻" },
    { value: "🏼", label: "Medium-light skin tone", hand: "🖐🏼" },
    { value: "🏽", label: "Medium skin tone", hand: "🖐🏽" },
    { value: "🏾", label: "Medium-dark skin tone", hand: "🖐🏾" },
    { value: "🏿", label: "Dark skin tone", hand: "🖐🏿" }
]

function categoryIcon(group) {
    return CATEGORY_ICONS[String(group)] || "•"
}

// One tab per catalogue group, in catalogue order — emoji-test.txt's own
// order, which the grid's slice order then follows.
function tabs(groups) {
    var out = []
    for (var i = 0; i < groups.length; i++)
        out.push({ value: groups[i], label: categoryIcon(groups[i]) })
    return out
}

function hasTone(sequence) {
    return /[\u{1f3fb}-\u{1f3ff}]/u.test(String(sequence || ""))
}

function toneFamilyKey(sequence) {
    return String(sequence || "")
        .replace(/[\u{1f3fb}-\u{1f3ff}]/gu, "")
        .replace(/\ufe0f/g, "")
}

function familyBases(entries) {
    var bases = {}
    for (var i = 0; i < entries.length; i++) {
        if (!hasTone(entries[i].emoji))
            bases[toneFamilyKey(entries[i].emoji)] = entries[i]
    }
    return bases
}

// Collapse every modifier family onto its unmodified catalogue entry. This
// covers modifiers inside ZWJ professions and multi-person sequences, not
// only the generated catalogue's simple trailing-modifier links. A toned
// entry with no unmodified peer is semantically fixed and stays exact.
function visibleEntries(entries, catalog, limit) {
    var bases = familyBases(catalog)
    var seen = {}
    var out = []
    for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var key = toneFamilyKey(entry.emoji)
        var visible = bases[key] || entry
        var identity = visible.emoji
        if (seen[identity]) continue
        seen[identity] = true
        out.push(visible)
        if (limit > 0 && out.length >= limit) break
    }
    return out
}

// Resolve the selected tone to an exact fully-qualified catalogue sequence.
// Multi-person families select the existing same-tone sequence, preserving
// modifier placement around every ZWJ. Unsupported and fixed entries pass
// through unchanged; a modifier is never appended by guesswork.
function entryForTone(entry, tone, catalog) {
    var selected = String(tone || "")
    if (selected === "" || hasTone(entry.emoji)) return entry
    var key = toneFamilyKey(entry.emoji)
    var bases = familyBases(catalog)
    if (!bases[key]) return entry
    var best = null
    var bestModifierCount = -1
    for (var i = 0; i < catalog.length; i++) {
        var candidate = catalog[i]
        if (toneFamilyKey(candidate.emoji) !== key || !hasTone(candidate.emoji))
            continue
        var modifiers = candidate.emoji.match(/[\u{1f3fb}-\u{1f3ff}]/gu) || []
        var exact = modifiers.length > 0
        for (var m = 0; m < modifiers.length; m++) {
            if (modifiers[m] !== selected) { exact = false; break }
        }
        if (exact && modifiers.length > bestModifierCount) {
            best = candidate
            bestModifierCount = modifiers.length
        }
    }
    return best || entry
}

// A grid tile's origin decides whether its pick re-applies the skin tone
// (review R1). Catalogue tiles — a group slice, or search results collapsed
// to their family bases — resolve the selector; usage history repeats its
// exact stored sequence, so a Recent tile that drew 👍 delivers 👍 and not
// 👍🏿. The grid's one delegate serves both models, so it asks here with the
// same two facts that chose its model; the Most Frequent header row passes
// its own false directly.
function appliesTone(searching, activeGroup) {
    return !!searching || String(activeGroup) !== "__usage__"
}

// What a paste may hand the search query (R2 review follow-up): the
// clipboard serves whatever it holds — bytes that are not really text, or
// an entire document — and the query is typed text. Whitespace collapses
// to single separators (the shape search() splits its terms on) and the
// result is capped at `limit` characters; anything that collapses to
// nothing inserts nothing. A query that long matches nothing anyway — the
// bound keeps a huge payload off the UI thread's search.
function searchPasteText(raw, limit) {
    var collapsed = String(raw === undefined || raw === null ? "" : raw)
        .replace(/\s+/g, " ").trim()
    var max = isFinite(limit) && limit > 0 ? Math.floor(limit) : 0
    if (collapsed === "" || max <= 0) return ""
    return collapsed.slice(0, max)
}

function toneHand(tone) {
    for (var i = 0; i < SKIN_TONES.length; i++)
        if (SKIN_TONES[i].value === tone) return SKIN_TONES[i].hand
    return SKIN_TONES[0].hand
}

// The grid shows one group's collapsed slice, catalogue order kept.
function groupEntries(entries, group) {
    var out = []
    for (var i = 0; i < entries.length; i++) {
        if (entries[i].group === group) out.push(entries[i])
    }
    return visibleEntries(out, entries, 0)
}

// Step 3's seam: one intercepted keyboard cap applied to the standing
// query. The keyboard resolves what a cap draws (Layout.charUnderModifiers —
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

// Ticket 42's seam: one PHYSICAL key event, named with the action
// vocabulary nextQuery (and Keyboard.searchInput) already speak — "char",
// "backspace", "escape" — or "" when the key produces nothing. `event` is
// event-shaped (key: the Qt key code, text: the decoded character or ""),
// never a live KeyEvent, so tests/emoji-page.qml drives it with plain
// objects (decisions §36). "char" hands the caller back to event.text
// verbatim — the physical layout's character, Cyrillic included, case
// included, exactly the rule the caps' resolution follows. Control
// payloads never type: Return/Enter (\r), Delete (U+007F) and everything
// below space are "" — Enter picking the first result stays out (the
// ticket's nice-to-have), and a key with no text (modifiers, arrows, Tab,
// function keys) has nothing to append. Key codes are matched before text
// so Escape's or Backspace's own control payload cannot be mistaken for
// a character. The literals are Qt.Key_Escape (0x01000000) and
// Qt.Key_Backspace (0x01000003). A chord is not typing: Ctrl (0x04000000),
// Alt (0x08000000) and Meta/Super (0x10000000) all produce nothing — while
// armed the layer holds the keyboard and the chord cannot reach the app
// anyway, but it must not leave a stray character in the query (the
// ticket-42 review caught the first cut gating 0x08000000 as Meta and
// letting Super chords through). AltGr is untouched: on the Wayland stack
// it arrives as GroupSwitchModifier (0x40000000), so é/§ still type.
// Shift is typing — "A" is what was typed. Whether an event reaches here
// at all — the armed gate, the scope's focus — is the page's QML, not
// this rule.
function searchKeyAction(event) {
    var key = event ? (event.key || 0) : 0
    var modifiers = event ? (event.modifiers || 0) : 0
    if ((modifiers & 0x04000000) || (modifiers & 0x08000000)
            || (modifiers & 0x10000000)) return ""
    if (key === 0x01000000) return "escape"
    if (key === 0x01000003) return "backspace"
    var text = event && typeof event.text === "string" ? event.text : ""
    if (text.length === 0) return ""
    var code = text.charCodeAt(0)
    if (code < 32 || code === 127) return ""
    return "char"
}

// The search field's placeholder word, in the ACTIVE LAYOUT's language
// (the owner's 2026-09-13 call): ua draws Пошук, ru Поиск, everything
// else the English Search. Keyed by the xkb layout CODE the panel already
// knows, so a custom code falls through to English rather than guessing.
function searchPlaceholder(layoutCode) {
    var code = String(layoutCode || "").toLowerCase()
    if (code === "ua") return "Пошук"
    if (code === "ru") return "Поиск"
    return "Search"
}

// The tone picker's names, localized (ticket 52): SKIN_TONES keeps its
// English label as the data fallback (the field contract is pinned to
// value/label/hand), and this maps each tone VALUE to its UiStrings id —
// the picker draws tr(toneNameId(value), lang). An unknown value answers
// "" and the picker falls back to the table's own label rather than
// asking the string module for an id it never had.
function toneNameId(value) {
    var tone = String(value || "")
    if (tone === "") return "emoji.tone.default"
    if (tone === "🏻") return "emoji.tone.light"
    if (tone === "🏼") return "emoji.tone.mediumLight"
    if (tone === "🏽") return "emoji.tone.medium"
    if (tone === "🏾") return "emoji.tone.mediumDark"
    if (tone === "🏿") return "emoji.tone.dark"
    return ""
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

var PAGE_SIZES = {
    medium: { columns: 8, rows: 4 },
    large: { columns: 10, rows: 6 },
    "x-large": { columns: 12, rows: 8 }
}

function pageCapacity(size) {
    return PAGE_SIZES[size] || PAGE_SIZES.medium
}

// The frequent row is one of the preset's emoji rows. Its two labels, three
// Column gaps and enlarged separator are extra chrome; compute them without
// reading GridView.header geometry (that creates a QML binding cycle).
function usageChromeHeight(hasUsage, lineHeight, spacing, gap) {
    if (!hasUsage) return 0
    return Math.max(0, lineHeight) * 2 + Math.max(0, spacing) * 3
        + Math.max(0, gap) * 2
}

function needsUnicodeEntry(clientClass) {
    var name = String(clientClass || "").toLowerCase()
    return /(chrom|chrome|brave|edge|electron|codex|chatgpt|openai|claude|slack|discord)/.test(name)
}

function usageAfterSuccess(records, emoji) {
    var out = []
    var sequence = 0
    var found = false
    for (var s = 0; s < records.length; s++)
        sequence = Math.max(sequence, records[s].lastUsed)
    for (var i = 0; i < records.length; i++) {
        var record = records[i]
        if (record.emoji === emoji) {
            out.push({ emoji: record.emoji, count: record.count + 1,
                lastUsed: sequence + 1 })
            found = true
        } else {
            out.push({ emoji: record.emoji, count: record.count,
                lastUsed: record.lastUsed })
        }
    }
    if (found) return out
    if (out.length >= 64) {
        out.sort(function (a, b) {
            return a.count - b.count || a.lastUsed - b.lastUsed
                || (a.emoji < b.emoji ? -1 : a.emoji > b.emoji ? 1 : 0)
        })
        out.shift()
    }
    out.push({ emoji: emoji, count: 1, lastUsed: sequence + 1 })
    return out
}

// Ticket 34: the usage category renders a snapshot of the records, taken
// when the view is entered and only then — positional stability while
// clicking beats live re-ranking. The store stays live (its per-delivery
// update is untouched, decisions §44); a pick's evidence appears at the
// next entry. The copy is deep: no record may alias the store's, or a
// later success would leak into a view that promised not to move.
function usageViewOnOpen(records) {
    var out = []
    for (var i = 0; i < records.length; i++)
        out.push({ emoji: records[i].emoji, count: records[i].count,
            lastUsed: records[i].lastUsed })
    return out
}

// A group change re-snapshots only on re-entry into the usage category;
// every other switch keeps the standing snapshot (nothing reorders while
// another category shows). The page calls this from its one group-change
// hook and stays dumb about the rule.
function usageViewOnGroupChange(newGroup, records, snapshot) {
    return String(newGroup) === "__usage__"
        ? usageViewOnOpen(records) : snapshot
}

function usageSections(records, columns) {
    var frequent = records.slice().sort(function (a, b) {
        return b.count - a.count || b.lastUsed - a.lastUsed
            || (a.emoji < b.emoji ? -1 : a.emoji > b.emoji ? 1 : 0)
    }).slice(0, Math.max(1, columns))
    var used = []
    for (var i = 0; i < frequent.length; i++) used.push(frequent[i].emoji)
    var recent = records.filter(function (record) {
        return used.indexOf(record.emoji) === -1
    }).sort(function (a, b) {
        return b.lastUsed - a.lastUsed
            || (a.emoji < b.emoji ? -1 : a.emoji > b.emoji ? 1 : 0)
    })
    return { frequent: frequent, recent: recent }
}

function recordsToEntries(records, entries) {
    var byEmoji = {}
    for (var i = 0; i < entries.length; i++) byEmoji[entries[i].emoji] = entries[i]
    var out = []
    for (var j = 0; j < records.length; j++) {
        var entry = byEmoji[records[j].emoji]
        if (entry) out.push(entry)
    }
    return out
}
