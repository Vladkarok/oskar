// Pure emoji catalogue. Not a product seam: loads the generated
// EmojiCatalog.js the way the panel will, with no compositor. The
// counts it pins are the generator's output for the vendored Emoji
// 16.0 / CLDR 46 data; a deliberate data upgrade regenerates both
// this suite's expectations and the catalogue.
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

        // The pinned English orderings below must stay identical to the
        // English-only catalogue once the Russian and Ukrainian
        // vocabularies ship alongside it.
        T.test("ru and uk keywords ship in lockstep, never on variants", function () {
            // CLDR 46 keywords the same 1948 sequences for en, ru and uk;
            // the catalogue keeps ru/uk presence in lockstep and off the
            // variants, which carry no keywords in any language. English
            // lists can additionally be emptied by the generator's
            // keyword-equals-name drop ("hole", "battery") — a per-language
            // rule with no Cyrillic equivalent, so it is not asserted here.
            var offender = -1
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                var hasRu = entry.ru.length > 0
                var hasUk = entry.uk.length > 0
                if (entry.base >= 0 && (hasRu || hasUk)) { offender = i; break }
                if (hasRu !== hasUk) { offender = i; break }
            }
            T.equal(offender, -1)
        })

        T.test("Russian queries find emoji through CLDR ru keywords", function () {
            var kot = Catalog.search("кот", 0)
            T.equal(kot.length > 0, true)
            T.equal(containsName(kot, "cat"), true)
            T.equal(containsName(kot, "cat face"), true)
            T.equal(containsName(Catalog.search("КОТ", 0), "cat"), true)
            var serdce = Catalog.search("сердце", 0)
            T.equal(serdce.length > 0, true)
            T.equal(containsName(serdce, "red heart"), true)
            T.equal(containsName(serdce, "black heart"), true)
        })

        T.test("Ukrainian queries find emoji through CLDR uk keywords", function () {
            var kit = Catalog.search("кіт", 0)
            T.equal(kit.length > 0, true)
            T.equal(containsName(kit, "cat"), true)
            var yabluko = Catalog.search("яблуко", 0)
            T.equal(yabluko.length > 0, true)
            T.equal(containsName(yabluko, "red apple"), true)
        })

        T.test("a Cyrillic multi-term query ANDs its terms", function () {
            // black heart carries both "чорне" and "серце" as uk keywords;
            // red heart has "серце" but not "чорне", so one unmatched term
            // must keep it out.
            var chorne = Catalog.search("чорне серце", 0)
            T.equal(containsName(chorne, "black heart"), true)
            T.equal(containsName(chorne, "red heart"), false)
        })

        T.test("English results and ordering are pinned: cat, star, 100", function () {
            var catNames = []
            var cat = Catalog.search("cat", 0)
            for (var i = 0; i < cat.length; i++) catNames.push(cat[i].name)
            T.deepEqual(catNames, [
                "grinning cat", "grinning cat with smiling eyes",
                "cat with tears of joy", "smiling cat with heart-eyes",
                "cat with wry smile", "kissing cat", "weary cat",
                "crying cat", "pouting cat", "cat face", "cat", "black cat",
                "palm up hand", "person playing handball",
                "man playing handball", "woman playing handball",
                "tiger face", "tiger", "leopard", "hook", "woozy face",
                "sad but relieved face", "backpack", "graduation cap",
                "loudspeaker", "mobile phone", "mobile phone with arrow",
                "telephone receiver", "pager", "fax machine",
                "notebook with decorative cover", "closed book", "open book",
                "green book", "blue book", "orange book", "books",
                "newspaper", "envelope with arrow", "package",
                "closed mailbox with raised flag", "memo", "round pushpin",
                "pill", "identification card", "antenna bars",
                "vibration mode", "multiply", "cross mark",
                "cross mark button", "Japanese “application” button",
            ])
            var starNames = []
            var star = Catalog.search("star", 0)
            for (var s = 0; s < star.length; s++) starNames.push(star[s].name)
            T.deepEqual(starNames, [
                "star-struck", "night with stars", "star", "glowing star",
                "shooting star", "star of David", "star and crescent",
                "dotted six-pointed star", "eight-pointed star",
                "face with peeking eye", "dizzy", "singer", "man singer",
                "woman singer", "sparkles", "custard",
            ])
            // CLDR ru/uk also publish "100" as a keyword (on other emoji
            // too); an ASCII query must keep seeing only the English hits,
            // in the English order.
            var hundred = Catalog.search("100", 0)
            T.equal(hundred.length, 2)
            T.equal(hundred[0].name, "hundred points")
            T.equal(hundred[1].name, "euro banknote")
        })

        T.test("English results and ordering are pinned: heart", function () {
            var heart = Catalog.search("heart", 0)
            T.equal(heart.length, 148)
            var head = []
            for (var h = 0; h < 30; h++) head.push(heart[h].name)
            T.deepEqual(head, [
                "smiling face with hearts", "smiling face with heart-eyes",
                "smiling cat with heart-eyes", "heart with arrow",
                "heart with ribbon", "sparkling heart", "growing heart",
                "beating heart", "revolving hearts", "two hearts",
                "heart decoration", "heart exclamation", "broken heart",
                "heart on fire", "mending heart", "red heart", "pink heart",
                "orange heart", "yellow heart", "green heart", "blue heart",
                "light blue heart", "purple heart", "brown heart",
                "black heart", "grey heart", "white heart", "heart hands",
                "heart hands: light skin tone",
                "heart hands: medium-light skin tone",
            ])
            var tail = []
            for (var t = heart.length - 3; t < heart.length; t++) {
                tail.push(heart[t].name)
            }
            T.deepEqual(tail, ["house", "house with garden", "stethoscope"])
        })

        // ---- the catalogue's field contract ----
        //
        // The page's grid delegate reads entry.emoji and entry.name; the
        // search reads keywords/ru/uk; the tabs come from group; the tone
        // families hang off base and variants. A rename in the generator
        // (or a hand edit of the generated file) must break this suite,
        // not read as `undefined` in a shipped page.
        T.test("every catalogue entry carries exactly the fields the panel reads", function () {
            var shape = ["base", "emoji", "group", "keywords", "name",
                         "ru", "uk", "variants"]
            var offender = -1
            for (var i = 0; i < entries.length; i++) {
                var keys = Object.keys(entries[i]).sort().join(",")
                if (keys !== shape.join(",")) { offender = i; break }
            }
            T.equal(offender, -1)
            for (i = 0; i < entries.length; i++) {
                var entry = entries[i]
                if (typeof entry.emoji !== "string" || entry.emoji.length === 0
                        || typeof entry.name !== "string" || entry.name.length === 0
                        || typeof entry.group !== "string"
                        || typeof entry.base !== "number"
                        || !Array.isArray(entry.keywords)
                        || !Array.isArray(entry.ru)
                        || !Array.isArray(entry.uk)
                        || !Array.isArray(entry.variants)) {
                    offender = i
                    break
                }
            }
            T.equal(offender, -1)
        })

        Qt.exit(T.report("emoji catalogue"))
    }
}
