// Pure emoji catalogue (ticket 24, decisions §37). Not a product seam:
// loads the generated EmojiCatalog.js the way the panel will, with no
// compositor. The counts it pins are the generator's output for the
// vendored Emoji 16.0 / CLDR 46 data on 2026-09-09; a deliberate data
// upgrade regenerates both this suite's expectations and the catalogue.
import QtQml
import "../EmojiCatalog.js" as Catalog
import "harness.js" as T

QtObject {
    function findByName(entries, name) {
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].name === name) return i
        }
        return -1
    }

    function containsName(results, name) {
        return findByName(results, name) >= 0
    }

    Component.onCompleted: {
        var entries = Catalog.entries()
        var groups = Catalog.groups()

        T.test("the catalogue is the size the generator produced today", function () {
            // 3781 fully-qualified sequences of Emoji 16.0: 3126 bases and
            // 655 skin-tone variants. The band guard keeps a half-finished
            // regeneration from passing by accident.
            T.equal(entries.length >= 3700, true)
            T.equal(entries.length, 3781)
        })

        T.test("every entry has an emoji, a name, and a known group", function () {
            var offender = -1
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                if (typeof entry.emoji !== "string" || entry.emoji.length === 0
                        || typeof entry.name !== "string" || entry.name.length === 0
                        || groups.indexOf(entry.group) < 0) {
                    offender = i
                    break
                }
            }
            T.equal(offender, -1)
        })

        T.test("groups() is the set of groups the entries use, in order", function () {
            T.equal(groups.length > 0, true)
            var distinct = []
            for (var i = 0; i < entries.length; i++) {
                if (distinct.indexOf(entries[i].group) < 0) distinct.push(entries[i].group)
            }
            T.deepEqual(groups, distinct)
        })

        T.test("the Component group is not here", function () {
            // emoji-test.txt has a Component group, but its members are
            // component-status and nothing kept lives in it; a tab with no
            // entries would only be a dead end.
            T.equal(groups.indexOf("Component"), -1)
        })

        T.test("variant linkage is bidirectional and lands on bases", function () {
            var offender = -1
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                if (entry.base >= 0) {
                    if (entries[entry.base].base !== -1
                            || entries[entry.base].variants.indexOf(i) < 0) {
                        offender = i
                        break
                    }
                }
                for (var v = 0; v < entry.variants.length; v++) {
                    if (entries[entry.variants[v]].base !== i) {
                        offender = i
                        break
                    }
                }
                if (offender >= 0) break
            }
            T.equal(offender, -1)
        })

        T.test("each variant directly follows its base", function () {
            var offender = -1
            for (var i = 0; i < entries.length; i++) {
                var variants = entries[i].variants
                for (var v = 0; v < variants.length; v++) {
                    if (variants[v] !== i + 1 + v) {
                        offender = i
                        break
                    }
                }
                if (offender >= 0) break
            }
            T.equal(offender, -1)
        })

        T.test("variants carry no keywords; bases may", function () {
            var offender = -1
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                if (entry.base >= 0 && entry.keywords.length > 0) {
                    offender = i
                    break
                }
            }
            T.equal(offender, -1)
            T.equal(entries[findByName(entries, "thumbs up")].keywords.length > 0, true)
        })

        T.test("thumbs up keeps its five skin tones beside it", function () {
            var up = entries[findByName(entries, "thumbs up")]
            T.equal(up.variants.length, 5)
            for (var v = 0; v < up.variants.length; v++) {
                var variant = entries[up.variants[v]]
                T.equal(variant.name.indexOf("thumbs up: ") === 0, true)
                T.equal(variant.base, findByName(entries, "thumbs up"))
            }
        })

        T.test("toned forms of text-default glyphs link to their selector-less base", function () {
            // 26F9 1F3FB is kept bare while its base is kept as 26F9 FE0F;
            // the base link must survive the dropped presentation selector.
            var toned = entries[findByName(entries, "person bouncing ball: light skin tone")]
            T.equal(toned.base >= 0, true)
            T.equal(entries[toned.base].emoji, "⛹️")
        })

        T.test("the E15.1 facing-right variants carry their tone in the name", function () {
            // CLDR 46's derived annotations dropped the tone suffixes the
            // 16.0 data has; the emoji-test.txt comments name them right.
            T.equal(findByName(entries, "person walking facing right: light skin tone") >= 0, true)
            T.equal(findByName(entries, "woman walking facing right: dark skin tone") >= 0, true)
        })

        T.test("thumbs up finds the thumbs-up emoji first", function () {
            var results = Catalog.search("thumbs up", 0)
            T.equal(results.length > 0, true)
            T.equal(results[0].name, "thumbs up")
        })

        T.test("an exact name match ranks before a keyword-only match", function () {
            var results = Catalog.search("banana", 0)
            // monkey face carries banana only as a keyword; the fruit itself
            // matches on the name and must outrank it.
            T.equal(results[0].name, "banana")
            var keywordOnly = -1
            for (var i = 1; i < results.length; i++) {
                if (results[i].name.indexOf("banana") < 0
                        && results[i].keywords.indexOf("banana") >= 0) {
                    keywordOnly = i
                    break
                }
            }
            T.equal(keywordOnly > 0, true)
        })

        T.test("a multi-term query ANDs its terms", function () {
            // CLDR 46 gives banana no "yellow" keyword, so the fixture pairs
            // its name with a keyword it does carry; one unmatched term must
            // kill the result.
            var results = Catalog.search("banana potassium", 0)
            T.equal(results.length, 1)
            T.equal(results[0].name, "banana")
            T.equal(Catalog.search("banana zxqvv", 0).length, 0)
        })

        T.test("a term matching only a keyword still finds the entry", function () {
            // "g2g" lives in no name, only in waving hand's keywords.
            var results = Catalog.search("g2g", 0)
            T.equal(results.length > 0, true)
            T.equal(containsName(results, "waving hand"), true)
        })

        T.test("limit caps the result; 0 and undefined mean all", function () {
            var all = Catalog.search("face", 0)
            T.equal(all.length > 10, true)
            T.equal(Catalog.search("face", 10).length, 10)
            T.equal(Catalog.search("face").length, all.length)
        })

        T.test("gibberish finds nothing, and neither does an empty query", function () {
            T.equal(Catalog.search("zxqjvkw", 0).length, 0)
            T.equal(Catalog.search("", 0).length, 0)
            T.equal(Catalog.search("   ", 0).length, 0)
        })

        T.test("names with capitals are findable by their lowercase words", function () {
            // The first matcher lowercased only the query, so "flag:
            // Ukraine" and "Mrs. Claus" were invisible to their own words.
            var results = Catalog.search("ukraine", 0)
            T.equal(results.length > 0, true)
            T.equal(containsName(results, "flag: Ukraine"), true)
            T.equal(containsName(Catalog.search("mrs claus", 0), "Mrs. Claus"), true)
        })

        T.test("a keyword published in caps still matches lowercase input", function () {
            // optical disk is reachable only through its "CD" keyword.
            T.equal(containsName(Catalog.search("cd", 0), "optical disk"), true)
        })

        T.test("search is case-insensitive and trims", function () {
            var plain = Catalog.search("thumbs up", 0)
            var messy = Catalog.search("  Thumbs UP  ", 0)
            T.equal(messy.length, plain.length)
            T.equal(messy[0].name, plain[0].name)
            var shouted = Catalog.search("FLAG: UKRAINE", 0)
            T.equal(shouted.length > 0, true)
            T.equal(shouted[0].name, "flag: Ukraine")
        })

        Qt.exit(T.report("emoji catalogue"))
    }
}
