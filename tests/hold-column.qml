// Ticket 37's pure seam: which levels a keymap position offers as a hold
// column, and which caps defer their typing to mouse-release so a hold can
// open a menu without typing first. Run with tools/run-tests.sh — no
// compositor, no display. The menu chrome itself (MouseAreas, the timer)
// is QML and is proven in the VM leg; what is pinned here is that the two
// decisions the chrome feeds on cannot drift, because they are the whole
// contract: no menu content outside the layout's own levels 2-4, and no
// cap ever defers unless holding it can actually offer something.
import QtQml
import "../HoldColumn.js" as HoldColumn
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        // ---- the column: what one position offers ----
        //
        // Fixtures carry the shape the helper's caps facts really have
        // (KeyboardSession.parseCapsReply): an array per position, one
        // entry per level, `{ text }` for drawable text and `{ none }`
        // for a level with nothing to draw.

        T.test("a four-level column offers its extra levels three and four", function () {
            // Level 2 (№ here) stays on the cap's own Shift face — see
            // the shift-pair test below.
            var entries = HoldColumn.columnEntries([
                { text: "3" }, { text: "\u2116" }, { text: "\u00a7" }, { text: "\u20b4" }
            ])
            T.equal(entries.length, 2)
            T.deepEqual(entries[0], { level: 3, text: "\u00a7" })
            T.deepEqual(entries[1], { level: 4, text: "\u20b4" })
        })

        T.test("the shift pair is not menu content: level 2 stays on the cap", function () {
            // The ticket's honest expectation decides this: stock
            // `us`/`ua`/`ru` letter columns are two levels deep and their
            // caps "mostly have no menu"; the menu lights up where the
            // installed map actually carries levels 3-4. capOverlay also
            // writes the keymap's level 2 into the cap's own chrShift, so
            // a level-2 entry would be a second route to the character
            // the cap already types under Shift.
            T.equal(HoldColumn.columnEntries([
                { text: "a" }, { text: "A" }
            ]).length, 0)
            var onlyTwo = HoldColumn.columnEntries([
                { text: "3" }, { text: "!" }
            ])
            T.equal(onlyTwo.length, 0)
            // And with 3/4 present, level 2 still does not join them.
            var four = HoldColumn.columnEntries([
                { text: "3" }, { text: "!" }, { text: "\u00a7" }, { text: "\u20b4" }
            ])
            T.equal(four.length, 2)
            T.equal(four[0].level, 3)
            T.equal(four[1].level, 4)
        })

        T.test("levels five to eight are never offered, whatever they carry", function () {
            // The reserved block's own levels (decisions §33): the &123
            // page is the one route to those characters, and a hold on a
            // letter cap must not grow a second one.
            var entries = HoldColumn.columnEntries([
                { text: "3" }, { text: "!" }, { none: "" }, { none: "" },
                { text: "\u00a3" }, { text: "\u20ac" }, { text: "\u00a5" }, { text: "\u00a2" }
            ])
            T.equal(entries.length, 0)
            var mixed = HoldColumn.columnEntries([
                { text: "3" }, { text: "!" }, { text: "\u00a7" }, { none: "" },
                { text: "\u00a3" }, { text: "\u20ac" }, { text: "\u00a5" }, { text: "\u00a2" }
            ])
            T.equal(mixed.length, 1)
            T.deepEqual(mixed[0], { level: 3, text: "\u00a7" })
        })

        T.test("a block-hosted position still offers only its layout levels", function () {
            // The ordinary shape after §33: levels 1-4 keep the layout's
            // own characters and the catalogue rides above. A column on
            // such a position is the layout's, never the catalogue's.
            var entries = HoldColumn.columnEntries([
                { text: "4" }, { text: "\"" }, { text: "\u00a4" }, { text: "\u20ac" },
                { text: "\u00a3" }, { text: "\u00a5" }, { text: "\u00b0" }, { text: "\u00b1" }
            ])
            T.equal(entries.length, 2)
            T.equal(entries[0].text, "\u00a4")
            T.equal(entries[1].text, "\u20ac")
        })

        T.test("empty, none and unresolved levels are skipped", function () {
            var entries = HoldColumn.columnEntries([
                { text: "a" }, { none: "" }, { text: "\u00a7" }, { none: "dead_acute" }
            ])
            T.equal(entries.length, 1)
            T.deepEqual(entries[0], { level: 3, text: "\u00a7" })
            // A text entry that is the empty string is not drawable
            // either — the same rule buildGlyphIndex applies.
            var hollow = HoldColumn.columnEntries([
                { text: "a" }, { text: "" }, { text: "\u00a7" }, { text: "" }
            ])
            T.equal(hollow.length, 1)
            T.deepEqual(hollow[0], { level: 3, text: "\u00a7" })
        })

        T.test("a two-level column — the stock letter key — offers nothing", function () {
            // The owner's stock layouts' letters are two levels deep, so
            // their caps keep press-types and the compositor's repeat:
            // the menu must not appear with the shift pair as content.
            T.equal(HoldColumn.columnEntries([
                { text: "\u0430" }, { text: "\u0410" }
            ]).length, 0)
        })
        T.test("absent, null and short facts offer nothing", function () {
            T.equal(HoldColumn.columnEntries(null).length, 0)
            T.equal(HoldColumn.columnEntries(undefined).length, 0)
            T.equal(HoldColumn.columnEntries([]).length, 0)
            T.equal(HoldColumn.columnEntries([{ text: "q" }]).length, 0)
            // Not an array at all (a facts map miss or a malformed record):
            // no column, never a crash.
            T.equal(HoldColumn.columnEntries({}).length, 0)
        })

        // ---- the defer decision: which caps type on release ----

        // A main-page typed cap (typedRow's shape, overlaid with the
        // keymap's own levels) whose position carries a level-3 symbol.
        function deferredCap() {
            return { chr: "3", chrShift: "\u2116", xkb: "AE03" }
        }
        function richColumn() {
            return [
                { level: 3, text: "\u00a7" },
                { level: 4, text: "\u20b4" }
            ]
        }

        T.test("a character cap with a column defers, ready and not searching", function () {
            T.equal(HoldColumn.shouldDefer(deferredCap(), richColumn(),
                false, true), true)
        })

        T.test("a cap with no column never defers", function () {
            // The regression the whole design turns on: without content
            // there is no menu, and such a cap keeps today's press-types
            // plus the compositor's own repeat (spec-v1 §6).
            T.equal(HoldColumn.shouldDefer(deferredCap(), [], false, true), false)
            T.equal(HoldColumn.shouldDefer(deferredCap(), null, false, true), false)
        })

        T.test("searchMode never defers", function () {
            // The emoji search feeds its query on PRESS (typeCap's search
            // arm); deferring would eat the first letter of every search.
            T.equal(HoldColumn.shouldDefer(deferredCap(), richColumn(),
                true, true), false)
        })

        T.test("a not-ready keyboard never defers", function () {
            // The gated cap's press path never starts (spec-v1.1 §6), and
            // a hold is part of that press path.
            T.equal(HoldColumn.shouldDefer(deferredCap(), richColumn(),
                false, false), false)
        })

        T.test("exact caps never defer", function () {
            // The &123 glyph caps type the level they draw on press and
            // are the menu's own routing, not a customer of it.
            var glyph = { chr: "\u00a3", xkb: "AB11", baseLvl: 5, exact: true,
                level3: true }
            T.equal(HoldColumn.shouldDefer(glyph, richColumn(), false, true), false)
        })

        T.test("a level-bearing cap without the exact flag never defers either", function () {
            // typeCap treats `baseLvl !== undefined` as exactness; the
            // defer decision must not split that hair differently.
            var levelled = { chr: "\u00a7", xkb: "AE03", baseLvl: 3 }
            T.equal(HoldColumn.shouldDefer(levelled, richColumn(),
                false, true), false)
        })

        T.test("modifier, command and keysym caps never defer", function () {
            // `key` names the modifier/command/keysym caps — Shift, Fn,
            // BackSpace, the arrows — and all of them keep press or click
            // semantics entirely.
            T.equal(HoldColumn.shouldDefer({ key: "shift", label: "Shift" },
                richColumn(), false, true), false)
            T.equal(HoldColumn.shouldDefer({ key: "BackSpace", label: "\u232b" },
                richColumn(), false, true), false)
            T.equal(HoldColumn.shouldDefer({ key: "Escape", label: "esc" },
                richColumn(), false, true), false)
        })

        T.test("Space never defers: a fixed-label cap keeps press semantics", function () {
            // Space carries `label: ""` rather than a `key`, so the label
            // property is what tells it apart from a typed character cap.
            // A deferred Space would eat hold-repeat of the most-held key
            // on the board.
            var space = { chr: " ", label: "", w: 4.5, xkb: "SPCE" }
            T.equal(HoldColumn.shouldDefer(space, [
                { level: 2, text: " " }, { level: 3, text: "\u00a0" }
            ], false, true), false)
        })

        T.test("a cap without a position never defers", function () {
            T.equal(HoldColumn.shouldDefer({ chr: "q" }, richColumn(),
                false, true), false)
            T.equal(HoldColumn.shouldDefer(null, richColumn(), false, true), false)
        })

        T.test("an unavailable or spacer cap never defers", function () {
            T.equal(HoldColumn.shouldDefer({ chr: "\u2603", unavailable: true,
                xkb: "AB11" }, richColumn(), false, true), false)
            T.equal(HoldColumn.shouldDefer({ spacer: true, w: 1 },
                richColumn(), false, true), false)
        })

        // ---- the threshold ----

        T.test("the hold threshold sits in the designed window", function () {
            // ~300-350 ms: long enough to read as a deliberate hold,
            // short enough to stay under the compositor's repeat_delay
            // (Hyprland's default is 600 ms; a user's own setting can be
            // lower, and the deferred cap never sends a press line at all,
            // so no repeat can start).
            T.equal(HoldColumn.HOLD_THRESHOLD_MS >= 300, true)
            T.equal(HoldColumn.HOLD_THRESHOLD_MS <= 350, true)
        })

        Qt.exit(T.report("hold column"))
    }
}
