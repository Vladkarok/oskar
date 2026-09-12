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
import "../Config.js" as Config
import "../SettingsPlacement.js" as Place
import "harness.js" as T

QtObject {
    // The page's chrome restated: page margins 2x10, the header row's 28,
    // a 1px hairline, the tabs' two recorded chip rows (24-high chips on a
    // 7-space gap), and 7-space gaps between the column's four children.
    // Only the grid cells carry the size preset's scale.
    function naturalPageHeight(cell, gap) {
        var chrome = 2 * 10 + 28 + 1 + (2 * 24 + 7) + 3 * 7
        return chrome + 4 * (cell + gap) - gap
    }

    function naturalPageWidth(cell, gap) {
        return 2 * 10 + 8 * cell + 7 * gap
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

        T.test("tab labels shorten at the ampersand and keep bare names", function () {
            T.equal(Page.tabLabel("Smileys & Emotion"), "Smileys")
            T.equal(Page.tabLabel("Food & Drink"), "Food")
            T.equal(Page.tabLabel("Flags"), "Flags")
            T.equal(Page.tabLabel("Activities"), "Activities")
            T.equal(Page.tabLabel(""), "")
            var tabs = Page.tabs(groups)
            for (var i = 0; i < tabs.length; i++) {
                if (tabs[i].label.indexOf(" ") >= 0) {
                    T.fail("label " + tabs[i].label + " did not shorten")
                    return
                }
            }
            T.equal(true, true)
        })

        T.test("no group is an empty tab, and the slices reassemble the catalogue", function () {
            var total = 0
            for (var i = 0; i < groups.length; i++) {
                var slice = Page.groupEntries(entries, groups[i])
                if (slice.length === 0) {
                    T.fail("group " + groups[i] + " is empty")
                    return
                }
                total += slice.length
            }
            T.equal(total, entries.length)
            // 3781 entries, none lost between the tabs and the grid.
            T.equal(total, 3781)
        })

        T.test("variants sit beside their base inside the group slice", function () {
            // Skin tones render as their own cells next to the base because
            // they already do in the catalogue; the slice must keep them so.
            var slice = Page.groupEntries(entries, "People & Body")
            var at = -1
            for (var i = 0; i < slice.length; i++) {
                if (slice[i].name === "thumbs up") { at = i; break }
            }
            T.equal(at >= 0, true)
            T.equal(slice[at].variants.length, 5)
            for (var v = 0; v < 5; v++) {
                T.equal(slice[at + 1 + v].base, entries.indexOf(slice[at]))
                T.equal(slice[at + 1 + v].name.indexOf("thumbs up: ") === 0, true)
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

        T.test("the page stays clear of the keyboard band at every size preset", function () {
            var output = { x: 0, y: 0, w: 1280, h: 800 }
            var presets = Config.SIZE_PRESET_SCALES
            var tried = 0
            for (var preset in presets) {
                // Cells ride the preset's scale (space(42) * uiScale at the
                // theme's scale-1 spacing), the chrome does not.
                var cell = Math.round(42 * presets[preset])
                var gap = 4
                var natural = {
                    w: naturalPageWidth(cell, gap),
                    h: naturalPageHeight(cell, gap)
                }
                // The suite's recorded medium band, scaled as the keyboard's
                // card is by the preset.
                var band = Place.overlayBand("docked", output,
                    { x: 0, y: 0, w: 1280, h: Math.round(240 * presets[preset]) })
                var fitted = Place.fitSizeInLeftover(output, band, natural, 8)
                // Width never needs clamping on this output: the grid keeps
                // all eight natural columns at every preset.
                T.equal(fitted.w, natural.w)
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
            var cell = Math.round(42 * Config.SIZE_PRESET_SCALES["x-large"])
            var gap = 4
            var natural = {
                w: naturalPageWidth(cell, gap),
                h: naturalPageHeight(cell, gap)
            }
            var maxPageWidth = Math.max(0, output.w - 2 * 6)
            var width = Math.min(natural.w, maxPageWidth)
            T.equal(width < natural.w, true)
            var columns = Page.columnsFor(width - 2 * 10, cell, gap, 8)
            T.equal(columns < 8, true)
            T.equal(columns >= 1, true)
            var band = Place.overlayBand("docked", output,
                { x: 0, y: 0, w: 480, h: Math.round(240 * Config.SIZE_PRESET_SCALES["x-large"]) })
            var fitted = Place.fitSizeInLeftover(output, band, natural, 8)
            var pos = Place.centreInLeftover(output, band, fitted)
            T.equal(pos.y + fitted.h <= band.y, true)
            // The clamp that makes the grid scroll is the same one that
            // keeps the band clear.
            T.equal(fitted.h < natural.h, true)
        })

        Qt.exit(T.report("emoji page"))
    }
}
