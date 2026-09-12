// The curated page's half of the keycap pipeline, driven as a pure module:
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
        var slotPositions = [
            "AE01", "AE02", "AE03", "AE04", "AE05", "AE06",
            "AE07", "AE08", "AE09", "AE10", "AE11", "AE12",
            "AD01", "AD02", "AD03", "AD04", "AD05", "AD06",
            "AD07", "AD08", "AD09", "AD10", "AD11", "AD12",
            "AC01", "AC02", "AC03", "AC04", "AC05", "AC06",
            "AC07", "AC08", "AC09", "AC10", "AB01", "AB02",
            "AB03", "AB04", "AB05", "AB06", "AB07", "AB08",
            "AB09", "AB10", "BKSL", "TLDE"
        ]

        function mapOf(count) {
            var map = {}
            var next = 0
            for (var p = 0; p < slotPositions.length && next < count; p++) {
                var levels = []
                for (var l = 0; l < 4 && next < count; l++) {
                    levels.push(Layout.curatedTokens[next])
                    next += 1
                }
                while (levels.length < 4) levels.push("")
                map[slotPositions[p]] = levels
            }
            return map
        }

        function expectedSlot(n) {
            return { k: slotPositions[Math.floor(n / 4)], lvl: (n % 4) + 1 }
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

        T.test("the Shift/Enter row survives 18 available symbols (ua's count)", function () {
            var page = Layout.curatedPageRows(mapOf(18))
            T.equal(page.available, 18)
            T.equal(controlRowIndex(page.rows) >= 0, true)
        })

        T.test("the Shift/Enter row survives 26 and 23 available symbols (gb, fr)", function () {
            T.equal(controlRowIndex(Layout.curatedPageRows(mapOf(26)).rows) >= 0, true)
            T.equal(controlRowIndex(Layout.curatedPageRows(mapOf(23)).rows) >= 0, true)
        })

        T.test("the Shift/Enter control row exists with no symbol left for it", function () {
            // 18 symbols fill the 13-slot first row and 5 of the 15-slot
            // second row: the control row itself resolves nothing, which is
            // exactly the shape where it used to vanish and a locked Shift
            // stayed held with its control hidden.
            var page = Layout.curatedPageRows(mapOf(18))
            var index = controlRowIndex(page.rows)
            T.equal(index >= 0, true)
            // Everything between Shift and Enter is a declared spacer: the
            // row draws its two controls and no blank cap.
            for (var j = 0; j < page.rows[index].length; j++) {
                var cap = page.rows[index][j]
                if (cap.key !== "shift" && cap.key !== "Return")
                    T.equal(Layout.isSpacer(cap), true)
            }
        })

        T.test("the esc/Backspace row survives too; a control-free empty row is still omitted", function () {
            // Ten symbols fill only the first content row: the second row
            // carries no control cap and nothing resolved to it, so it stays
            // omitted — but both fixed-control rows are there.
            var page = Layout.curatedPageRows(mapOf(10))
            T.equal(page.available, 10)
            T.equal(escapeRowIndex(page.rows) >= 0, true)
            T.equal(controlRowIndex(page.rows) >= 0, true)
            T.equal(page.rows.length, 3)  // esc row, Shift/Enter row, command row
        })

        T.test("the eight-symbol availability threshold is unchanged", function () {
            T.equal(Layout.curatedMinimum, 8)
            var page = Layout.curatedPageRows(mapOf(8))
            T.equal(page.available, 8)
            // esc row + Shift/Enter row + command row: the control rows are
            // kept, the control-free second row is dropped at this fill.
            T.equal(page.rows.length, 3)
            T.equal(controlRowIndex(page.rows), 1)
            T.equal(page.available < Layout.curatedMinimum, false)
            T.equal(Layout.curatedPageRows(mapOf(7)).available < Layout.curatedMinimum, true)
        })

        T.test("every curated row still sums to the shared 15.5-unit grid", function () {
            var counts = [8, 10, 18, 23, 26, 37]
            for (var c = 0; c < counts.length; c++) {
                var rows = Layout.curatedPageRows(mapOf(counts[c])).rows
                for (var i = 0; i < rows.length; i++) {
                    var sum = 0
                    for (var j = 0; j < rows[i].length; j++) sum += rows[i][j].w || 1
                    T.equal(Math.abs(sum - 15.5) < 0.01, true)
                }
            }
        })

        T.test("no availability grows the page past its declared maximum height", function () {
            var counts = [8, 10, 18, 23, 26, Layout.curatedTokens.length]
            for (var c = 0; c < counts.length; c++) {
                var rows = Layout.curatedPageRows(mapOf(counts[c])).rows
                T.equal(rows.length <= Layout.curatedMaxRows, true)
            }
        })

        T.test("symbol order is stable: tokens fill slots in declaration order", function () {
            function firstLevelCap(page) {
                for (var r = 0; r < page.rows.length; r++) {
                    for (var s = 0; s < page.rows[r].length; s++) {
                        if (page.rows[r][s].lvl) return page.rows[r][s]
                    }
                }
                return null
            }

            // The n-th available token takes the n-th slot, whatever that
            // slot's row: the category sequence never reorders (decisions
            // §17). The expected position/level is mapOf's own spread.
            var counts = [8, 10, 18, 23, 26]
            for (var c = 0; c < counts.length; c++) {
                var page = Layout.curatedPageRows(mapOf(counts[c]))
                var seen = 0
                for (var i = 0; i < page.rows.length; i++) {
                    for (var j = 0; j < page.rows[i].length; j++) {
                        var cap = page.rows[i][j]
                        if (!cap.lvl) continue
                        var want = expectedSlot(seen)
                        T.equal(cap.k, want.k, "token " + seen + " position")
                        T.equal(cap.lvl, want.lvl, "token " + seen + " level")
                        T.equal(cap.exact, true, "token " + seen + " exact")
                        seen += 1
                    }
                }
                T.equal(seen, counts[c])
            }
            // And the very first slot carries the very first token's answer.
            T.equal(firstLevelCap(Layout.curatedPageRows(mapOf(18))).k, "AE01")
            T.equal(firstLevelCap(Layout.curatedPageRows(mapOf(18))).lvl, 1)
        })

        T.test("buildTokenIndex skips empty and NoSymbol levels and keeps the first occurrence", function () {
            var index = Layout.buildTokenIndex({
                AE01: ["EuroSign", "", "NoSymbol", ""],
                AE02: ["EuroSign", "sterling"]
            })
            T.equal(index.EuroSign.position, "AE01")
            T.equal(index.EuroSign.level, 1)
            T.equal(index.sterling.position, "AE02")
            T.equal(index.sterling.level, 2)
            T.equal(index.hasOwnProperty("NoSymbol"), false)
        })

        // ---- R3: an exact cap draws exactly the level it types ----

        T.test("a level-1 curated cap carries no paired shift glyph", function () {
            // The French shape that was the finding: TLDE resolves
            // twosuperior at level 1 and asciitilde at level 2. The overlay
            // used to attach the level-2 symbol as the cap's shifted variant,
            // so a latched or locked Shift redrew ² as ~ while the exact
            // press went on typing ².
            var misses = []
            var overlay = Layout.capOverlay(
                { k: "TLDE", lvl: 1, exact: true },
                ["twosuperior", "asciitilde", "notsign", "notsign"], misses)
            T.equal(overlay.t, "\u00b2")
            T.equal(overlay.s, undefined)
            T.equal(misses.length, 0)
        })

        T.test("levels 2, 3 and 4 draw exactly their own level's symbol", function () {
            var levels = ["twosuperior", "asciitilde", "notsign", "notsign"]
            var wants = [
                { lvl: 2, t: "~" },
                { lvl: 3, t: "\u00ac" },
                { lvl: 4, t: "\u00ac" }
            ]
            for (var i = 0; i < wants.length; i++) {
                var misses = []
                var overlay = Layout.capOverlay(
                    { k: "TLDE", lvl: wants[i].lvl, exact: true }, levels, misses)
                T.equal(overlay.t, wants[i].t, "level " + wants[i].lvl + " draws its level")
                T.equal(overlay.s, undefined, "level " + wants[i].lvl + " carries no pair")
                T.equal(misses.length, 0)
            }
        })

        T.test("an exact cap draws its own symbol under every Shift and Caps combination", function () {
            // The rule the seam exists for: display follows the exact press,
            // not the modifiers. Shift (latched or locked) and Caps are the
            // cap's business only through the level it already carries.
            var cap = { k: "TLDE", lvl: 1, exact: true, t: "\u00b2", s: "~" }
            T.equal(Layout.resolvedTypedChar(cap, false, false), "\u00b2")
            T.equal(Layout.resolvedTypedChar(cap, false, true), "\u00b2")
            T.equal(Layout.resolvedTypedChar(cap, true, false), "\u00b2")
            T.equal(Layout.resolvedTypedChar(cap, true, true), "\u00b2")
            var higher = { k: "AE03", lvl: 4, exact: true, t: "\u00b3" }
            T.equal(Layout.resolvedTypedChar(higher, false, true), "\u00b3")
            T.equal(Layout.resolvedTypedChar(higher, true, true), "\u00b3")
        })

        T.test("an unresolved curated level still draws blank and is marked unavailable", function () {
            var misses = []
            var overlay = Layout.capOverlay({ k: "AB01", lvl: 2, exact: true }, [], misses)
            T.equal(overlay.t, "")
            T.equal(overlay.unavailable, true)
            T.equal(misses.length, 1)
            T.equal(misses[0], "AB01^=<no keymap entry>")
        })

        // ---- the moved display rule, pinned at its new single home ----

        T.test("letter caps still swap case under Shift and Caps exactly as before", function () {
            var q = { t: "q", s: "Q" }
            T.equal(Layout.resolvedTypedChar(q, false, false), "q")
            T.equal(Layout.resolvedTypedChar(q, false, true), "Q")
            T.equal(Layout.resolvedTypedChar(q, true, false), "Q")
            // Caps and Shift together cancel back to lowercase — the rule the
            // panel has always drawn letters with (caps !== shift).
            T.equal(Layout.resolvedTypedChar(q, true, true), "q")
        })

        T.test("caps alone still does not shift a non-letter paired cap", function () {
            var dash = { t: "-", s: "_" }
            T.equal(Layout.resolvedTypedChar(dash, false, false), "-")
            T.equal(Layout.resolvedTypedChar(dash, false, true), "_")
            T.equal(Layout.resolvedTypedChar(dash, true, false), "-")
            T.equal(Layout.resolvedTypedChar(dash, true, true), "_")
        })

        T.test("isLetterKey keeps its rule: capital-of-base is a letter, é/2 is not", function () {
            T.equal(Layout.isLetterKey({ t: "q", s: "Q" }), true)
            T.equal(Layout.isLetterKey({ t: "\u0430", s: "\u0410" }), true)  // Cyrillic а/А
            T.equal(Layout.isLetterKey({ t: "\u00e9", s: "\u00c9" }), true)  // é/É
            // The French é key is not a letter pair: Caps alone types the
            // base é — never É, never 2 — while Shift alone types 2. Asking
            // merely whether the base has a capital would have made Caps
            // behave as if this key were É's.
            T.equal(Layout.isLetterKey({ t: "\u00e9", s: "2" }), false)
            T.equal(Layout.isLetterKey({ t: "2", s: "@" }), false)
            T.equal(Layout.isLetterKey({ t: "-", s: "" }), false)
            T.equal(Layout.isLetterKey({ t: "", s: "Q" }), false)
        })

        Qt.exit(T.report("keyboard layout"))
    }
}
