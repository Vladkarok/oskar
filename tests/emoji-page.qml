// Pure logic behind the panel's own emoji page (ticket 24, steps 2–3). Not
// a product seam: loads EmojiPage.js and the catalogue the way the page
// does, with no compositor (decisions §36) — the tab model and group slice
// the grid shows, and the step-3 rule that turns one intercepted keyboard
// cap into the next search query. The geometry half restates the page's
// own width/height formulas beside SettingsPlacement — the same
// carried-by-hand duplication the settings-placement suite records for the
// settings card; a change to the page's chrome has to be carried here.
import QtQml
import "../EmojiCatalog.js" as Catalog
import "../EmojiPage.js" as Page
import "../SettingsPlacement.js" as Place
import "harness.js" as T

QtObject {
    // The page's chrome restated: page margins 2x10, the header row's 28,
    // a 1px hairline, one 24-high icon-tab row, and 7-space gaps between the
    // column's four children.
    // Only the grid cells carry the size preset's scale.
    function naturalPageHeight(cell, gap, rows) {
        var chrome = 2 * 10 + 28 + 1 + 24 + 3 * 7
        return chrome + rows * (cell + gap) - gap
    }

    function naturalPageWidth(cell, gap, columns) {
        return 2 * 10 + columns * cell + (columns - 1) * gap
    }

    Component.onCompleted: {
        var entries = Catalog.entries()
        var groups = Catalog.groups()

        T.test("tabs follow groups() in catalogue order", function () {
            var tabs = Page.tabs(groups)
            T.equal(tabs.length, groups.length)
            var inOrder = true
            for (var i = 0; i < groups.length; i++) {
                if (tabs[i].value !== groups[i]) inOrder = false
            }
            T.equal(inOrder, true)
            T.equal(tabs[0].value, "Smileys & Emotion")
            T.equal(tabs[tabs.length - 1].value, "Flags")
        })

        T.test("every category has a stable representative emoji", function () {
            T.equal(Page.categoryIcon("Smileys & Emotion"), "😀")
            T.equal(Page.categoryIcon("People & Body"), "👋")
            T.equal(Page.categoryIcon("Flags"), "🏁")
            var tabs = Page.tabs(groups)
            for (var i = 0; i < tabs.length; i++) {
                if (tabs[i].label === "•") {
                    T.fail("group " + tabs[i].value + " has no icon")
                    return
                }
            }
            T.equal(true, true)
        })

        T.test("no group is empty and tone families occupy one base tile", function () {
            var total = 0
            for (var i = 0; i < groups.length; i++) {
                var slice = Page.groupEntries(entries, groups[i])
                if (slice.length === 0) {
                    T.fail("group " + groups[i] + " is empty")
                    return
                }
                total += slice.length
            }
            T.equal(total < entries.length, true)
            T.equal(total, 2026)
        })

        T.test("simple, ZWJ and multi-person families collapse and resolve exactly", function () {
            var slice = Page.groupEntries(entries, "People & Body")
            function named(name) {
                for (var i = 0; i < slice.length; i++)
                    if (slice[i].name === name) return slice[i]
                return null
            }
            var thumbs = named("thumbs up")
            T.equal(thumbs !== null, true)
            T.equal(named("thumbs up: light skin tone"), null)
            T.equal(Page.entryForTone(thumbs, "🏽", entries).emoji, "👍🏽")
            var beard = named("woman: beard")
            T.equal(Page.entryForTone(beard, "🏿", entries).emoji, "🧔🏿‍♀️")
            var people = named("people holding hands")
            T.equal(Page.entryForTone(people, "🏼", entries).emoji,
                "🧑🏼‍🤝‍🧑🏼")
            T.equal(Page.entryForTone(people, "", entries).emoji,
                people.emoji)
        })

        T.test("the selector exposes default plus five standard tones", function () {
            T.equal(Page.SKIN_TONES.length, 6)
            T.equal(Page.SKIN_TONES[0].value, "")
            var seen = {}
            for (var i = 0; i < Page.SKIN_TONES.length; i++) {
                T.equal(Page.SKIN_TONES[i].label !== "", true)
                T.equal(seen[Page.SKIN_TONES[i].value] === true, false)
                seen[Page.SKIN_TONES[i].value] = true
                T.equal(Page.toneHand(Page.SKIN_TONES[i].value),
                    Page.SKIN_TONES[i].hand)
            }
        })

        T.test("unsupported flags and semantically fixed sequences are unchanged", function () {
            var flag = Catalog.search("flag ukraine", 0)[0]
            T.equal(Page.entryForTone(flag, "🏿", entries).emoji, flag.emoji)
            var fixed = null
            for (var i = 0; i < entries.length; i++) {
                if (entries[i].emoji === "🫱🏻‍🫲🏼") {
                    fixed = entries[i]
                    break
                }
            }
            T.equal(fixed !== null, true)
            T.equal(Page.entryForTone(fixed, "🏻", entries).emoji, fixed.emoji)
        })

        T.test("a Recent tile repeats its exact stored sequence under a selected tone (R1)", function () {
            // The scenario the second review reproduced: a default 👍 that
            // lands in Recent (not Most Frequent), a dark tone selected, and
            // the history tile clicked. The grid's one delegate decides the
            // tone flag by the tile's origin — appliesTone with the same two
            // facts that chose its model — so the stored 👍 delivers as 👍,
            // never retone to 👍🏿. On the old code the delegate passed a
            // hardcoded true and this delivered the wrong sequence.
            var records = [
                { emoji: "😀", count: 5, lastUsed: 2 },
                { emoji: "👍", count: 1, lastUsed: 1 }
            ]
            var sections = Page.usageSections(records, 1)
            T.equal(sections.frequent.length, 1)
            T.equal(sections.frequent[0].emoji, "😀")
            T.equal(sections.recent.length, 1)
            T.equal(sections.recent[0].emoji, "👍")
            var flag = Page.appliesTone(false, "__usage__")
            T.equal(flag, false)
            var delivered = flag
                ? Page.entryForTone(sections.recent[0], "🏿", entries)
                : sections.recent[0]
            T.equal(delivered.emoji, "👍")
        })

        T.test("catalogue and search tiles still resolve the selected tone", function () {
            // A group slice and a standing search both show catalogue bases;
            // their picks resolve the selector exactly as before R1.
            T.equal(Page.appliesTone(false, "People & Body"), true)
            T.equal(Page.appliesTone(false, "Flags"), true)
            T.equal(Page.appliesTone(true, "__usage__"), true)
            T.equal(Page.appliesTone(true, "Flags"), true)
        })

        T.test("a paste into the search is collapsed, bounded and refuses nothingness", function () {
            // R2 review follow-up: the clipboard serves whatever it holds;
            // the query takes typed text only.
            T.equal(Page.searchPasteText("thumbs up", 64), "thumbs up")
            T.equal(Page.searchPasteText("flag\n ukraine ", 64), "flag ukraine")
            T.equal(Page.searchPasteText("  \n\t ", 64), "")
            T.equal(Page.searchPasteText("", 64), "")
            T.equal(Page.searchPasteText(null, 64), "")
            T.equal(Page.searchPasteText("a very long clipboard payload", 8),
                "a very l")
            T.equal(Page.searchPasteText("anything", 0), "")
            T.equal(Page.searchPasteText("anything", -3), "")
        })

        T.test("search collapses variants after ranking and still fills its limit", function () {
            var results = Page.visibleEntries(Catalog.search("hand", 0), entries, 8)
            T.equal(results.length, 8)
            var seen = {}
            for (var i = 0; i < results.length; i++) {
                var key = Page.toneFamilyKey(results[i].emoji)
                T.equal(seen[key] === true, false)
                seen[key] = true
            }
        })

        T.test("appends keep what was typed, verbatim and case included", function () {
            // The field shows what was typed; search() lowercases its own
            // side (§37), so the seam must not.
            T.equal(Page.nextQuery("", "char", "a"), "a")
            T.equal(Page.nextQuery("Fl", "char", "a"), "Fla")
            T.equal(Page.nextQuery("", "char", "3"), "3")
            T.equal(Page.nextQuery("", "char", "#"), "#")
            // ua-group characters append verbatim: what the cap drew is
            // what the query holds, whatever the group.
            T.equal(Page.nextQuery("", "char", "й"), "й")
            T.equal(Page.nextQuery("й", "char", "ї"), "йї")
        })

        T.test("backspace deletes the last code unit, down to empty and no further", function () {
            var q = "thumbs"
            for (var i = 0; i < 7; i++) q = Page.nextQuery(q, "backspace", "")
            T.equal(q, "")
            T.equal(Page.nextQuery("", "backspace", ""), "")
            T.equal(Page.nextQuery(null, "backspace", ""), "")
        })

        T.test("space appends the separator, even leading", function () {
            T.equal(Page.nextQuery("", "space", ""), " ")
            T.equal(Page.nextQuery(" ", "char", "b"), " b")
            T.equal(Page.nextQuery("thumbs", "space", ""), "thumbs ")
        })

        T.test("actions that are not text change nothing", function () {
            T.equal(Page.nextQuery("abc", "enter", ""), "abc")
            T.equal(Page.nextQuery("abc", "nosuch", ""), "abc")
            T.equal(Page.nextQuery("abc", "escape", ""), "abc")
        })

        T.test("a leading space is a term separator, and searching still works", function () {
            // The space a query picks up at the start is a separator, not a
            // term: search() trims, so the answers match the plain query's.
            var plain = Catalog.search("thumbs", 0)
            var led = Catalog.search(" thumbs", 0)
            T.equal(led.length, plain.length)
            T.equal(led[0].name, plain[0].name)
            // The seam builds that query: a space first, then the letters.
            var q = Page.nextQuery("", "space", "")
            q = Page.nextQuery(q, "char", "t")
            q = Page.nextQuery(q, "char", "h")
            T.equal(q, " th")
            T.equal(Catalog.search(q, 0).length > 0, true)
            // A composed query typed through the seam — "flag", separator,
            // "ukraine" — ranks the flag itself first (§37's capitalised
            // shape). The term must be a real word of the name: "ua" is no
            // substring of "ukraine" and would match nothing there.
            var typed = ""
            var keys = [["char", "f"], ["char", "l"], ["char", "a"],
                ["char", "g"], ["space", ""], ["char", "u"], ["char", "k"],
                ["char", "r"], ["char", "a"], ["char", "i"], ["char", "n"],
                ["char", "e"]]
            for (var i = 0; i < keys.length; i++)
                typed = Page.nextQuery(typed, keys[i][0], keys[i][1])
            T.equal(typed, "flag ukraine")
            var results = Catalog.search(typed, 0)
            T.equal(results.length > 0, true)
            T.equal(results[0].name, "flag: Ukraine")
        })

        T.test("a lone separator is not a term: trim before asking search", function () {
            // search answers [] for a termless query — that is
            // found-nothing, not not-searching. The page's `searching`
            // rule trims before it asks, so a query of bare separators
            // keeps the group slice instead of flipping to that empty
            // answer. The boundary behaviour the rule rests on:
            T.equal(Catalog.search(" ", 0).length, 0)
            T.equal(Catalog.search("   ", 0).length, 0)
            // ...while one real term past the separator finds things.
            T.equal(Catalog.search(" " + "thumbs", 0).length > 0, true)
        })

        T.test("column count fits the width, capped, never below one", function () {
            var cell = 42, gap = 4
            // Degenerate inputs land on one column, not zero or negative.
            T.equal(Page.columnsFor(0, cell, gap, 8), 1)
            T.equal(Page.columnsFor(200, 0, gap, 8), 1)
            // n columns need n*(cell+gap)-gap: 8 columns need 364.
            T.equal(Page.columnsFor(363, cell, gap, 8), 7)
            T.equal(Page.columnsFor(364, cell, gap, 8), 8)
            // A wider host never widens the page past its natural count.
            T.equal(Page.columnsFor(4000, cell, gap, 8), 8)
        })

        T.test("page sizes request independent M L XL capacities", function () {
            T.deepEqual(Page.pageCapacity("medium"), { columns: 8, rows: 4 })
            T.deepEqual(Page.pageCapacity("large"), { columns: 10, rows: 6 })
            T.deepEqual(Page.pageCapacity("x-large"), { columns: 12, rows: 8 })
            T.deepEqual(Page.pageCapacity("bad"), { columns: 8, rows: 4 })
        })

        T.test("usage chrome is direct arithmetic, not GridView geometry", function () {
            T.equal(Page.usageChromeHeight(false, 18, 5, 4), 0)
            T.equal(Page.usageChromeHeight(true, 18, 5, 4), 59)
        })

        T.test("only known Chromium-family classes take Unicode entry", function () {
            T.equal(Page.needsUnicodeEntry("chromium"), true)
            T.equal(Page.needsUnicodeEntry("brave-browser"), true)
            T.equal(Page.needsUnicodeEntry("com.openai.codex"), true)
            T.equal(Page.needsUnicodeEntry("chatgpt"), true)
            T.equal(Page.needsUnicodeEntry("Claude"), true)
            // Owner acceptance proved ZapZap already handles the ordinary
            // transient-keymap route correctly; do not reroute it merely
            // because its engine may be Chromium-derived.
            T.equal(Page.needsUnicodeEntry("ZapZap"), false)
            T.equal(Page.needsUnicodeEntry("foot"), false)
            T.equal(Page.needsUnicodeEntry("x11cat"), false)
        })

        T.test("successful usage ranks, deduplicates and evicts deterministically", function () {
            var records = []
            records = Page.usageAfterSuccess(records, "😁")
            records = Page.usageAfterSuccess(records, "😛")
            records = Page.usageAfterSuccess(records, "😁")
            T.deepEqual(records, [
                { emoji: "😁", count: 2, lastUsed: 3 },
                { emoji: "😛", count: 1, lastUsed: 2 }
            ])
            var recordSections = Page.usageSections(records, 1)
            var sections = {
                frequent: Page.recordsToEntries(recordSections.frequent, entries),
                recent: Page.recordsToEntries(recordSections.recent, entries)
            }
            T.equal(sections.frequent[0].emoji, "😁")
            T.equal(sections.recent[0].emoji, "😛")
            var seen = {}
            for (var f = 0; f < sections.frequent.length; f++)
                seen[sections.frequent[f].emoji] = true
            for (var r = 0; r < sections.recent.length; r++)
                T.equal(seen[sections.recent[r].emoji] === true, false)

            records = []
            for (var i = 0; i < 64; i++)
                records.push({ emoji: "e" + i, count: i === 0 ? 2 : 1,
                    lastUsed: i + 1 })
            records = Page.usageAfterSuccess(records, "new")
            T.equal(records.length, 64)
            T.equal(records.some(function (x) { return x.emoji === "e1" }), false)
            T.equal(records.some(function (x) { return x.emoji === "e0" }), true)
            T.equal(records.some(function (x) { return x.emoji === "new" }), true)

            records = Page.usageAfterSuccess([], "👍🏻")
            records = Page.usageAfterSuccess(records, "👍🏿")
            T.equal(records.length, 2)
            T.equal(records[0].emoji, "👍🏻")
            T.equal(records[1].emoji, "👍🏿")
        })

        T.test("the usage view opens on a snapshot, not the live records", function () {
            // Ticket 34: the open snapshot reflects the records as they
            // stand at that moment and nothing later. The copy is deep —
            // aliasing is the classic bug a snapshot can hide, so a
            // mutated record or a pushed one must not leak in.
            var records = [
                { emoji: "😀", count: 3, lastUsed: 1 },
                { emoji: "👍", count: 1, lastUsed: 2 }
            ]
            var snapshot = Page.usageViewOnOpen(records)
            T.deepEqual(snapshot, records)
            T.equal(snapshot === records, false)
            records[0].count = 99
            records.push({ emoji: "😛", count: 7, lastUsed: 3 })
            T.equal(snapshot.length, 2)
            T.equal(snapshot[0].count, 3)
        })

        T.test("re-entering the usage group re-snapshots; leaving it keeps the view", function () {
            // The owner's fruits-and-back round trip: picks accumulate in
            // the store while another category shows, the return hands the
            // view the re-snapshot, and leaving again changes nothing.
            var records = [{ emoji: "😀", count: 1, lastUsed: 1 }]
            var snapshot = Page.usageViewOnOpen(records)
            records = Page.usageAfterSuccess(records, "😛")
            records = Page.usageAfterSuccess(records, "😛")
            var kept = Page.usageViewOnGroupChange("Food & Drink", records,
                snapshot)
            T.equal(kept === snapshot, true)
            var reentered = Page.usageViewOnGroupChange("__usage__", records,
                snapshot)
            T.deepEqual(reentered, records)
            T.equal(reentered === snapshot, false)
        })

        T.test("five picks under the usage view move no tile", function () {
            // The exact report that opened ticket 34: a new emoji clicked
            // five times climbs the frequency ranking live and lands under
            // the pointer on the last clicks. No reopen and no group
            // change means no refresh call at all — the view derives from
            // the untouched snapshot while the store re-ranks beneath it.
            var records = [
                { emoji: "😀", count: 5, lastUsed: 2 },
                { emoji: "👍", count: 1, lastUsed: 3 }
            ]
            var snapshot = Page.usageViewOnOpen(records)
            var before = Page.usageSections(snapshot, 1)
            T.equal(before.frequent[0].emoji, "😀")
            T.equal(before.recent[0].emoji, "👍")
            for (var i = 0; i < 5; i++)
                records = Page.usageAfterSuccess(records, "👍")
            // The store itself re-ranked (its per-delivery update is
            // untouched)...
            var store = Page.usageSections(records, 1)
            T.equal(store.frequent[0].emoji, "👍")
            // ...but the snapshot's sections are byte-identical.
            T.deepEqual(Page.usageSections(snapshot, 1), before)
        })

        T.test("an empty store snapshots to empty sections", function () {
            // The empty-store path is unchanged: the snapshot of nothing
            // is nothing — no usage header, no chrome.
            var snapshot = Page.usageViewOnOpen([])
            T.deepEqual(snapshot, [])
            var sections = Page.usageSections(snapshot, 1)
            T.equal(sections.frequent.length, 0)
            T.equal(sections.recent.length, 0)
        })

        T.test("the page stays clear of the keyboard band at every size preset", function () {
            var output = { x: 0, y: 0, w: 1280, h: 800 }
            var presets = Page.PAGE_SIZES
            var tried = 0
            for (var preset in presets) {
                var cell = 42
                var gap = 4
                var capacity = Page.pageCapacity(preset)
                var natural = {
                    w: naturalPageWidth(cell, gap, capacity.columns),
                    h: naturalPageHeight(cell, gap, capacity.rows)
                }
                // The suite's recorded medium band, scaled as the keyboard's
                // card is by the preset.
                var band = Place.overlayBand("docked", output,
                    { x: 0, y: 0, w: 1280, h: 240 })
                var fitted = Place.fitSizeInLeftover(output, band, natural, 8)
                // Width never needs clamping on this output: the grid keeps
                // all eight natural columns at every preset.
                var pos = Place.centreInLeftover(output, band, fitted)
                // The never-covers-keys rule, arithmetic not aspiration.
                T.equal(pos.y + fitted.h <= band.y, true)
                tried += 1
            }
            T.equal(tried, 3)
        })

        T.test("a small output narrows the grid and still clears the band", function () {
            // Portrait-shaped output, XL keys: the width clamp bites, the
            // column count shrinks with it, and the height clamps into the
            // leftover (the grid scrolls the difference).
            var output = { x: 0, y: 0, w: 480, h: 640 }
            var cell = 42
            var gap = 4
            var capacity = Page.pageCapacity("x-large")
            var natural = {
                w: naturalPageWidth(cell, gap, capacity.columns),
                h: naturalPageHeight(cell, gap, capacity.rows)
            }
            var maxPageWidth = Math.max(0, output.w - 2 * 6)
            var width = Math.min(natural.w, maxPageWidth)
            T.equal(width < natural.w, true)
            var columns = Page.columnsFor(width - 2 * 10, cell, gap,
                capacity.columns)
            T.equal(columns < capacity.columns, true)
            T.equal(columns >= 1, true)
            var band = Place.overlayBand("docked", output,
                { x: 0, y: 0, w: 480, h: 240 })
            var fitted = Place.fitSizeInLeftover(output, band, natural, 8)
            var pos = Place.centreInLeftover(output, band, fitted)
            T.equal(pos.y + fitted.h <= band.y, true)
            // The clamp that makes the grid scroll is the same one that
            // keeps the band clear.
            T.equal(fitted.h < natural.h, true)
        })

        // ---- ticket 40: field contracts — the page's builders vs the
        // ---- delegates' reads ----
        //
        // The tab delegate reads modelData.value/modelData.label (tab 429
        // of EmojiPage.qml), the grid delegate reads modelData.emoji and
        // modelData.name off whatever its model carries, and the usage
        // sections read emoji/count/lastUsed off the store's records. A
        // rename in any builder must break this suite, not the page.
        T.test("the search placeholder speaks the active layout's language", function () {
            // The owner's 2026-09-13 call: the word under the field follows
            // the layout he types in — Пошук on ua, Поиск on ru, Search
            // elsewhere; an unknown or missing code falls through rather
            // than guess.
            T.equal(Page.searchPlaceholder("ua"), "Пошук")
            T.equal(Page.searchPlaceholder("ru"), "Поиск")
            T.equal(Page.searchPlaceholder("us"), "Search")
            T.equal(Page.searchPlaceholder("de"), "Search")
            T.equal(Page.searchPlaceholder(""), "Search")
            T.equal(Page.searchPlaceholder(undefined), "Search")
        })
        T.test("tab entries carry exactly the two fields the tab delegate reads", function () {
            var tabs = Page.tabs(Catalog.groups())
            T.equal(tabs.length, groups.length)
            for (var i = 0; i < tabs.length; i++) {
                T.deepEqual(Object.keys(tabs[i]).sort(), ["label", "value"])
                T.equal(typeof tabs[i].value, "string")
                T.equal(tabs[i].value.length > 0, true)
                T.equal(typeof tabs[i].label, "string")
                T.equal(tabs[i].label.length > 0, true)
            }
        })

        T.test("grid slices are catalogue entries; usage records keep their three fields", function () {
            var slice = Page.groupEntries(Catalog.entries(), groups[0])
            T.equal(slice.length > 0, true)
            for (var i = 0; i < slice.length; i++) {
                var keys = Object.keys(slice[i]).sort().join(",")
                if (keys !== "base,emoji,group,keywords,name,ru,uk,variants") {
                    T.fail("grid tile " + i + " carries " + keys)
                    return
                }
                if (typeof slice[i].emoji !== "string"
                        || typeof slice[i].name !== "string") {
                    T.fail("grid tile " + i + " lost emoji/name")
                    return
                }
            }
            var records = Page.usageAfterSuccess([], "\u{1F600}")
            records = Page.usageAfterSuccess(records, "\u{1F602}")
            T.deepEqual(Object.keys(records[0]).sort(),
                ["count", "emoji", "lastUsed"])
            var snapshot = Page.usageViewOnOpen(records)
            T.deepEqual(Object.keys(snapshot[0]).sort(),
                ["count", "emoji", "lastUsed"])
            var sectioned = Page.usageSections(records, 1)
            T.deepEqual(Object.keys(sectioned.frequent[0]).sort(),
                ["count", "emoji", "lastUsed"])
            T.deepEqual(Object.keys(sectioned.recent[0]).sort(),
                ["count", "emoji", "lastUsed"])
        })

        Qt.exit(T.report("emoji page"))
    }
}
