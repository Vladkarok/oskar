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

        T.test("glyphs route by CLIENT proof, never by payload faith (§90)", function () {
            // The owner's live report killed §84's first rule ("a lone
            // BMP scalar rides the keysym route everywhere"): his
            // Electron build repeats the FIRST glyph for every later
            // pick — its keymap table caches the first transient. The
            // keysym route serves only the PROVEN clients; §40's
            // discipline — no Chromium-family build sees a transient
            // keymap — holds for every payload, glyphs included.
            var entries = TextGlyphs.entries()
            var byClass = {
                "foot": "text",
                "com.rtosta.zapzap": "text",
                "brave-browser": "text-unicode",
                "com.anthropic.Claude": "text-unicode",
                "zcode": "clipboard",
                "org.telegram.desktop": "clipboard",
                "viber": "clipboard",
                "": "clipboard"
            }
            for (var c in byClass) {
                // Every glyph, same route — the payload no longer
                // buys anyone the keysym route.
                for (var i = 0; i < entries.length; i++) {
                    T.equal(Page.deliveryRoute(entries[i].emoji, c),
                        byClass[c],
                        entries[i].emoji + " into " + c)
                }
                // And the invariant beyond glyphs: no unlisted client
                // is EVER handed the transient route, whatever the
                // payload — the emoji twins included.
                T.equal(Page.deliveryRoute("\u2665\uFE0F", c), byClass[c],
                    "the twin into " + c)
                T.equal(Page.deliveryRoute("\uD83D\uDC4D", c), byClass[c],
                    "an astral single into " + c)
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

        T.test("the shelf never hijacks a catalogue family (§86's poison 1)", function () {
            // THE VIEW THE USER SEES: the page draws each group tab as
            // the catalogue's own slice passed through visibleEntries
            // with the merged table. The §86 bug was exactly here — a
            // bare glyph winning the family key rewrote the twin's TILE
            // (monochrome render) and its PICK (bare bytes). Pin: no
            // entry of any catalogue slice ever comes out as a
            // different string, and no glyph substitutes onto a
            // non-Text tab. (The first draft of this pin asserted
            // groupEntries and caught nothing — written-after-the-fix
            // tautology, caught by negative-testing the guard away.)
            var catalog = Catalog.entries()
            var merged = Page.allEntries()
            var groups = Catalog.groups()
            for (var g = 0; g < groups.length; g++) {
                var slice = Page.groupEntries(catalog, groups[g])
                var view = Page.visibleEntries(slice, merged, 0)
                T.equal(view.length, slice.length,
                    groups[g] + " lost tiles to the family collapse")
                for (var i = 0; i < view.length; i++) {
                    T.equal(view[i].emoji, slice[i].emoji,
                        groups[g] + " tile " + slice[i].emoji
                            + " was rewritten to " + view[i].emoji)
                    T.equal(view[i].group, slice[i].group,
                        "a shelf entry substituted onto " + groups[g])
                }
            }
            // The Text tab itself passes through AS ITSELF, asserted
            // against the RAW SHELF (§88's pin fix: the §87 draft
            // re-collapsed an already-collapsed slice — twin-to-twin
            // comparison, vacuous; only its group arm was live).
            var shelf = TextGlyphs.entries()
            var textSlice = Page.groupEntries(merged, "Text")
            var textView = Page.visibleEntries(textSlice, merged, 0)
            T.equal(textView.length, shelf.length)
            for (var t = 0; t < textView.length; t++) {
                T.equal(textView[t].emoji, shelf[t].emoji,
                    "Text tile " + shelf[t].emoji
                        + " came out as " + textView[t].emoji)
                T.equal(textView[t].group, "Text")
            }
        })

        T.test("search keeps the shelf's identity, not its twin's (§88)", function () {
            // The search path's mirror symptom is VANISHING, not
            // twin-drawing: a substituted glyph dedups against the
            // catalogue twin already seen. The pin asserts the shelf's
            // own tile survives the collapse per identity.
            var view = Page.visibleEntries(
                Page.searchEverything("heart", 64),
                Page.allEntries(), 0)
            var sawShelfHeart = false
            for (var i = 0; i < view.length; i++) {
                if (view[i].group === "Text" && view[i].emoji === "\u2665") {
                    sawShelfHeart = true
                }
                if (view[i].emoji === "\u2665") {
                    T.equal(view[i].group, "Text",
                        "the bare heart survived as "
                            + view[i].group)
                }
            }
            T.equal(sawShelfHeart, true,
                "the shelf's heart vanished from the search view")
        })

        T.test("a twinned glyph survives the whole pick flow (§87's mirror)", function () {
            // END TO END, the way the page really works: the tile's
            // model → the tone step → the route table. A twinned glyph
            // under a selected tone must still deliver itself, as a
            // lone BMP scalar, on the keysym fast lane.
            var merged = Page.allEntries()
            var textSlice = Page.groupEntries(merged, "Text")
            var textView = Page.visibleEntries(textSlice, merged, 0)
            var tones = ["", "\u{1F3FB}", "\u{1F3FD}", "\u{1F3FF}"]
            var twinned = 0
            for (var i = 0; i < textView.length; i++) {
                var twin = textView[i].emoji + "\uFE0F"
                var isTwin = false
                for (var m = 0; m < merged.length; m++)
                    if (merged[m].emoji === twin) isTwin = true
                if (!isTwin) continue
                twinned++
                for (var t = 0; t < tones.length; t++) {
                    var toned = Page.entryForTone(textView[i], tones[t], merged)
                    T.equal(toned.emoji, textView[i].emoji,
                        textView[i].emoji + " under a tone resolved to "
                            + toned.emoji)
                    T.equal(Page.deliveryRoute(toned.emoji, "foot"), "text",
                        textView[i].emoji + " routed off the fast lane")
                    T.equal(Page.deliveryRoute(toned.emoji,
                        "com.rtosta.zapzap"), "text")
                }
            }
            T.equal(twinned >= 15, true,
                "the fixture expects the twin set, got " + twinned)
        })

        T.test("searchEverything caps the catalogue side, appends glyphs whole", function () {
            var results = Page.searchEverything("a", 8)
            var fromCatalog = 0
            var fromShelf = 0
            var mergedByEmoji = {}
            var merged = Page.allEntries()
            for (var m = 0; m < merged.length; m++)
                mergedByEmoji[merged[m].emoji] = merged[m]
            for (var r = 0; r < results.length; r++) {
                if (results[r].group === "Text") fromShelf++
                else fromCatalog++
            }
            // The catalogue side is capped WITH COLLAPSE HEADROOM (§88:
            // raw cap = 3x the page limit — tone families eat up to six
            // raw hits per distinct tile).
            T.equal(fromCatalog <= 8 * 3, true,
                "catalogue side capped at 3x the limit, got " + fromCatalog)
            // "a" matches shelf keywords (arrow, sun...) — they ride
            // whole past the cap.
            T.equal(fromShelf > 0, true,
                "glyph hits appended past the cap")
        })

        T.test("no tone ever applies to a glyph (§86's poison 2)", function () {
            // The real pick flow tones BEFORE it routes; the invariant
            // must hold at that step, not on the raw entry.
            var tones = ["", "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}",
                "\u{1F3FE}", "\u{1F3FF}"]
            var glyphs = TextGlyphs.entries()
            var all = Page.allEntries()
            for (var i = 0; i < glyphs.length; i++) {
                for (var t = 0; t < tones.length; t++) {
                    var resolved = Page.entryForTone(glyphs[i], tones[t], all)
                    T.equal(resolved.emoji, glyphs[i].emoji,
                        glyphs[i].emoji + " under a tone resolved to "
                            + resolved.emoji)
                }
            }
        })

        Qt.exit(T.report("text glyphs"))
    }
}
