// The text-glyph shelf (§85): the owner's bare-BMP classics in the
// picker. Two contracts live here: every glyph is a LONE BMP scalar (so
// the delivery route taps it directly into any client — the fast lane),
// and the merge seam places the shelf as the THIRD tab, before the
// animals, over the full merged catalogue. Run with tools/run-tests.sh
// — no compositor, no display.
import QtQml
import "../TextGlyphs.js" as TextGlyphs
import "../EmojiPage.js" as Page
import "../EmojiCatalog.js" as Catalog
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("every glyph is a lone BMP scalar — the fast lane holds", function () {
            // §85's whole point: these picks ride the keysym route into
            // EVERY client (no clipboard, no composition). A glyph that
            // regresses to astral or multi-scalar silently becomes a
            // clipboard pick in half the world — this pin is the tripwire.
            var entries = TextGlyphs.entries()
            T.equal(entries.length > 80, true,
                "the shelf carries a real selection, got " + entries.length)
            for (var i = 0; i < entries.length; i++) {
                var emoji = entries[i].emoji
                T.equal(emoji.length, 1,
                    emoji + " is a single UTF-16 unit")
                T.equal(emoji.codePointAt(0) <= 0xFFFF, true,
                    emoji + " is a BMP scalar")
            }
        })

        T.test("every glyph routes 'text' into any client whatsoever", function () {
            var entries = TextGlyphs.entries()
            var classes = ["zcode", "org.telegram.desktop", "brave-browser",
                "foot", "", "com.rtosta.zapzap", "viber"]
            for (var i = 0; i < entries.length; i++) {
                for (var c = 0; c < classes.length; c++) {
                    var route = Page.deliveryRoute(entries[i].emoji, classes[c])
                    T.equal(route, "text",
                        entries[i].emoji + " into " + classes[c]
                            + " routed " + route)
                }
            }
        })

        T.test("entries carry the catalogue's shape", function () {
            var entries = TextGlyphs.entries()
            var seen = {}
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                T.equal(entry.group, "Text")
                T.equal(entry.base, -1)
                T.equal(entry.variants.length, 0)
                T.equal(typeof entry.name, "string")
                T.equal(entry.name.length > 0, true)
                T.equal(entry.keywords.length > 0, true, entry.name)
                T.equal(entry.ru.length > 0, true, entry.name)
                T.equal(entry.uk.length > 0, true, entry.name)
                T.equal(seen[entry.emoji], undefined,
                    entry.emoji + " appears twice")
                seen[entry.emoji] = true
            }
        })

        T.test("the shelf sits third, before the animals", function () {
            var groups = Page.allGroups()
            T.equal(groups[0], "Smileys & Emotion")
            T.equal(groups[1], "People & Body")
            T.equal(groups[2], "Text", "the shelf is the third tab")
            T.equal(groups[3], "Animals & Nature",
                "and it stands before the animals (the owner's placement)")
            T.equal(groups.length, Catalog.groups().length + 1)
        })

        T.test("merged entries hold both shelves", function () {
            var all = Page.allEntries()
            T.equal(all.length,
                Catalog.entries().length + TextGlyphs.entries().length)
            var textGroup = 0
            for (var i = 0; i < all.length; i++)
                if (all[i].group === "Text") textGroup++
            T.equal(textGroup, TextGlyphs.entries().length)
        })

        T.test("search reaches the shelf in all three vocabularies", function () {
            function firstEmoji(query) {
                var results = TextGlyphs.search(query)
                return results.length > 0 ? results[0].emoji : null
            }
            T.equal(firstEmoji("heart"), "\u2665")
            T.equal(firstEmoji("сердце"), "\u2665")
            T.equal(firstEmoji("серце"), "\u2665")
            T.equal(firstEmoji("гривня"), "\u20B4")
            T.equal(firstEmoji("зірка"), "\u2605")
            T.equal(firstEmoji("многоточие"), "\u2026")
            // Multiple terms AND together like the catalogue's search.
            T.equal(firstEmoji("die six"), "\u2685")
            T.deepEqual(TextGlyphs.search(""), [])
            T.equal(TextGlyphs.search("qqqqzzzz").length, 0)
        })

        Qt.exit(T.report("text glyphs"))
    }
}
