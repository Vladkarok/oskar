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
                emojiCloseAfterPick: false,
                emojiPageSize: "medium",
                // Ticket 28: typing is the default delivery.
                emojiDelivery: "direct",
                // The Super cap says what the key is (ticket 22).
                superMark: "word",
                keyRadius: 8,
                panelRadius: 12,
                keyBackground: "#303030",
                panelBackground: "#202020",
                textColor: "#f5f5f5",
                accentColor: "#7aa2f7",
                borderColor: "#5a5a5a"
            })
            T.deepEqual(Config.stateDefaults(), {
                center: null, emojiUsage: [], emojiSkinTone: "",
                layoutGroup: 0, layoutDevice: ""
            })
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

        T.test("emoji page preferences validate and stay sparse", function () {
            var parsed = Config.reloadOverrides({},
                '{"emoji_close_after_pick":true,"emoji_page_size":"x-large"}')
            T.deepEqual(parsed.value, {
                emojiCloseAfterPick: true, emojiPageSize: "x-large"
            })
            T.equal(Config.serializeOverrides(parsed.value),
                '{\n  "emoji_close_after_pick": true,'
                + '\n  "emoji_page_size": "x-large"\n}\n')
            T.equal(Config.reloadOverrides({}, '{"emoji_page_size":"small"}').error,
                "Invalid value for emoji_page_size")
            T.equal(Config.reloadOverrides({}, '{"emoji_close_after_pick":1}').error,
                "Invalid value for emoji_close_after_pick")
        })

        T.test("emoji usage state preserves exact sequences and validates its bound", function () {
            var text = '{"center":null,"emoji_usage":['
                + '{"emoji":"👨‍👩‍👧","count":3,"lastUsed":9}]}'
            var parsed = Config.reloadState(Config.stateDefaults(), text)
            T.equal(parsed.error, "")
            T.deepEqual(parsed.value.emojiUsage,
                [{ emoji: "👨‍👩‍👧", count: 3, lastUsed: 9 }])
            T.equal(parsed.value.emojiSkinTone, "")
            T.equal(Config.serializeState(parsed.value).indexOf("👨‍👩‍👧") >= 0, true)
            T.equal(Config.reloadState(parsed.value,
                '{"emoji_usage":[{"emoji":"x","count":0,"lastUsed":1}]}').error,
                "Invalid value for emoji_usage")
            var records = []
            for (var i = 0; i < 65; i++)
                records.push({ emoji: "e" + i, count: 1, lastUsed: i + 1 })
            T.equal(Config.reloadState(parsed.value,
                JSON.stringify({ emoji_usage: records })).error,
                "Invalid value for emoji_usage")
        })

        T.test("emoji delivery mode is direct or clipboard, direct by default", function () {
            // Ticket 28: the explicit mode for clients that drop the typed
            // routes. The canonical name and its camelCase alias validate
            // identically; anything else is a malformed edit with the §5
            // preservation semantics.
            var modes = ["direct", "clipboard"]
            for (var i = 0; i < modes.length; i++) {
                var parsed = Config.reloadOverrides({},
                    '{"emoji_delivery":"' + modes[i] + '"}')
                T.equal(parsed.error, "")
                T.deepEqual(parsed.value, { emojiDelivery: modes[i] })
                T.equal(Config.serializeOverrides(parsed.value),
                    '{\n  "emoji_delivery": "' + modes[i] + '"\n}\n')
            }

            var previous = { emojiDelivery: "direct" }
            var unknown = Config.reloadOverrides(previous,
                '{"emoji_delivery":"paste"}')
            T.equal(unknown.value, previous)
            T.equal(unknown.error, "Invalid value for emoji_delivery")
            var aliasOk = Config.reloadOverrides({}, '{"emojiDelivery":"clipboard"}')
            T.equal(aliasOk.error, "")
            T.deepEqual(aliasOk.value, { emojiDelivery: "clipboard" })
            var aliasBad = Config.reloadOverrides(previous,
                '{"emojiDelivery":"emote"}')
            T.equal(aliasBad.value, previous)
            T.equal(aliasBad.error, "Invalid value for emojiDelivery")
        })

        T.test("emoji skin tone is validated UI state, not an override", function () {
            var parsed = Config.reloadState(Config.stateDefaults(),
                '{"emoji_skin_tone":"🏽"}')
            T.equal(parsed.error, "")
            T.equal(parsed.value.emojiSkinTone, "🏽")
            T.equal(Config.serializeState(parsed.value).indexOf(
                '"emoji_skin_tone": "🏽"') >= 0, true)
            T.equal(Config.reloadState(parsed.value,
                '{"emoji_skin_tone":"blue"}').error,
                "Invalid value for emoji_skin_tone")
            T.equal(Config.configField("emoji_skin_tone"), null)
        })

        T.test("the Super mark is one of five words, the word by default", function () {
            // Ticket 22: what the Super cap draws is a preference in the same
            // validated store as the rest. The popover offers five marks and
            // nothing else is one; the canonical snake_case name and its
            // camelCase alias are the same field with the same rule.
            var marks = ["word", "omarchy", "windows", "macos", "penguin"]
            for (var i = 0; i < marks.length; i++) {
                var parsed = Config.reloadOverrides({}, '{"super_mark":"' + marks[i] + '"}')
                T.equal(parsed.error, "")
                T.deepEqual(parsed.value, { superMark: marks[i] })
                T.equal(Config.serializeOverrides(parsed.value),
                    '{\n  "super_mark": "' + marks[i] + '"\n}\n')
            }

            // An unknown value is a malformed edit with the §5 preservation
            // semantics — the last valid map stands, the file is not touched.
            // The QML independently treats an unknown string as the word, so
            // a value that could not reach the file cannot blank the cap.
            var previous = { superMark: "penguin" }
            var unknown = Config.reloadOverrides(previous, '{"super_mark":"tux"}')
            T.equal(unknown.value, previous)
            T.equal(unknown.error, "Invalid value for super_mark")
            var nonString = Config.reloadOverrides(previous, '{"super_mark":7}')
            T.equal(nonString.value, previous)
            T.equal(nonString.error, "Invalid value for super_mark")

            // Alias spellings validate identically.
            var aliasOk = Config.reloadOverrides({}, '{"superMark":"windows"}')
            T.equal(aliasOk.error, "")
            T.deepEqual(aliasOk.value, { superMark: "windows" })
            var aliasBad = Config.reloadOverrides(previous, '{"superMark":"tux"}')
            T.equal(aliasBad.value, previous)
            T.equal(aliasBad.error, "Invalid value for superMark")
            // Duplicate semantic names resolve canonically in both orders.
            var canonicalA = Config.reloadOverrides(
                {}, '{"super_mark":"word","superMark":"macos"}')
            T.deepEqual(canonicalA.value, { superMark: "word" })
            var canonicalB = Config.reloadOverrides(
                {}, '{"superMark":"macos","super_mark":"word"}')
            T.deepEqual(canonicalB.value, { superMark: "word" })

            // Sparse: nothing materializes the default — a fresh install's
            // file carries no super_mark at all, and merge answers the
            // maintained default for it.
            var absent = Config.reloadOverrides({}, "{}")
            T.equal(absent.error, "")
            T.equal(Config.owns(absent.value, "superMark"), false)
            T.equal(Config.serializeOverrides(absent.value), "{}\n")
            var effective = Config.merge(Config.maintainerDefaults(), absent.value, null)
            T.equal(effective.superMark, "word")
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
            T.equal(Config.toHex({ r: 0.102, g: 0.106, b: 0.149, a: 0.999 }),
                "#1a1b26")
            T.equal(Config.toHex(null), "")
            T.equal(Config.toHex("#ff8000"), "")
        })

        T.test("valid external state reloads while malformed state is retained", function () {
            var first = Config.reloadState(Config.stateDefaults(), '{"center":{"x":12,"y":34}}')
            T.deepEqual(first.value, {
                center: { x: 12, y: 34 }, emojiUsage: [], emojiSkinTone: "",
                layoutGroup: 0, layoutDevice: ""
            })
            var malformed = Config.reloadState(first.value, '{"center":{"x":12}}')
            T.equal(malformed.value, first.value)
            T.equal(malformed.error, "Invalid value for center")
            // The pre-08 state file stored the dragged top-left under
            // "position"; with no migration promised (spec-v1.1 §5) it reads
            // as an absent centre — the card simply falls back to docked
            // placement rules instead of restoring a stale top-left.
            var legacy = Config.reloadState(Config.stateDefaults(), '{"position":{"x":12,"y":34}}')
            T.deepEqual(legacy.value, {
                center: null, emojiUsage: [], emojiSkinTone: "",
                layoutGroup: 0, layoutDevice: ""
            })
            T.equal(legacy.error, "")
        })

        T.test("state serialization cannot copy preferences into state", function () {
            T.equal(Config.serializeState({ center: { x: 5, y: 9 }, mode: "floating" }),
                '{\n  "center": {\n    "x": 5,\n    "y": 9\n  },'
                + '\n  "emoji_usage": [],'
                + '\n  "emoji_skin_tone": "",'
                + '\n  "layout_group": 0,'
                + '\n  "layout_device": ""\n}\n')
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

        T.test("a base-only dual cap keeps the stacked shape and stays enabled", function () {
            // symbols v2 renders dual caps stacked; a shifted level that
            // resolves to nothing leaves the pair one-sided — the flag, not
            // a resolved `s`, is what the panel's isDualKey reads, so the
            // cap stays stacked and enabled with its miss reported.
            //
            // Levels arrive as the helper's resolved facts, which is the only
            // shape there is since ticket 05 retired the keysym-token path.
            var misses = []
            var cap = Layout.capOverlay({ k: "AD11", dual: true },
                [{ text: "[" }, { none: "" }], misses)
            T.equal(cap.t, "[")
            T.equal(cap.hasOwnProperty("s"), false)
            T.equal(cap.hasOwnProperty("unavailable"), false)
            T.equal(misses.length, 1)
        })

        T.test("the symbols page's dual caps draw both levels from the keymap", function () {
            // Symbols v2 (2026-09-05): the page's caps are main-page caps
            // with both levels taken from the compiled keymap — the stacked
            // shifted/base pair the main page draws, with the level typed
            // following Shift. No built-in character behind either level.
            var pair = Layout.capOverlay({ k: "AD11", dual: true },
                [{ text: "[" }, { text: "{" }], [])
            T.equal(pair.t, "[")
            T.equal(pair.s, "{")
            T.equal(pair.hasOwnProperty("unavailable"), false)

            // Digits: the top row types them without leaving the page, one
            // press either way.
            var digit = Layout.capOverlay({ k: "AE01", dual: true },
                [{ text: "1" }, { text: "!" }], [])
            T.equal(digit.t, "1")
            T.equal(digit.s, "!")

            // A level the keymap does not carry is a per-cap miss, and the
            // level that resolves still draws.
            var misses = []
            var hole = Layout.capOverlay({ k: "AB08", dual: true },
                [{ text: "," }, { none: "" }], misses)
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

        T.test("direct symbols page declares ten digit and five special glyph pairs", function () {
            var rows = Layout.symbolRows("ABC")
            T.equal(rows.length, 5)
            var duals = 0
            for (var r = 0; r < rows.length; r++) {
                for (var c = 0; c < rows[r].length; c++) {
                    var cap = rows[r][c]
                    T.equal(cap.pair === true, false)
                    if (cap.shiftGlyph) {
                        duals += 1
                        T.equal(!!cap.glyph, true)
                        T.equal(cap.hasOwnProperty("lvl"), false)
                    }
                }
            }
            T.equal(duals, 15)
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

        T.test("hex Apply holds a valid draft while config is unhealthy", function () {
            // Enter and the Apply button share one decision: an invalid
            // draft is refused inline; a valid draft is not committed — and
            // not treated as applied — while a malformed external edit
            // stands; only a healthy config commits.
            T.deepEqual(Config.commitHexDraft("#a55555", true),
                { action: "commit", value: "#a55555" })
            T.deepEqual(Config.commitHexDraft(" a55555 ", true),
                { action: "commit", value: "#a55555" })
            T.deepEqual(Config.commitHexDraft("#a55555", false),
                { action: "hold", value: "#a55555" })
            T.equal(Config.commitHexDraft("#ab", true).action, "reject")
            T.equal(Config.commitHexDraft("#ab", false).action, "reject")
            T.equal(Config.commitHexDraft("", true).action, "reject")
        })

        T.test("hex-edit dismiss drops item focus so hide cannot recapture keys", function () {
            // Spec-v1.1 §5: ending the typed-hex exception returns the
            // surface to WlrKeyboardFocus.None and leaves no focused
            // TextInput. Custom/Cancel/outside clicks are dismissals too.
            // A hide that still leaves a hex field focused hands Qt focus
            // to a row field (beginHexEdit recaptures OSK keys) or keeps
            // the caret after the pad is gone (letters go to the last app).
            T.deepEqual(Config.hexEditRelease(), {
                hexEditing: false,
                hexEditField: "",
                dropItemFocus: true
            })
        })

        // Key hover/press fills (live-host ticket 01): mix the resting cap
        // toward the foreground; never replace the cap with the foreground.
        T.test("key hover mix is a modest lift; press is stronger and not white", function () {
            T.equal(Config.keyHoverMix(0.08), 0.08)
            T.equal(Config.keyHoverMix(1), 0.16)
            T.equal(Config.keyPressMix(0.22, 0.08), 0.22)
            T.equal(Config.keyPressMix(1, 0.16), 0.32)
            T.equal(Config.keyPressMix(0.10, 0.08) > Config.keyHoverMix(0.08), true)

            var rest = { r: 0.125, g: 0.125, b: 0.125 }
            var fg = { r: 0.96, g: 0.96, b: 0.96 }
            var hover = Config.mixRgb(rest, fg, Config.keyHoverMix(0.08))
            var press = Config.mixRgb(rest, fg, Config.keyPressMix(0.22, 0.08))
            T.equal(hover.a, 1)
            T.equal(press.a, 1)
            T.equal(hover.r > rest.r, true)
            T.equal(press.r > hover.r, true)
            T.equal(hover.r < 0.4, true)
            T.equal(press.r < 0.5, true)

            // A pinned mid-grey key-background must not bleach on hover
            // even if the theme's overlay alpha is 1.
            var pinned = { r: 0.19, g: 0.19, b: 0.19 }
            var pinnedHover = Config.mixRgb(pinned, fg, Config.keyHoverMix(1))
            T.equal(pinnedHover.r < 0.4, true)

            // Host override #0ad4d4d4: light RGB at ~4% alpha. Mixing the
            // raw RGB toward white is a solid pale cap. Composite onto the
            // panel first so rest and hover stay a key of the theme.
            var panel = { r: 0.08, g: 0.09, b: 0.12, a: 1 }
            var thinLight = { r: 0.831, g: 0.831, b: 0.831, a: 0.039 }
            var restOnPanel = Config.compositeOnto(panel, thinLight)
            T.equal(restOnPanel.a, 1)
            T.equal(restOnPanel.r < 0.2, true)
            var thinHover = Config.mixRgb(restOnPanel, fg, Config.keyHoverMix(1))
            T.equal(thinHover.r < 0.4, true)
            T.equal(Config.compositeOnto(panel, { r: 0.2, g: 0.2, b: 0.2, a: 1 }).r,
                0.2)
            // Custom Apply writes a hex string. That must round-trip, not
            // collapse to #000000 in the settings row.
            var fromHex = Config.compositeOnto(panel, "#dcdcdc")
            T.equal(Config.toHex(fromHex).toLowerCase(), "#dcdcdc")
        })

        // Paste chip (live-host ticket 02): classify CLIPBOARD types; flatten
        // a text payload to a single-line preview. Elision is the chip width.
        T.test("clipboard kinds hide empty, preview text, and keep a glyph for non-text", function () {
            T.equal(Config.clipboardKind("", 1), "empty")
            T.equal(Config.clipboardKind("Nothing is copied\n", 1), "empty")
            T.equal(Config.clipboardKind("text/plain\ntext/html\n", 0), "text")
            T.equal(Config.clipboardKind("UTF8_STRING\n", 0), "text")
            T.equal(Config.clipboardKind("text/uri-list\n", 0), "text")
            T.equal(Config.clipboardKind("image/png\nimage/jpeg\n", 0), "other")
            T.equal(Config.clipboardKind("text/html\nimage/png\n", 0), "other")
            T.equal(Config.clipboardKind("text/plain\nimage/png\n", 0), "other")
            T.equal(Config.clipboardKind("text/uri-list\ntext/plain\n", 0), "text")
            T.equal(Config.pastePreviewText("http://172.25.30.242/\n"),
                "http://172.25.30.242/")
            T.equal(Config.pastePreviewText("a\nb\tc"), "a b c")
            T.equal(Config.pastePreviewText(""), "")
        })

        // Chip visibility is types-kind + preview + whether wl-paste
        // --no-newline succeeded. Text stays hidden until a non-empty
        // preview exists (adversarial 81d138b: no 30px flash, no glyph
        // for whitespace, no leftover "text" on a failed paste).
        T.test("paste chip hides until a non-empty text preview exists", function () {
            T.equal(Config.pasteChipKind("empty", "", false), "empty")
            T.equal(Config.pasteChipKind("other", "", false), "other")
            T.equal(Config.pasteChipKind("other", "not a preview", true), "other")
            T.equal(Config.pasteChipKind("text", "", false), "empty")
            T.equal(Config.pasteChipKind("text", "", true), "empty")
            T.equal(Config.pasteChipKind("text", "   \n\t", true), "empty")
            T.equal(Config.pasteChipKind("text", "http://172.25.30.242/", false),
                "empty")
            T.equal(Config.pasteChipKind("text", "http://172.25.30.242/", true),
                "text")
        })

        // Key radius (live-host ticket 04): 0–24 is a medium-key proportion;
        // the drawn radius scales with the size preset so 24 stays a circle.
        T.test("key radius 24 scales with the size preset", function () {
            T.equal(Config.SIZE_PRESET_SCALES.medium, 1)
            T.equal(Config.SIZE_PRESET_SCALES.large, 1.2)
            T.equal(Config.SIZE_PRESET_SCALES["x-large"], 1.45)
            T.equal(Config.effectiveKeyRadius(24, 1), 24)
            T.equal(Math.round(Config.effectiveKeyRadius(24, 1.2) * 10), 288)
            T.equal(Math.round(Config.effectiveKeyRadius(24, 1.45) * 100), 3480)
            T.equal(Config.effectiveKeyRadius(0, 1.45), 0)
        })

        // Custom colour editor (live-host ticket 07): HS square + V slider
        // keep RGB/HSV/hex in sync. Worked example is the WinUI reference
        // swatch #34CF2B (R 52, G 207, B 43).
        T.test("hsv and rgb round-trip the WinUI green and keep hex in sync", function () {
            var rgb = { r: 52 / 255, g: 207 / 255, b: 43 / 255 }
            var hsv = Config.rgbToHsv(rgb.r, rgb.g, rgb.b)
            T.equal(Math.round(hsv.h * 360), 117)
            T.equal(Math.round(hsv.s * 100), 79)
            T.equal(Math.round(hsv.v * 100), 81)
            T.equal(Config.toHex(Config.hsvToRgb(hsv.h, hsv.s, hsv.v)).toLowerCase(),
                "#34cf2b")
            var grey = Config.rgbToHsv(0.5, 0.5, 0.5)
            T.equal(grey.h, 0)
            T.equal(grey.s, 0)
            T.equal(Config.toHex(Config.hsvToRgb(0, 0, 1)).toLowerCase(), "#ffffff")
            T.equal(Config.toHex(Config.hsvToRgb(0, 0, 0)).toLowerCase(), "#000000")
        })

        T.test("RGB and HSV channel parse refuses empty and out of range", function () {
            T.deepEqual(Config.parseChannel("52", 255), { ok: true, value: 52 })
            T.deepEqual(Config.parseChannel("360", 360), { ok: true, value: 360 })
            T.equal(Config.parseChannel("256", 255).ok, false)
            T.equal(Config.parseChannel("361", 360).ok, false)
            T.equal(Config.parseChannel("", 255).ok, false)
            T.equal(Config.parseChannel("12.5", 255).ok, false)
            T.equal(Math.round(Config.channelUnit(117, 360) * 1000), 325)
            T.equal(Config.channelUnit(255, 255), 1)
        })

        T.test("colour-field insert replaces a selection and respects max length", function () {
            function mock(text) {
                return {
                    text: text,
                    cursorPosition: text.length,
                    selectionStart: 0,
                    selectionEnd: 0,
                    maximumLength: 9,
                    get length() { return this.text.length },
                    remove: function (s, e) {
                        this.text = this.text.slice(0, s) + this.text.slice(e)
                        this.cursorPosition = s
                        this.selectionStart = s
                        this.selectionEnd = s
                    },
                    insert: function (pos, chunk) {
                        this.text = this.text.slice(0, pos) + chunk + this.text.slice(pos)
                        this.cursorPosition = pos + chunk.length
                        this.selectionStart = this.cursorPosition
                        this.selectionEnd = this.cursorPosition
                    },
                    selectAll: function () {
                        this.selectionStart = 0
                        this.selectionEnd = this.text.length
                        this.cursorPosition = this.text.length
                    }
                }
            }
            var field = mock("#000000")
            Config.fieldSelectAll(field)
            Config.fieldInsert(field, "#34cf2b")
            T.equal(field.text, "#34cf2b")
            var clipped = mock("")
            clipped.maximumLength = 4
            Config.fieldInsert(clipped, "#34cf2b")
            T.equal(clipped.text, "#34c")
        })

        Qt.exit(T.report("configuration"))
    }
}
