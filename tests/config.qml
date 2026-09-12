// Pure configuration logic lives beside the existing panel reducer tests.
// This is not a product seam: it checks parsing and serialization without
// inventing a mock panel or filesystem protocol (spec-v1.1 §8). The curated
// page's pure resolution (the token reverse index and the row builder) rides
// in this file for the same reason: it is pure module logic, and a third
// suite file would be a new seam (spec-v1.1 §8).
import QtQml
import "../Config.js" as Config
import "../KeyboardLayout.js" as Layout
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("maintainer defaults are complete and state is separate", function () {
            T.deepEqual(Config.maintainerDefaults(), {
                mode: "docked",
                sizePreset: "medium",
                sound: false,
                followTheme: true,
                // Omarchy 4.0.2's own default emoji picker (2026-09-05).
                emojiApp: "omarchy-menu-emoji",
                keyRadius: 8,
                panelRadius: 12,
                keyBackground: "#303030",
                panelBackground: "#202020",
                textColor: "#f5f5f5",
                accentColor: "#7aa2f7",
                borderColor: "#5a5a5a"
            })
            T.deepEqual(Config.stateDefaults(), { center: null })
        })

        T.test("the emoji app override is any bare name, trimmed", function () {
            // The ☺ cap execs the configured picker by bare PATH name
            // (spec-v1.1 §1): a string is valid — any string, since the
            // panel probes PATH at click time and answers a miss with the
            // transient hint — but empty or padding-only is not a name, and
            // a non-string is a malformed value like any other.
            var parsed = Config.reloadOverrides({},
                '{"emoji_app":"emote"}')
            T.equal(parsed.error, "")
            T.deepEqual(parsed.value, { emojiApp: "emote" })

            var padded = Config.reloadOverrides({}, '{"emoji_app":"  emote  "}')
            T.equal(padded.error, "")
            T.deepEqual(padded.value, { emojiApp: "emote" })

            var previous = { emojiApp: "emote" }
            var empty = Config.reloadOverrides(previous, '{"emoji_app":""}')
            T.equal(empty.value, previous)
            T.equal(empty.error, "Invalid value for emoji_app")
            var paddedEmpty = Config.reloadOverrides(previous, '{"emoji_app":"   "}')
            T.equal(paddedEmpty.error, "Invalid value for emoji_app")
            var nonString = Config.reloadOverrides(previous, '{"emoji_app":7}')
            T.equal(nonString.value, previous)
            T.equal(nonString.error, "Invalid value for emoji_app")

            // And it round-trips under the file's snake_case name.
            T.equal(Config.serializeOverrides({ emojiApp: "xmoji" }),
                '{\n  "emoji_app": "xmoji"\n}\n')
        })

        T.test("sparse overrides merge over theme tokens and shipped fallbacks", function () {
            var parsed = Config.reloadOverrides({}, '{"sound":true,"accent_color":"#ff0000"}')
            var effective = Config.merge(Config.maintainerDefaults(), parsed.value, {
                keyRadius: 4,
                panelRadius: 6,
                keyBackground: "#111111",
                panelBackground: "#222222",
                textColor: "#eeeeee",
                accentColor: "#00ff00",
                borderColor: "#333333"
            })
            T.equal(parsed.error, "")
            T.equal(effective.sound, true)
            T.equal(effective.keyRadius, 4)
            T.equal(effective.accentColor, "#ff0000")
        })

        T.test("turning theme following off exposes shipped appearance fallbacks", function () {
            var effective = Config.merge(Config.maintainerDefaults(), { followTheme: false }, {
                accentColor: "#00ff00"
            })
            T.equal(effective.followTheme, false)
            T.equal(effective.accentColor, "#7aa2f7")
        })

        T.test("override serialization stays sparse and preserves future keys", function () {
            var overrides = Config.reloadOverrides({},
                '{"mode":"floating","future_setting":{"enabled":true}}').value
            T.equal(Config.serializeOverrides(overrides),
                '{\n  "mode": "floating",\n  "future_setting": {\n    "enabled": true\n  }\n}\n')
        })

        T.test("malformed override text preserves the last valid value", function () {
            var previous = { mode: "floating", sound: true }
            var out = Config.reloadOverrides(previous, '{"mode":')
            T.equal(out.value, previous)
            T.equal(out.error, "Invalid configuration JSON")
        })

        T.test("an empty overrides file is malformed, not an empty map", function () {
            // Truncating config.json to zero bytes is an external edit that
            // destroyed the file's content (§5): it must preserve the last
            // valid runtime and flag the error, exactly like any other
            // malformed text — reading `{}` here would silently clear every
            // override. Whitespace-only is the same file with padding.
            var previous = { mode: "floating", sound: true }
            var empty = Config.reloadOverrides(previous, "")
            T.equal(empty.value, previous)
            T.equal(empty.error, "Invalid configuration JSON")
            var padded = Config.reloadOverrides(previous, " \n\t ")
            T.equal(padded.value, previous)
            T.equal(padded.error, "Invalid configuration JSON")
            // The distinction is emptiness, not braces: an explicit empty
            // JSON object is a valid (if pointless) override map.
            var braces = Config.reloadOverrides(previous, "{}")
            T.equal(braces.error, "")
            T.deepEqual(braces.value, {})
        })

        T.test("an empty state file is malformed, not default state", function () {
            // Same fact for state.json: a zero-byte file is a destroyed
            // file, not an answer, so the remembered centre survives and
            // the error is flagged (missing files take defaults, and that
            // distinction is the FileView seam's, not the parser's).
            var previous = { center: { x: 12, y: 34 } }
            var empty = Config.reloadState(previous, "")
            T.equal(empty.value, previous)
            T.equal(empty.error, "Invalid state JSON")
        })

        T.test("invalid known overrides preserve the last valid value", function () {
            var previous = { sound: true }
            var out = Config.reloadOverrides(previous, '{"sound":"yes"}')
            T.equal(out.value, previous)
            T.equal(out.error, "Invalid value for sound")
        })

        T.test("appearance values validate as hex colours and whole-pixel radii", function () {
            // A named colour is a malformed value with the §5 preservation
            // semantics, not a guess to be accepted: the popover writes hex
            // and external edits are held to the same rule.
            var previous = { keyBackground: "#303030" }
            var named = Config.reloadOverrides(previous, '{"key_background":"red"}')
            T.equal(named.value, previous)
            T.equal(named.error, "Invalid value for key_background")

            // The hex forms validation accepts — 3, 4, 6 and 8 digits, any
            // case — map to their camelCase runtime names and keep their
            // written form for serialization. Swatches only ever write the
            // 6-digit form; the wider grammar is the external edit's.
            var parsed = Config.reloadOverrides({},
                '{"text_color":"#abc","accent_color":"#abcd",'
                + '"key_background":"#ABCDEF","border_color":"#abcdef01"}')
            T.equal(parsed.error, "")
            T.deepEqual(parsed.value, {
                textColor: "#abc",
                accentColor: "#abcd",
                keyBackground: "#ABCDEF",
                borderColor: "#abcdef01"
            })

            // Radii are whole pixels: the steppers step by one, and a
            // fractional or negative radius from an external edit is a
            // malformed value, not a rounding decision.
            var fractional = Config.reloadOverrides(previous, '{"key_radius":8.5}')
            T.equal(fractional.value, previous)
            T.equal(fractional.error, "Invalid value for key_radius")
            var negative = Config.reloadOverrides(previous, '{"panel_radius":-1}')
            T.equal(negative.value, previous)
            T.equal(negative.error, "Invalid value for panel_radius")
            // Zero is square keys, and the panel radius bound the popover
            // steppers to is a legal value.
            var squares = Config.reloadOverrides({}, '{"key_radius":0,"panel_radius":32}')
            T.deepEqual(squares.value, { keyRadius: 0, panelRadius: 32 })

            // Validation trims, so storage trims: a padded hex passes as the
            // same colour and must not come back padded from the panel's
            // own reads and serialization.
            var padded = Config.reloadOverrides({}, '{"accent_color":"  #7aa2f7  "}')
            T.equal(padded.error, "")
            T.deepEqual(padded.value, { accentColor: "#7aa2f7" })
        })

        T.test("a camelCase alias validates exactly like its canonical field", function () {
            // R5's root door: the camelCase runtime spelling of an approved
            // field used to fall through every predicate as an "unknown" key
            // and land raw in the override map (spec-v1.1 §5, 2026-09-06).
            // An alias is the same field, so the same rule applies — an
            // invalid alias is a malformed edit with the §5 preservation
            // semantics, never a silently accepted guess.
            var previous = { keyRadius: 8, sound: true }
            var cases = [
                ['{"keyRadius":-20}', "Invalid value for keyRadius"],
                ['{"keyRadius":9.5,"key_radius":8.5}', "Invalid value for keyRadius"],
                ['{"sizePreset":null}', "Invalid value for sizePreset"],
                ['{"size_preset":null}', "Invalid value for size_preset"],
                ['{"sizePreset":"huge"}', "Invalid value for sizePreset"],
                ['{"keyBackground":"red"}', "Invalid value for keyBackground"],
                ['{"textColor":7}', "Invalid value for textColor"],
                ['{"followTheme":1}', "Invalid value for followTheme"],
                ['{"sound":"yes"}', "Invalid value for sound"],
                ['{"emojiApp":""}', "Invalid value for emojiApp"],
                ['{"mode":" sideways"}', "Invalid value for mode"]
            ]
            for (var i = 0; i < cases.length; i++) {
                var out = Config.reloadOverrides(previous, cases[i][0])
                T.equal(out.value, previous)
                T.equal(out.error, cases[i][1])
            }

            // Valid aliases become the override under the runtime name, with
            // the same trimming the canonical spellings get.
            T.deepEqual(Config.reloadOverrides({},
                '{"keyRadius":12,"accentColor":" #00ff00 ","sound":true,'
                + '"emojiApp":" emote ","sizePreset":"x-large"}').value, {
                keyRadius: 12,
                accentColor: "#00ff00",
                sound: true,
                emojiApp: "emote",
                sizePreset: "x-large"
            })
        })

        T.test("canonical and camelCase collisions resolve canonically in both JSON orders", function () {
            // The exact R5 reproduction: whichever order the file names the
            // two spellings in, an invalid alias can neither override a
            // validated field nor ride through serialization as one. The
            // edit is malformed as a whole; the runtime keeps its last valid
            // map and the file keeps its exact text (the FileView never
            // writes while an error stands).
            var previous = { keyRadius: 8 }
            var orderA = Config.reloadOverrides(previous, '{"key_radius":8,"keyRadius":-20}')
            T.equal(orderA.value, previous)
            T.equal(orderA.error, "Invalid value for keyRadius")
            var orderB = Config.reloadOverrides(previous, '{"keyRadius":-20,"key_radius":8}')
            T.equal(orderB.value, previous)
            T.equal(orderB.error, "Invalid value for keyRadius")

            // Duplicate semantic names that both validate are deterministic
            // too: the canonical spelling wins, not the JSON order.
            var canonicalA = Config.reloadOverrides({}, '{"key_radius":8,"keyRadius":12}')
            T.equal(canonicalA.error, "")
            T.deepEqual(canonicalA.value, { keyRadius: 8 })
            var canonicalB = Config.reloadOverrides({}, '{"keyRadius":12,"key_radius":8}')
            T.equal(canonicalB.error, "")
            T.deepEqual(canonicalB.value, { keyRadius: 8 })
            // And the panel's own save therefore normalizes the file to the
            // one canonical value rather than whichever spelling came last.
            T.equal(Config.serializeOverrides(canonicalA.value),
                '{\n  "key_radius": 8\n}\n')
        })

        T.test("unknown fields stay verbatim and never serialize as canonical fields", function () {
            // Unknown keys ride along untouched: preserved across reload and
            // GUI save under their own names, never name-mapped through the
            // field table. A camelCase key that names no approved field is
            // just as unknown as a snake_case one — being camelCase grants
            // nothing, which is what closed R5.
            var overrides = Config.reloadOverrides({},
                '{"future_setting":{"enabled":true},"oddCamelName":-3,'
                + '"panelRadius":10}').value
            T.equal(Config.serializeOverrides(overrides),
                '{\n  "future_setting": {\n    "enabled": true\n  },'
                + '\n  "oddCamelName": -3,\n  "panel_radius": 10\n}\n')
            // The approved field the panel read back is still the validated
            // canonical value, not a second spelling with its own life.
            T.deepEqual(Config.merge(Config.maintainerDefaults(), overrides, null).panelRadius, 10)
        })

        T.test("keys the engine will not store as own properties cannot poison the map", function () {
            // JSON.parse makes "__proto__" an own property, but plain
            // assignment would re-point the map's prototype instead of
            // storing a value (or throws for a non-object), and V4 silently
            // loses assignments for a few Object.prototype names. None of
            // them can round-trip, so all of them are dropped, and nothing
            // inherited survives into serialization or merge. Whatever the
            // engine refuses is dropped by probe, not by a maintained name
            // list.
            var parsed = Config.reloadOverrides({},
                '{"__proto__":{"mode":"docked"},"hasOwnProperty":1,'
                + '"isPrototypeOf":true,"mode":"floating"}')
            T.equal(parsed.error, "")
            T.deepEqual(parsed.value, { mode: "floating" })
            T.equal(Object.getPrototypeOf(parsed.value), Object.prototype)
            T.equal(Config.serializeOverrides(parsed.value),
                '{\n  "mode": "floating"\n}\n')
            // A non-object "__proto__" is refused by the engine too, not a
            // crash on the load path.
            var primitive = Config.reloadOverrides({}, '{"__proto__":5,"mode":"floating"}')
            T.equal(primitive.error, "")
            T.deepEqual(primitive.value, { mode: "floating" })
            T.equal(Object.getPrototypeOf(primitive.value), Object.prototype)
        })

        T.test("toHex serializes the colour the popover displays", function () {
            T.equal(Config.toHex({ r: 1, g: 0.5, b: 0, a: 1 }), "#ff8000")
            // A translucent colour keeps its alpha — a hex field that showed
            // "#000000" for a transparent black would write back a colour
            // the file would not restore.
            T.equal(Config.toHex({ r: 0, g: 0, b: 0, a: 0 }), "#00000000")
            T.equal(Config.toHex({ r: 1, g: 1, b: 1 }), "#ffffff")
            T.equal(Config.toHex(null), "")
            T.equal(Config.toHex("#ff8000"), "")
        })

        T.test("valid external state reloads while malformed state is retained", function () {
            var first = Config.reloadState(Config.stateDefaults(), '{"center":{"x":12,"y":34}}')
            T.deepEqual(first.value, { center: { x: 12, y: 34 } })
            var malformed = Config.reloadState(first.value, '{"center":{"x":12}}')
            T.equal(malformed.value, first.value)
            T.equal(malformed.error, "Invalid value for center")
            // The pre-08 state file stored the dragged top-left under
            // "position"; with no migration promised (spec-v1.1 §5) it reads
            // as an absent centre — the card simply falls back to docked
            // placement rules instead of restoring a stale top-left.
            var legacy = Config.reloadState(Config.stateDefaults(), '{"position":{"x":12,"y":34}}')
            T.deepEqual(legacy.value, { center: null })
            T.equal(legacy.error, "")
        })

        T.test("state serialization cannot copy preferences into state", function () {
            T.equal(Config.serializeState({ center: { x: 5, y: 9 }, mode: "floating" }),
                '{\n  "center": {\n    "x": 5,\n    "y": 9\n  }\n}\n')
        })

        // ---- the curated symbols page (spec-v1.1 §3, decisions §17) ----
        //
        // Availability is decided by a reverse index over the keycap
        // pipeline's own symbolMap: a curated entry is a keysym token, and it
        // is enabled only when some position and level of the complete active
        // keymap carries it. The tests below drive that pure layer with
        // synthetic keymaps.
        //
        // floatingAnchor has no seam case here on purpose: its round-trip
        // identity is geometry, and geometry is host/guest evidence owned by
        // ticket 08 (spec-v1.1 §8, §15), not configuration parsing.

        T.test("the reverse index maps a token to its first position and level", function () {
            var index = Layout.buildTokenIndex({
                AE01: ["one", "EuroSign"],
                AE10: ["", "EuroSign"],
                AB01: ["mu", "NoSymbol"],
                AD01: ["copyright"]
            })
            T.deepEqual(index["EuroSign"], { position: "AE01", level: 2 })
            T.deepEqual(index["mu"], { position: "AB01", level: 1 })
            T.deepEqual(index["copyright"], { position: "AD01", level: 1 })
            T.equal(index.hasOwnProperty("NoSymbol"), false)
            // The index is the keymap's complete answer; curation picks from
            // it, so a token outside the palette is still indexed.
            T.deepEqual(index["one"], { position: "AE01", level: 1 })
        })

        T.test("the reverse index reads every level the keymap carries", function () {
            var index = Layout.buildTokenIndex({ AE03: ["three", "numerosign", "section", "U20B4"] })
            T.deepEqual(index["U20B4"], { position: "AE03", level: 4 })
            T.deepEqual(index["section"], { position: "AE03", level: 3 })
        })

        T.test("the curated palette is exactly the shipped category sequence", function () {
            // The ticket's table: currency, mathematics, typography, brackets,
            // legal marks, common — every name a real keysym, in a fixed
            // order that filtering never reorders.
            T.deepEqual(Layout.curatedTokens, [
                "EuroSign", "sterling", "yen", "cent", "currency", "U20B4",
                "plusminus", "multiply", "division", "degree", "notsign",
                "approximate", "notequal", "lessthanequal", "greaterthanequal",
                "onehalf", "onequarter", "threequarters", "twosuperior",
                "threesuperior", "infinity",
                "guillemotleft", "guillemotright", "emdash", "endash", "ellipsis",
                "leftsinglequotemark", "rightsinglequotemark",
                "leftdoublequotemark", "rightdoublequotemark",
                "leftsingleanglequotemark", "rightsingleanglequotemark",
                "copyright", "registered", "trademark", "section", "numerosign",
                "mu", "brokenbar"
            ])
            T.equal(Layout.curatedMinimum, 8)
        })

        T.test("every shipped curated token draws its own character", function () {
            // Expected characters are the worked source: the codepoints in
            // xkbcommon's keysym header, written out here literally.
            var expected = {
                EuroSign: "\u20ac", sterling: "\u00a3", yen: "\u00a5",
                cent: "\u00a2", currency: "\u00a4", U20B4: "\u20b4",
                plusminus: "\u00b1", multiply: "\u00d7", division: "\u00f7",
                degree: "\u00b0", notsign: "\u00ac", approximate: "\u2248",
                notequal: "\u2260", lessthanequal: "\u2264",
                greaterthanequal: "\u2265", onehalf: "\u00bd",
                onequarter: "\u00bc", threequarters: "\u00be",
                twosuperior: "\u00b2", threesuperior: "\u00b3",
                infinity: "\u221e",
                guillemotleft: "\u00ab", guillemotright: "\u00bb",
                emdash: "\u2014", endash: "\u2013", ellipsis: "\u2026",
                leftsinglequotemark: "\u2018", rightsinglequotemark: "\u2019",
                leftdoublequotemark: "\u201c", rightdoublequotemark: "\u201d",
                leftsingleanglequotemark: "\u2039",
                rightsingleanglequotemark: "\u203a",
                copyright: "\u00a9", registered: "\u00ae", trademark: "\u2122",
                section: "\u00a7", numerosign: "\u2116",
                mu: "\u00b5", brokenbar: "\u00a6"
            }
            for (var i = 0; i < Layout.curatedTokens.length; i++) {
                var token = Layout.curatedTokens[i]
                var misses = []
                var overlay = Layout.capOverlay({ k: "AE05", lvl: 1 }, [token], misses)
                T.equal(overlay.t, expected[token])
                T.equal(misses.length, 0)
            }
            // And a token found on an AltGr level draws from that level.
            var level3 = Layout.capOverlay({ k: "AB08", lvl: 3 },
                ["less", "greater", "guillemotleft", "leftdoublequotemark"], [])
            T.equal(level3.t, "\u00ab")
        })

        T.test("a base-only dual cap keeps the stacked shape and stays enabled", function () {
            // symbols v2 renders dual caps stacked; a shifted level that
            // resolves to nothing leaves the pair one-sided — the flag, not
            // a resolved `s`, is what the panel's isDualKey reads, so the
            // cap stays stacked and enabled with its miss reported.
            var misses = []
            var cap = Layout.capOverlay({ k: "AD11", dual: true },
                ["bracketleft", ""], misses)
            T.equal(cap.t, "[")
            T.equal(cap.hasOwnProperty("s"), false)
            T.equal(cap.hasOwnProperty("unavailable"), false)
            T.equal(misses.length, 1)
        })

        T.test("an unresolved level marks the cap unavailable instead of blank and clickable", function () {
            // Spec-v1.1 §3: a visible cap must never be silently blank. A
            // valid partial keymap can leave a hole where one level resolves
            // to nothing; the overlay marks the cap so the panel draws it
            // dim and refuses its press, while the miss still reaches the
            // §11 report. Fixed-label caps and spacers are never marked.
            var misses = []
            var hole = Layout.capOverlay({ k: "AE01", lvl: 2 }, ["one", ""], misses)
            T.equal(hole.t, "")
            T.equal(hole.unavailable, true)
            T.equal(misses.length, 1)
            var absent = Layout.capOverlay({ k: "AE02", lvl: 1 }, [], [])
            T.equal(absent.unavailable, true)
            var resolved = Layout.capOverlay({ k: "AE03", lvl: 2 },
                ["three", "numbersign"], [])
            T.equal(resolved.t, "#")
            T.equal(resolved.hasOwnProperty("unavailable"), false)
        })

        T.test("the symbols page's dual caps draw both levels from the keymap", function () {
            // Symbols v2 (2026-09-05): the page's caps are main-page caps
            // with both levels taken from the compiled keymap — the stacked
            // shifted/base pair the main page draws, with the level typed
            // following Shift. No built-in character behind either level.
            var pair = Layout.capOverlay({ k: "AD11", dual: true },
                ["bracketleft", "braceleft"], [])
            T.equal(pair.t, "[")
            T.equal(pair.s, "{")
            T.equal(pair.hasOwnProperty("unavailable"), false)

            // Digits: the top row types them without leaving the page, one
            // press either way. (A compiled keymap names the digit keysyms
            // as the bare character and the shifted form by keysym name.)
            var digit = Layout.capOverlay({ k: "AE01", dual: true }, ["1", "exclam"], [])
            T.equal(digit.t, "1")
            T.equal(digit.s, "!")

            // A level the keymap does not carry is a per-cap miss, and the
            // level that resolves still draws.
            var misses = []
            var hole = Layout.capOverlay({ k: "AB08", dual: true }, ["comma", ""], misses)
            T.equal(hole.t, ",")
            T.equal(hole.hasOwnProperty("s"), false)
            T.deepEqual(misses, ["AB08^=<no symbol at this level>"])

            // Neither level resolving marks the cap unavailable — dim,
            // press-refusing, never a silent blank — with both holes
            // reported.
            var both = []
            var dead = Layout.capOverlay({ k: "AB09", dual: true }, [], both)
            T.equal(dead.hasOwnProperty("t"), false)
            T.equal(dead.hasOwnProperty("s"), false)
            T.equal(dead.unavailable, true)
            T.deepEqual(both, ["AB09=<no keymap entry>", "AB09^=<no keymap entry>"])
        })

        T.test("every symbols-page cap is keymap-only and dual", function () {
            // The page's declaration itself: no `lvl` caps (that shape is
            // the curated page's), no built-in t/s a stale table could fall
            // back to — what the page draws is what this session's keymap
            // answered, or a reported hole. Thirteen top-row positions plus
            // the eight punctuation positions carry the dual shape.
            var rows = Layout.symbolRows("ABC")
            var duals = 0
            for (var r = 0; r < rows.length; r++) {
                for (var c = 0; c < rows[r].length; c++) {
                    var cap = rows[r][c]
                    T.equal(cap.hasOwnProperty("lvl"), false)
                    if (cap.dual === true) {
                        duals += 1
                        T.equal(cap.hasOwnProperty("t"), false)
                        T.equal(cap.hasOwnProperty("s"), false)
                    }
                }
            }
            T.equal(duals, 21)
        })

        T.test("an incomplete keymap keeps the table order, pads with invisible spacers, and keeps its controls", function () {
            // EuroSign from the currency category, then section and
            // numerosign from the legal marks: three survivors, everything
            // between them in the table unavailable.
            var page = Layout.curatedPageRows({
                AE04: ["four", "EuroSign"],
                AE03: ["three", "numerosign", "section"]
            })
            T.equal(page.available, 3)
            // Three survivors fill only the first content row, but the rows
            // carrying the page's fixed caps are drawn regardless (R2): a
            // page that dropped Shift/Enter left a locked Shift held with
            // its control hidden and no Enter to come back with.
            T.equal(page.rows.length, 3)
            var row = page.rows[0]
            T.equal(row[1].k, "AE04")
            T.equal(row[1].lvl, 2)
            // The exact marker is what tells the reducer a curated cap
            // types its own level, latch or no latch.
            T.equal(row[1].exact, true)
            T.equal(row[2].k, "AE03")
            T.equal(row[2].lvl, 3)
            // Slots the keymap cannot fill are invisible spacers that keep
            // the row on the grid; the rest of the row is exactly the row's
            // fixed caps.
            var spacers = 0
            for (var c = 0; c < row.length; c++) {
                if (Layout.isSpacer(row[c])) {
                    spacers += 1
                    T.equal(row[c].spacer, true)
                    T.equal(row[c].hasOwnProperty("k"), false)
                    T.equal(row[c].hasOwnProperty("label"), false)
                }
            }
            T.equal(spacers, 10)
            // The middle row is the control row: Shift and Enter with
            // declared spacers between — visible Shift state, a direct
            // unlock, and a way back, at any availability.
            var mid = page.rows[1]
            T.equal(mid[0].key, "shift")
            T.equal(mid[mid.length - 1].key, "Return")
            for (var m = 1; m < mid.length - 1; m++)
                T.equal(Layout.isSpacer(mid[m]), true)
            // The only row after it is the command row.
            T.deepEqual(page.rows[2], Layout.commandRow("ABC"))
        })

        T.test("filtering never reorders the surviving symbols", function () {
            var subset = {}
            for (var i = 0; i < Layout.curatedTokens.length; i++) {
                var token = Layout.curatedTokens[i]
                // Drop "yen" and everything from "multiply" through
                // "endash": the survivors must keep their relative order.
                if (token !== "yen" && !(i >= 7 && i <= 25))
                    subset["K" + (i < 10 ? "0" + i : i)] = [token, ""]
            }
            var page = Layout.curatedPageRows(subset)
            var flat = []
            for (var r = 0; r < page.rows.length - 1; r++)
                for (var c = 0; c < page.rows[r].length; c++)
                    // Level caps only: the rows' fixed anchors carry labels,
                    // the spacers carry nothing, and neither is a slot.
                    if (page.rows[r][c].k) flat.push(page.rows[r][c].k)
            var wanted = []
            for (var i = 0; i < Layout.curatedTokens.length; i++)
                if (subset.hasOwnProperty("K" + (i < 10 ? "0" + i : i)))
                    wanted.push("K" + (i < 10 ? "0" + i : i))
            T.deepEqual(flat, wanted)
        })

        T.test("seven available symbols are reported below the page threshold", function () {
            var few = {}
            for (var i = 0; i < 7; i++) few["K0" + i] = [Layout.curatedTokens[i], ""]
            var page = Layout.curatedPageRows(few)
            T.equal(page.available, 7)
            T.equal(page.available < Layout.curatedMinimum, true)
        })

        // ---- the colour rows' recommended swatches and the hex draft ----
        //
        // The 2026-09-06 amendment's pure layer: which swatches a theme
        // recommends, and the one normal form an Apply button commits
        // through. Presentation rides on these in Panel.qml; here they are
        // pinned as module logic beside the rest of Config.js's contract.

        T.test("recommended swatches answer theme colours in fixed order, lowercased", function () {
            // One swatch per theme source — background, foreground, accent,
            // muted — in that order, as the resolved lowercase hex the rows
            // compare overrides against.
            T.deepEqual(Config.recommendedSwatches({
                background: { r: 0.125, g: 0.125, b: 0.125, a: 1 },
                foreground: { r: 1, g: 1, b: 1, a: 1 },
                accent: { r: 1, g: 0.5, b: 0, a: 1 },
                muted: { r: 0, g: 0, b: 0, a: 1 }
            }), ["#202020", "#ffffff", "#ff8000", "#000000"])
        })

        T.test("unanswered theme tokens fall back to maintained swatch colours", function () {
            // A token nobody answered (transparent — Theme.colorAnswered's
            // rule), a null, a missing key, or no theme at all leaves the
            // maintained fallback standing for that source; the recommendation
            // is never an invisible swatch.
            var transparent = { r: 0, g: 0, b: 0, a: 0 }
            T.deepEqual(Config.recommendedSwatches({
                background: transparent, foreground: null, muted: transparent
            }), ["#202020", "#f5f5f5", "#7aa2f7", "#5a5a5a"])
            T.deepEqual(Config.recommendedSwatches(null),
                ["#202020", "#f5f5f5", "#7aa2f7", "#5a5a5a"])
        })

        T.test("duplicate resolved swatch colours collapse in source order", function () {
            var grey = { r: 0.5, g: 0.5, b: 0.5, a: 1 }
            T.deepEqual(Config.recommendedSwatches({
                background: grey, foreground: grey, accent: grey, muted: grey
            }), ["#808080"])
            T.deepEqual(Config.recommendedSwatches({
                background: { r: 1, g: 1, b: 1, a: 1 },
                foreground: { r: 1, g: 1, b: 1, a: 1 },
                accent: { r: 0, g: 0, b: 0, a: 1 },
                muted: { r: 1, g: 1, b: 1, a: 1 }
            }), ["#ffffff", "#000000"])
        })

        T.test("hex draft normalizes to the colour grammar before Apply", function () {
            // Bare digits gain the '#'; whitespace is trimmed; the accepted
            // forms are exactly isColor's — #RGB, #RGBA, #RRGGBB, #AARRGGBB,
            // any case. The written form survives normalization so an
            // external file's own casing is not rewritten by a round trip.
            T.deepEqual(Config.normalizeHexDraft(" a55555 "), { ok: true, value: "#a55555" })
            T.deepEqual(Config.normalizeHexDraft("#ABCDEF"), { ok: true, value: "#ABCDEF" })
            T.deepEqual(Config.normalizeHexDraft("#abc"), { ok: true, value: "#abc" })
            T.deepEqual(Config.normalizeHexDraft("12345678"), { ok: true, value: "#12345678" })
            T.deepEqual(Config.normalizeHexDraft("#12345678"), { ok: true, value: "#12345678" })
            // Incomplete, empty, absent and non-hex drafts are refused — the
            // caller keeps the field editable and writes nothing.
            T.equal(Config.normalizeHexDraft("#ab").ok, false)
            T.equal(Config.normalizeHexDraft("#12345").ok, false)
            T.equal(Config.normalizeHexDraft("").ok, false)
            T.equal(Config.normalizeHexDraft(null).ok, false)
            T.equal(Config.normalizeHexDraft("red").ok, false)
        })

        Qt.exit(T.report("configuration"))
    }
}
