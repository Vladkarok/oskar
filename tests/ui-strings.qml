// The UI string table: every user-facing word the panel
// draws is an id in UiStrings.js's table, carried in EN/RU/UK — the
// searchPlaceholder mechanism (EmojiPage.js) generalised to
// the whole surface, with a settings override on top. Run with
// tools/run-tests.sh — no compositor, no display.
//
// Three pins:
//   * the table is DATA that cannot drift — every id exists in exactly
//     the three shipped languages and none is empty;
//   * tr() fails LOUDLY — an unknown id throws here, in the offscreen
//     suite, rather than rendering a blank in production;
//   * every tr("…") call site in the QML resolves — the suite reads the
//     runtime QML files (XMLHttpRequest; tools/run-tests.sh sets
//     QML_XHR_ALLOW_FILE_READ=1) and resolves each literal id it finds,
//     so a typo'd or deleted id fails here, not at first hover.
import QtQml
import "../UiStrings.js" as UiStrings
import "../EmojiPage.js" as Page
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("the table ships exactly four complete languages", function () {
            T.deepEqual(UiStrings.LANGUAGES, ["en", "ru", "uk", "it"])
            var ids = UiStrings.ids()
            T.equal(ids.length > 60, true)
            for (var i = 0; i < ids.length; i++) {
                var entry = UiStrings.STRINGS[ids[i]]
                T.deepEqual(Object.keys(entry).sort(), ["en", "it", "ru", "uk"],
                    "id " + ids[i])
                for (var l = 0; l < UiStrings.LANGUAGES.length; l++) {
                    var text = entry[UiStrings.LANGUAGES[l]]
                    if (typeof text !== "string" || text.trim() === "")
                        T.fail("id " + ids[i] + " has an empty "
                            + UiStrings.LANGUAGES[l] + " translation")
                }
            }
        })

        T.test("tr answers in the asked language", function () {
            T.equal(UiStrings.tr("emoji.searchPlaceholder", "en"), "Search")
            T.equal(UiStrings.tr("emoji.searchPlaceholder", "ru"), "Поиск")
            T.equal(UiStrings.tr("emoji.searchPlaceholder", "uk"), "Пошук")
        })

        T.test("an unknown language falls through to English", function () {
            // The searchPlaceholder rule: a code we do not ship reads as
            // English rather than guessing (a "de" layout, a junk value).
            T.equal(UiStrings.tr("emoji.searchPlaceholder", "de"), "Search")
            T.equal(UiStrings.tr("emoji.searchPlaceholder", ""), "Search")
            T.equal(UiStrings.tr("emoji.searchPlaceholder", undefined), "Search")
        })

        T.test("an unknown id throws — loudly, not as a blank", function () {
            var threw = false
            try {
                UiStrings.tr("no.such.id", "en")
            } catch (error) {
                threw = true
            }
            T.equal(threw, true)
        })

        T.test("substitution fills %1..%n in order", function () {
            T.equal(UiStrings.tr("color.setTo", "en", ["Text colour", "#fff"]),
                "Set Text colour to #fff")
            T.equal(UiStrings.tr("color.setTo", "ru", ["Текст", "#fff"]).length
                > "#fff".length, true)
            // No args leaves the template alone — the sweep resolves bare.
            T.equal(UiStrings.tr("color.setTo", "en").indexOf("%1") !== -1,
                true)
        })

        T.test("languageFor: the override wins ONLY if its language is installed, auto follows the layout", function () {
            // Never offer — let alone apply — a language the seat
            // cannot type. Auto is the searchPlaceholder
            // mapping (ua→uk, ru→ru, else en); an explicit override pins
            // the UI ONLY when its language rides an installed layout (or
            // is English, the product's fallback); otherwise it is inert
            // and the layout answers. layoutCodes is the seat's list.
            T.equal(UiStrings.languageFor("ua", "auto", ["us", "ua"]), "uk")
            T.equal(UiStrings.languageFor("ru", "auto", ["us", "ru"]), "ru")
            T.equal(UiStrings.languageFor("us", "auto", ["us"]), "en")
            T.equal(UiStrings.languageFor("de", "auto", ["de"]), "en")
            T.equal(UiStrings.languageFor("", "auto", []), "en")
            T.equal(UiStrings.languageFor(undefined, "auto", undefined), "en")
            // The xkb code arrives uppercased sometimes; the placeholder
            // lowercases before comparing and so does this.
            T.equal(UiStrings.languageFor("UA", "auto", ["US", "UA"]), "uk")
            // A representable override pins: en is always representable
            // (the fallback); ru/uk only when the layout carries them.
            T.equal(UiStrings.languageFor("us", "en", ["us"]), "en")
            T.equal(UiStrings.languageFor("us", "ru", ["us", "ru"]), "ru")
            // ru chosen on a seat that has none — stale file, hand-edited
            // config, or layouts shrank — the override goes inert, the
            // layout answers, nothing is shoved.
            T.equal(UiStrings.languageFor("us", "ru", ["us", "ua"]), "en")
            T.equal(UiStrings.languageFor("ua", "ru", ["us", "ua"]), "uk")
            // A junk override degrades the same way.
            T.equal(UiStrings.languageFor("ua", "junk", ["us", "ua"]), "uk")
            T.equal(UiStrings.languageFor("us", "junk", ["us"]), "en")
            T.equal(UiStrings.languageFor(undefined, undefined, undefined), "en")
        })

        T.test("languageChoices: the offered languages mirror the installed layouts", function () {
            // The LANGUAGE row offers Auto and English always, plus each
            // translation whose layout the seat carries: a us,ua seat
            // sees Auto/English/Українська — no Русский segment for a
            // language it cannot type.
            T.deepEqual(UiStrings.languageChoices(["us", "ua"]),
                ["auto", "en", "uk"])
            T.deepEqual(UiStrings.languageChoices(["us", "ru"]),
                ["auto", "en", "ru"])
            T.deepEqual(UiStrings.languageChoices(["us"]),
                ["auto", "en"])
            T.deepEqual(UiStrings.languageChoices(["us", "ua", "ru"]),
                ["auto", "en", "ru", "uk"])
            // Junk/empty/dup codes cost nothing; case-insensitive.
            T.deepEqual(UiStrings.languageChoices([]), ["auto", "en"])
            T.deepEqual(UiStrings.languageChoices(undefined), ["auto", "en"])
            T.deepEqual(UiStrings.languageChoices(["UA", "ua"]),
                ["auto", "en", "uk"])
            T.deepEqual(UiStrings.languageChoices(["de"]), ["auto", "en"])
        })


        T.test("every translation keeps the English arity of its placeholders", function () {
            // A ru string that lost its %1 stays non-empty, so the
            // completeness pin alone would miss it while tr() silently
            // skips a substitution: the placeholder COUNT is
            // part of the contract, per language.
            function count(text) {
                var found = text.match(/%[0-9]+/g) || []
                return found.length
            }
            var ids = Object.keys(UiStrings.STRINGS)
            T.equal(ids.length > 90, true)
            for (var i = 0; i < ids.length; i++) {
                var entry = UiStrings.STRINGS[ids[i]]
                var arity = count(entry.en)
                for (var l = 0; l < UiStrings.LANGUAGES.length; l++) {
                    var lang = UiStrings.LANGUAGES[l]
                    T.equal(count(entry[lang]), arity,
                        ids[i] + "/" + lang + " placeholder count drift")
                }
            }
        })

        T.test("every skin tone names itself in all three languages", function () {
            var tones = Page.SKIN_TONES
            T.equal(tones.length, 6)
            for (var i = 0; i < tones.length; i++) {
                var id = Page.toneNameId(tones[i].value)
                if (!id || typeof id !== "string" || id === "") {
                    T.fail("tone " + i + " has no id")
                    continue
                }
                // English stays the table data's own label; ru/uk resolve.
                T.equal(UiStrings.tr(id, "en"), tones[i].label, "tone " + i)
                T.equal(UiStrings.tr(id, "ru").trim() !== "", true)
                T.equal(UiStrings.tr(id, "uk").trim() !== "", true)
            }
            T.equal(Page.toneNameId("no such tone"), "")
        })

        // ---- the call-site sweep ----
        //
        // Every literal UiStrings.tr("id" in the QML files that carry
        // tr call sites (plus SettingsLayer, swept for symmetry) must
        // resolve in all FOUR languages. The files without tr sites
        // (HelperLink, PasteChords, PrivateSaves, HoldMenu, DragLine)
        // are deliberately absent: the sweep resolves literals that
        // exist. The files are read one by one
        // (async XHR; the runner's event loop spins until each lands) and
        // the suite reports after the last one.
        var files = ["Panel.qml", "BarWidget.qml", "Keyboard.qml",
            "EmojiDelivery.qml",
            "CursorPolicy.qml", "EmojiPage.qml", "HoverTooltip.qml",
            "KeyClickSound.qml", "Theme.qml", "SettingsPopover.qml",
            "SettingsColorRow.qml", "SettingsColorEditor.qml",
            "SettingsConfirmChip.qml", "SettingsResetChip.qml",
            "SettingsLayer.qml"]
        var index = 0

        function sweepNext() {
            if (index >= files.length) {
                Qt.exit(T.report("ui strings"))
                return
            }
            var name = files[index]
            index += 1
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                var source = xhr.responseText || ""
                T.test("every tr call site in " + name + " resolves", function () {
                    T.equal(xhr.status === 200 && source.length > 0, true,
                        name + " did not load")
                    var pattern = /UiStrings\.tr\(\s*"([^"]+)"/g
                    var seen = {}
                    var match
                    while ((match = pattern.exec(source)) !== null) {
                        if (seen[match[1]]) continue
                        seen[match[1]] = true
                        for (var l = 0; l < UiStrings.LANGUAGES.length; l++) {
                            var lang = UiStrings.LANGUAGES[l]
                            try {
                                var text = UiStrings.tr(match[1], lang)
                                if (typeof text !== "string" || text === "")
                                    T.fail(match[1] + "/" + lang + " is empty")
                            } catch (error) {
                                T.fail(match[1] + " does not resolve in "
                                    + lang + ": " + error)
                            }
                        }
                    }
                })
                sweepNext()
            }
            xhr.open("GET", Qt.resolvedUrl("../" + name), true)
            xhr.send()
        }

        sweepNext()
    }
}
