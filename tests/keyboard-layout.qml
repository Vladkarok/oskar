// The keycap pipeline driven as a pure module:
// what rows the page declares for what the keymap resolved, and what each cap
// draws versus what its press types (ticket 03, review findings R2 and R3).
// Run with tools/run-tests.sh — no compositor, no display. The real-keymap
// end of the same question is answered in the nested-session evidence run;
// this suite pins the rules the module must keep whatever a keymap says.
import QtQml
import "../KeyboardLayout.js" as Layout
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        // ---- synthetic keymaps shaped like the real ones ----
        //
        // The review measured the real compiled maps at 18 (ua), 26 (gb) and
        // 23 (fr) available curated symbols; the counts are not the point —
        // the row rule is. `mapOf` spreads the first `count` curated tokens
        // over distinct positions at levels 1..4, the same shape the real
        // pipeline's symbolMap carries, so curatedPageRows sees exactly what
        // it sees in production.
        function directSymbolFacts() {
            var glyphs = [
                "!", "1", "@", "2", "#", "3", "$", "4",
                "%", "5", "^", "6", "&", "7", "*", "8",
                "(", "9", ")", "0", "`", "-", "=", "[",
                "]", "{", "}", "\\", "|", ";", ":", "'",
                "\"", ",", ".", "/", "_", "+", "<", ">",
                "?", "~", "£", "€", "¥", "¢", "°", "±",
                "×", "≈", "÷", "≠", "¬", "≤", "≥", "∞"
            ]
            // The shape the helper actually installs (decisions §33): the
            // catalogue on levels five to eight of positions that keep their
            // own levels one to four. This fixture is the hard case — a
            // layout carrying NOTHING of its own, so every cap has to come
            // out of the block — and `usDigitRowFacts` below is the ordinary
            // one, where the layout already answers and the block is not
            // reached for.
            var facts = {}
            for (var i = 0; i < glyphs.length; i += 4) {
                facts[Layout.reservedPositions[i / 4]] = [
                    { none: "" }, { none: "" }, { none: "" }, { none: "" },
                    { text: glyphs[i] }, { text: glyphs[i + 1] },
                    { text: glyphs[i + 2] }, { text: glyphs[i + 3] }
                ]
            }
            return facts
        }

        function usDigitRowFacts() {
            var glyphs = [
                "!", "1", "@", "2", "#", "3", "$", "4",
                "%", "5", "^", "6", "&", "7", "*", "8",
                "(", "9", ")", "0", "`", "-", "=", "[",
                "]", "{", "}", "\\", "|", ";", ":", "'",
                "\"", ",", ".", "/", "_", "+", "<", ">",
                "?", "~", "£", "€", "¥", "¢", "°", "±",
                "×", "≈", "÷", "≠", "¬", "≤", "≥", "∞"
            ]
            var digits = "1234567890"
            var symbols = "!@#$%^&*()"
            var facts = {}
            for (var i = 0; i < glyphs.length; i += 4) {
                var position = Layout.reservedPositions[i / 4]
                var own = [{ none: "" }, { none: "" }, { none: "" }, { none: "" }]
                var slot = i / 4
                if (slot < 10)
                    own = [{ text: digits[slot] }, { text: symbols[slot] },
                           { none: "" }, { none: "" }]
                facts[position] = own.concat([
                    { text: glyphs[i] }, { text: glyphs[i + 1] },
                    { text: glyphs[i + 2] }, { text: glyphs[i + 3] }
                ])
            }
            return facts
        }

        function controlRowIndex(rows) {
            for (var i = 0; i < rows.length; i++) {
                var hasShift = false
                var hasEnter = false
                for (var j = 0; j < rows[i].length; j++) {
                    if (rows[i][j].key === "shift") hasShift = true
                    if (rows[i][j].key === "Return") hasEnter = true
                }
                if (hasShift && hasEnter) return i
            }
            return -1
        }

        function escapeRowIndex(rows) {
            for (var i = 0; i < rows.length; i++) {
                var hasEsc = false
                var hasBack = false
                for (var j = 0; j < rows[i].length; j++) {
                    if (rows[i][j].key === "Escape") hasEsc = true
                    if (rows[i][j].key === "BackSpace") hasBack = true
                }
                if (hasEsc && hasBack) return i
            }
            return -1
        }

        // ---- R2: the page keeps its essential controls at any availability ----

        // ---- R3: an exact cap draws exactly the level it types ----

        // ---- the moved display rule, pinned at its new single home ----

        T.test("letter caps still swap case under Shift and Caps exactly as before", function () {
            var q = { chr: "q", chrShift: "Q" }
            T.equal(Layout.charUnderModifiers(q, false, false), "q")
            T.equal(Layout.charUnderModifiers(q, false, true), "Q")
            T.equal(Layout.charUnderModifiers(q, true, false), "Q")
            // Caps and Shift together cancel back to lowercase — the rule the
            // panel has always drawn letters with (caps !== shift).
            T.equal(Layout.charUnderModifiers(q, true, true), "q")
        })

        T.test("caps alone still does not shift a non-letter paired cap", function () {
            var dash = { chr: "-", chrShift: "_" }
            T.equal(Layout.charUnderModifiers(dash, false, false), "-")
            T.equal(Layout.charUnderModifiers(dash, false, true), "_")
            T.equal(Layout.charUnderModifiers(dash, true, false), "-")
            T.equal(Layout.charUnderModifiers(dash, true, true), "_")
        })

        T.test("isLetterKey keeps its rule: capital-of-base is a letter, é/2 is not", function () {
            T.equal(Layout.isLetterKey({ chr: "q", chrShift: "Q" }), true)
            T.equal(Layout.isLetterKey({ chr: "\u0430", chrShift: "\u0410" }), true)  // Cyrillic а/А
            T.equal(Layout.isLetterKey({ chr: "\u00e9", chrShift: "\u00c9" }), true)  // é/É
            // The French é key is not a letter pair: Caps alone types the
            // base é — never É, never 2 — while Shift alone types 2. Asking
            // merely whether the base has a capital would have made Caps
            // behave as if this key were É's.
            T.equal(Layout.isLetterKey({ chr: "\u00e9", chrShift: "2" }), false)
            T.equal(Layout.isLetterKey({ chr: "2", chrShift: "@" }), false)
            T.equal(Layout.isLetterKey({ chr: "-", chrShift: "" }), false)
            T.equal(Layout.isLetterKey({ chr: "", chrShift: "Q" }), false)
        })

        // ---- ticket 04: the helper-facts (text) overlay path ----

        T.test("a dual cap draws both helper text levels stacked", function () {
            var misses = []
            var overlay = Layout.capOverlay(
                { k: "AE01", dual: true },
                [{ text: "1" }, { text: "!" }], misses)
            T.equal(overlay.chr, "1")
            T.equal(overlay.chrShift, "!")
            T.equal(misses.length, 0)
        })

        T.test("a helper level with nothing to draw is a miss and can disable the cap", function () {
            var misses = []
            var overlay = Layout.capOverlay(
                { xkb: "TLDE", dual: true },
                [{ text: "`" }, { none: "" }], misses)
            T.equal(overlay.chr, "`")
            T.equal(overlay.chrShift, undefined)
            T.equal(misses.length, 1)
            T.equal(misses[0], "TLDE^=<no symbol at this level>")
            // Both levels unanswered: dim and press-refusing, never blank
            // and typeable (spec-v1.1 \u00a73) — same as the token path.
            var misses2 = []
            var gone = Layout.capOverlay(
                { xkb: "TLDE", dual: true },
                [{ none: "dead_acute" }, { none: "" }], misses2)
            T.equal(gone.unavailable, true)
            T.equal(misses2.length, 2)
            T.equal(misses2[0], "TLDE=dead_acute")
        })

        T.test("a main-page pair keeps its built-in level where the helper has none", function () {
            var misses = []
            var overlay = Layout.capOverlay(
                { xkb: "AD01", chr: "q", chrShift: "Q" },
                [{ text: "\u0439" }, { none: "" }], misses)
            T.equal(overlay.chr, "\u0439")
            T.equal(overlay.chrShift, undefined)
            T.equal(misses.length, 1)
        })

        T.test("a glyph cap resolves by character, at whatever level carries it", function () {
            // Ticket 18. The cap names a character; the keymap says where it
            // lives. Level 3 and 4 additionally ask for <LVL3> rather than
            // RALT, because RALT is ISO_Level3_Shift only on some layouts.
            var facts = {
                AE05: [{ text: "5" }, { text: "%" }, { none: "" }, { none: "" }],
                AB11: [{ text: "£" }, { text: "¥" }, { text: "°" }, { text: "×" }]
            }
            var resolved = Layout.applyLanguage(
                [[{ glyph: "£" }, { glyph: "°" }, { glyph: "%" }, { glyph: "\u2603" }]],
                "us", facts)[0]
            T.equal(resolved[0].xkb, "AB11")
            // baseLvl, not lvl: the press reads baseLvl for the unshifted
            // half, and lvl is the curated page's single-level cap shape.
            T.equal(resolved[0].baseLvl, 1)
            T.equal(resolved[0].exact, true)
            T.equal(resolved[0].level3, false)
            T.equal(resolved[0].chr, "£")
            // Level three: same position, and the chord must move off RALT.
            T.equal(resolved[1].baseLvl, 3)
            T.equal(resolved[1].level3, true)
            // A character the active layout already carries resolves there —
            // the cap does not care which source supplied it.
            T.equal(resolved[2].xkb, "AE05")
            T.equal(resolved[2].baseLvl, 2)
            // And one nothing carries is dim and press-refusing, not blank.
            T.equal(resolved[3].unavailable, true)
            T.equal(resolved[3].chr, "\u2603")
        })

        T.test("a glyph cap whose base is missing refuses its Shift half too", function () {
            // The cap is gated as a whole — `disabled` refuses the press — so
            // an upper glyph drawn over an unavailable base would promise a
            // character the cap cannot type. Both halves are reported, because
            // a page silently losing caps on a keymap with fewer free
            // positions is exactly how this goes unnoticed.
            var facts = { AB11: [{ text: "\u00a5" }] }
            var resolved = Layout.applyLanguage(
                [[{ glyph: "\u00a3", shiftGlyph: "\u00a5" }]], "us", facts)[0][0]
            T.equal(resolved.unavailable, true)
            T.equal(resolved.chr, "\u00a3")
            T.equal(resolved.chrShift, undefined)
            T.equal(resolved.xkbShift, undefined)
            T.equal(resolved.dual, undefined)
        })

        T.test("the glyph index takes the first occurrence, in position order", function () {
            // A character two positions can produce must always resolve to
            // the same chord, or the cap would move when something unrelated
            // to it changed.
            var index = Layout.buildGlyphIndex({
                I149: [{ text: "£" }],
                AB11: [{ text: "£" }, { text: "¥" }]
            })
            T.equal(index["£"].position, "AB11")
            T.equal(index["£"].level, 1)
            T.equal(index["¥"].level, 2)
            // Levels five to eight are where the block lives now (decisions
            // §33), so they are indexed and they carry the level the press
            // needs. Past eight is past every chord the panel has.
            var deep = Layout.buildGlyphIndex({
                AB11: [{ none: "" }, { none: "" }, { none: "" }, { none: "" },
                       { text: "☃" }, { none: "" }, { none: "" }, { text: "∞" },
                       { text: "☂" }]
            })
            T.equal(deep["☃"].level, 5)
            T.equal(deep["∞"].level, 8)
            T.equal(deep["☂"], undefined)
            T.equal(Object.keys(Layout.buildGlyphIndex(null)).length, 0)
        })

        T.test("applyLanguage draws every positioned cap from the helper facts", function () {
            // One source since ticket 18. The second — the §11 pipeline's
            // symbolMap, which fed `token` and `lvl` caps — is gone, so a
            // positioned cap and a glyph cap both resolve against the same
            // facts and can never disagree about the keymap.
            var facts = {
                AD01: [{ text: "\u0439" }, { text: "\u0419" }],
                AD02: [{ text: "\u0446" }, { text: "\u0426" },
                       { text: "\u20b4" }, { none: "" }]
            }
            var resolved = Layout.applyLanguage(
                [[{ chr: "q", chrShift: "Q", xkb: "AD01" }, { glyph: "\u20b4" }]], "ua", facts)
            T.equal(resolved[0][0].chr, "\u0439")
            T.equal(resolved[0][0].chrShift, "\u0419")
            // The glyph cap found its character at level 3 of AD02 and asks
            // for the level-three chord rather than a position of its own.
            T.equal(resolved[0][1].chr, "\u20b4")
            T.equal(resolved[0][1].xkb, "AD02")
            T.equal(resolved[0][1].baseLvl, 3)
            T.equal(resolved[0][1].level3, true)
        })

        T.test("applyLanguage with no helper facts keeps built-ins and stays quiet", function () {
            // Facts in flight or unresolved: the built-in table draws as the
            // gated last resort and the status line owns the reason — that
            // window must not log a per-cap miss flood on every rebuild.
            var resolved = Layout.applyLanguage(
                [[{ chr: "q", chrShift: "Q", xkb: "AD01" }]], "ua", null)
            T.equal(resolved[0][0].chr, "q")
            T.equal(resolved[0][0].chrShift, "Q")
        })

        T.test("applyLanguage with helper facts misses a missing position loudly", function () {
            var resolved = Layout.applyLanguage(
                [[{ chr: "q", chrShift: "Q", xkb: "AD01" }, { chr: "w", chrShift: "W", xkb: "AD02" }]],
                "ua", { AD01: [{ text: "\u0439" }, { text: "\u0419" }] })
            T.equal(resolved[0][0].chr, "\u0439")
            // AD02 has no record at all: built-in kept, miss recorded.
            T.equal(resolved[0][1].chr, "w")
        })

        // ---- ticket 12: pair caps on &123 (compact-control-map.md) ----

        function unitsLeftOf(row, key) {
            var sum = 0
            for (var i = 0; i < row.length; i++) {
                if (row[i].key === key) return sum
                sum += row[i].w || 1
            }
            return -1
        }

        function shiftEnterRow(rows) {
            var i = controlRowIndex(rows)
            return i >= 0 ? rows[i] : []
        }

        function pairKeys(row) {
            var out = []
            for (var i = 0; i < row.length; i++) {
                if (row[i].pair === true) out.push(row[i].xkb)
            }
            return out
        }

        function spacerCount(row) {
            var n = 0
            for (var i = 0; i < row.length; i++) {
                if (Layout.isSpacer(row[i])) n += 1
            }
            return n
        }

        function rowSum(row) {
            var sum = 0
            for (var i = 0; i < row.length; i++) sum += row[i].w || 1
            return sum
        }

        // ua's 12 pair positions in curated-token category order
        // (docs/compact-control-map.md §2.2 / §3.2).
        var uaPairOrder = [
            "AE04", "AE03", "AE12", "AE05", "AE02", "AB08", "AB09", "AE11",
            "AB10", "AB03", "AD04", "AB06"
        ]

        function uaSymbolMap() {
            return {
                RALT: ["ISO_Level3_Shift", "", "", ""],
                AE04: ["4", "quotedbl", "", "EuroSign"],
                AE03: ["3", "numerosign", "section", "U20B4"],
                AE12: ["equal", "percent", "notequal", "plusminus"],
                AE05: ["5", "colon", "degree", ""],
                AE02: ["2", "quotedbl", "twosuperior", ""],
                AB08: ["Cyrillic_be", "Cyrillic_BE", "guillemotleft", ""],
                AB09: ["Cyrillic_yu", "Cyrillic_YU", "guillemotright",
                    "leftdoublequotemark"],
                AE11: ["minus", "underscore", "emdash", "endash"],
                AB10: ["period", "comma", "", "ellipsis"],
                AB03: ["Cyrillic_es", "Cyrillic_ES", "copyright", ""],
                AD04: ["Cyrillic_ka", "Cyrillic_KA", "registered", ""],
                AB06: ["Cyrillic_te", "Cyrillic_TE", "trademark", ""],
                // One curated token already one-click at block L1 (not a pair).
                AC10: ["numerosign", "", "", ""]
            }
        }

        T.test("letters stay five rows and the command row is unchanged", function () {
            T.equal(Layout.rows.length, 5)
            T.deepEqual(Layout.rows[4], Layout.commandRow("&123"))
            T.equal(Layout.rows[0][0].key, "Escape")
            T.equal(Layout.rows[0][2].xkb, "AE01")
        })

        T.test("direct symbols keep the five-row grid and fixed control geometry", function () {
            var rows = Layout.symbolRows("ABC")
            T.equal(rows.length, 5)
            T.deepEqual(rows[4], Layout.commandRow("ABC"))
            for (var i = 0; i < rows.length; i++)
                T.equal(Math.abs(rowSum(rows[i]) - 15.5) < 0.01, true)
            T.equal(rows[0][0].key, "Escape")
            T.equal(rows[0][0].w, Layout.rows[0][0].w)
            T.equal(unitsLeftOf(rows[0], "BackSpace"), 14)
            T.equal(rows[0][rows[0].length - 1].w, 1.5)
            T.equal(rows[1][0].key, "Tab")
            T.equal(rows[1][0].w, Layout.rows[1][0].w)
            T.equal(unitsLeftOf(rows[1], "Delete"), 14.5)
            T.equal(unitsLeftOf(rows[2], "Return"), 13)
            T.equal(rows[2][rows[2].length - 1].w, 2.5)
            T.equal(rows[3][0].key, "shift")
            T.equal(rows[3][0].w, Layout.rows[3][0].w)
            T.equal(unitsLeftOf(rows[3], "Up"), 12.5)
            T.equal(rows[3][rows[3].length - 1].key, "shift")
            T.equal(rows[3][rows[3].length - 1].w,
                Layout.rows[3][Layout.rows[3].length - 1].w)
            // Both pages are five rows, which is what the panel reserves
            // height for. The curated page's own maximum used to be a third
            // term here; it went with the page (ticket 05).
            T.equal(Math.max(Layout.rows.length, rows.length), 5)
        })

        T.test("top symbols shift to digits with exact level chords", function () {
            var rows = Layout.applyLanguage(Layout.symbolRows("ABC"), "ua",
                directSymbolFacts())
            var symbols = "!@#$%^&*()"
            var digits = "1234567890"
            for (var i = 0; i < 10; i++) {
                var cap = rows[0][i + 1]
                T.equal(cap.chr, symbols[i])
                T.equal(cap.chrShift, digits[i])
                T.equal(cap.xkb, Layout.reservedPositions[Math.floor(i / 2)])
                T.equal(cap.xkbShift, cap.xkb)
                T.equal(cap.baseLvl, (i % 2) * 2 + 5)
                T.equal(cap.slvl, (i % 2) * 2 + 6)
                T.equal(cap.exact, true)
                // Levels 7 and 8 want <LVL3> on top of <LVL5>; 5 and 6 do
                // not. `level5` is not a cap field — the press derives it
                // from the level through Layout.levelChord.
                T.equal(cap.level3, (i % 2) === 1)
                T.equal(cap.shiftLevel3, (i % 2) === 1)
                T.equal(Layout.levelChord(cap.baseLvl).level5, true)
                T.equal(Layout.levelChord(cap.slvl).level5, true)
                // Exact glyph pairs choose the half in Keyboard.typeCap;
                // their two resolved chords are the contract here.
                T.equal(cap.chr, symbols[i])
                T.equal(cap.chrShift, digits[i])
            }
        })

        T.test("the layout answers first and the block only for what it lacks", function () {
            // Level-major ordering (decisions §33). The block sits on levels
            // five to eight of positions the layout already uses, so a
            // position-major index would find `@` in the catalogue on AE01
            // before finding it on AE02's own Shift level and send
            // <LVL5>+<LVL3> for a character plain Shift types. On a `us`-
            // shaped keymap the ten digit/symbol duals must all come out of
            // the layout's own two levels.
            var rows = Layout.applyLanguage(Layout.symbolRows("ABC"), "us",
                usDigitRowFacts())
            for (var i = 0; i < 10; i++) {
                var cap = rows[0][i + 1]
                // The page draws the symbol on the base and the digit behind
                // Shift, so the base is the layout's level 2 and the Shift
                // half is its level 1.
                T.equal(cap.baseLvl, 2, "symbol " + i + " is a level-2 press")
                T.equal(cap.slvl, 1, "digit " + i + " is a level-1 press")
                T.equal(Layout.levelChord(cap.baseLvl).level5, false)
                T.equal(Layout.levelChord(cap.slvl).level5, false)
                T.equal(cap.level3, false)
                T.equal(cap.shiftLevel3, false)
            }
            // And the characters no layout carries still come from the block,
            // which is the half that has to keep working.
            var index = Layout.buildGlyphIndex(usDigitRowFacts())
            var glyphs = ["£", "€", "¥", "¢", "°", "±", "×", "≈", "÷", "≠"]
            for (var g = 0; g < glyphs.length; g++) {
                T.equal(index[glyphs[g]] !== undefined, true, glyphs[g] + " resolves")
                T.equal(Layout.levelChord(index[glyphs[g]].level).level5, true,
                    glyphs[g] + " comes from the block")
            }
        })

        T.test("symbols Fn swaps Home and End for explicit media caps only", function () {
            var plain = Layout.symbolRows("ABC")
            var fn = Layout.symbolFunctionRows("ABC")
            T.deepEqual(fn[0], Layout.functionRow)
            // Found by key, not by index: the symbol slots moved this row's
            // shape once already, and an index swap replaced two glyph caps
            // instead of Home and End.
            var slotOf = function (row, key) {
                for (var i = 0; i < row.length; i++) {
                    if (row[i].key === key) return i
                }
                return -1
            }
            var home = slotOf(plain[3], "Home")
            var end = slotOf(plain[3], "End")
            T.equal(home !== -1 && end !== -1, true)
            T.deepEqual(fn[3][home], { label: "⏮", key: "XF86AudioPrev", w: 1 })
            T.deepEqual(fn[3][end], { label: "⏭", key: "XF86AudioNext", w: 1 })
            T.equal(Layout.positionForKeysym(fn[3][home].key), "I173")
            T.equal(Layout.positionForKeysym(fn[3][end].key), "I171")
            // Nothing else on the row was touched — the glyph caps in
            // particular are still glyph caps under Fn.
            T.equal(slotOf(fn[3], "Home"), -1)
            T.equal(fn[3][1].glyph, "£")
            T.equal(Math.abs(rowSum(fn[3]) - 15.5) < 0.01, true)
            T.equal(fn[0][2].key, "F1")
            T.equal(fn[0][13].key, "F12")
        })

        // ---- ticket 22: the Super cap's mark is a setting ----
        //
        // The pure arm choice Keyboard.qml draws by: the word is the default
        // and the landing place for everything undrawable — an unknown
        // setting string, and the Omarchy glyph when its private font is
        // absent. Rendering shape and proportion of the three drawn marks is
        // invisible to this suite (decisions §36) and stays for the owner's
        // eyes; what is pinned here is that every answer names an arm that
        // draws something.

        T.test("the Super cap draws the word by default and on anything unknown", function () {
            T.equal(Layout.superMarkArm("word", true), "word")
            T.equal(Layout.superMarkArm("word", false), "word")
            // The store rejects these values; the QML still treats one as
            // the word so nothing can ever draw a blank cap.
            T.equal(Layout.superMarkArm("tux", true), "word")
            T.equal(Layout.superMarkArm("Super", true), "word")
            T.equal(Layout.superMarkArm("", false), "word")
            T.equal(Layout.superMarkArm(undefined, true), "word")
            T.equal(Layout.superMarkArm(7, true), "word")
        })

        T.test("the Omarchy arm answers on the font gate alone", function () {
            T.equal(Layout.superMarkArm("omarchy", true), "omarchy")
            // The packaged TTF absent: the word, never a blank cap
            // (decisions §27 as amended) — the gate stays attached to this
            // arm and to no other.
            T.equal(Layout.superMarkArm("omarchy", false), "word")
        })

        T.test("the three drawn marks draw whatever the font answers", function () {
            // The inline vectors carry no font dependency, so the gate that
            // guards the glyph arm has nothing to say about them.
            var marks = ["windows", "macos", "penguin"]
            for (var i = 0; i < marks.length; i++) {
                T.equal(Layout.superMarkArm(marks[i], true), marks[i])
                T.equal(Layout.superMarkArm(marks[i], false), marks[i])
            }
        })

        Qt.exit(T.report("keyboard layout"))
    }
}
