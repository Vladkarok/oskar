// Seam 2 of the two the project has (spec-v1 §15): the modifier state
// machine, driven as a pure function. Run with tools/run-tests.sh — it needs
// no compositor and no display, which is the point of keeping the reducer
// free of QML imports.
import QtQml
import "../ModifierReducer.js" as Reducer
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        var idle = Reducer.initialState()

        // ---- the state table, cell by cell ----

        T.test("idle + click -> latched, nothing emitted", function () {
            var out = Reducer.reduce(idle, { type: "click", modifier: "ctrl" })
            T.equal(out.state.ctrl, "latched")
            T.deepEqual(out.lines, [])
        })

        T.test("double-clicking Ctrl ends idle with no held protocol state", function () {
            var out = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, [])
        })

        T.test("idle + press -> unchanged, the position goes down", function () {
            var out = Reducer.reduce(idle, { type: "press", position: "AD03" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["down AD03"])
            // And the release is what lifts it. `down` rather than `tap` is
            // the whole of key repeat (spec-v1 §6): the key stays down for as
            // long as the button does and the compositor repeats it.
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines, ["up AD03"])
        })

        T.test("latched + click -> idle, without passing through locked", function () {
            var latched = Reducer.reduce(idle, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(latched, { type: "click", modifier: "ctrl" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, [])
        })

        T.test("latched Shift + double click -> locked, Shift goes down", function () {
            var latched = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(latched, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "locked")
            T.deepEqual(out.lines, ["down LFSH"])
        })

        T.test("latched + press -> idle, the modifier wraps the press", function () {
            var latched = Reducer.reduce(idle, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(latched, { type: "press", position: "AD03" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["down LCTL", "down AD03"])
            // The wrap comes off on the release, in the reverse of the order
            // it went on — and not before, or the repeats would arrive
            // unmodified after the first one.
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AD03", "up LCTL"])
        })

        T.test("locked Shift + click -> idle, Shift comes back up", function () {
            var locked = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(locked, { type: "click", modifier: "shift" })
            T.equal(out.state.shift, "idle")
            T.deepEqual(out.lines, ["up LFSH"])
        })

        T.test("locked Shift + double click -> idle, Shift comes back up", function () {
            var locked = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(locked, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "idle")
            T.deepEqual(out.lines, ["up LFSH"])
        })

        T.test("locked Shift + press stays locked and emits no extra hold", function () {
            var locked = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(locked, { type: "press", position: "AD03" })
            T.equal(out.state.shift, "locked")
            T.deepEqual(out.lines, ["down AD03"])
            // A locked modifier is held at the device, so the release lifts
            // the key alone and leaves the lock exactly where it was.
            var lifted = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(lifted.lines, ["up AD03"])
            T.equal(lifted.state.shift, "locked")
        })

        // ---- the double-click gesture, as the real MouseArea delivers it
        // (issue 17) ----
        //
        // Modifiers latch on the way down now, so the reducer no longer sees a
        // tidy one-click-per-gesture stream. A real MouseArea emits, measured:
        //
        //   single click   pressed, released, clicked
        //   double click   pressed, released, clicked, pressed, doubleClicked,
        //                  released
        //
        // Both presses reach the reducer as `click`; `clicked` is routed
        // nowhere for modifiers because Qt withholds it for the second press
        // anyway (issue 13). So a lock arrives as click, click, doubleClick,
        // and the second click has already bounced a fresh latch back to idle
        // by the time the lock is known. `doubleClick` therefore rolls the
        // gesture back to where it started rather than reading the state it
        // happens to find, and emits only the difference against the device.

        T.test("Shift click, click, doubleClick ends locked and held once", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" })
            T.equal(state.state.shift, "latched")
            T.deepEqual(state.lines, [])
            var second = Reducer.reduce(state.state, { type: "click", modifier: "shift" })
            // The second press of the double click is seen first as a click on
            // a latched modifier, which §5 says returns it to idle without
            // passing through locked. It must not emit anything either, or the
            // lock's `down` would be preceded by a stray `up`.
            T.equal(second.state.shift, "idle")
            T.deepEqual(second.lines, [])
            var out = Reducer.reduce(second.state, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "locked")
            T.deepEqual(out.lines, ["down LFSH"])
        })

        T.test("every non-Shift double-click sequence ends idle", function () {
            var modifiers = ["ctrl", "alt", "logo", "altgr"]
            for (var i = 0; i < modifiers.length; i++) {
                var modifier = modifiers[i]
                var first = Reducer.reduce(idle, { type: "click", modifier: modifier })
                var second = Reducer.reduce(first.state, { type: "click", modifier: modifier })
                var out = Reducer.reduce(second.state,
                    { type: "doubleClick", modifier: modifier })
                T.equal(out.state[modifier], "idle")
                T.deepEqual(first.lines.concat(second.lines, out.lines), [])
            }
        })

        T.test("click, click, doubleClick from latched ends locked", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            T.equal(state.shift, "latched")
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "locked")
            T.deepEqual(out.lines, ["down LFSH"])
        })

        T.test("Shift click, click, doubleClick from locked lifts exactly once", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            T.equal(state.shift, "locked")
            var first = Reducer.reduce(state, { type: "click", modifier: "shift" })
            // The first press of the gesture already lifted it.
            T.deepEqual(first.lines, ["up LFSH"])
            var second = Reducer.reduce(first.state, { type: "click", modifier: "shift" })
            T.deepEqual(second.lines, [])
            var out = Reducer.reduce(second.state, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "idle")
            // And the rollback must not lift it a second time: the helper is
            // no longer holding LFSH, so a second `up` would be a line about a
            // key nothing is down on.
            T.deepEqual(out.lines, [])
        })

        T.test("a Shift click that unlocks does not poison the next double click", function () {
            // The sequence that a one-click-deep memory gets wrong: unlock,
            // then double click. The gesture starts from idle, so it must
            // lock — not read the `locked` that preceded the unlocking click.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            T.equal(state.shift, "idle")
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "locked")
            T.deepEqual(out.lines, ["down LFSH"])
        })

        T.test("a double click on one modifier ignores the clicks on another", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            var out = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" })
            T.equal(out.state.shift, "locked")
            T.deepEqual(out.lines, ["down LFSH"])
            // and nothing it did leaked sideways
            T.equal(out.state.ctrl, "latched")
            T.equal(out.state.alt, "idle")
        })

        T.test("Shift gesture memory does not survive into the next gesture", function () {
            // lock, then unlock by a plain single click much later: the
            // doubleClick that made the lock must have cleared its own
            // bookkeeping, or the click would roll back instead of lifting.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "click", modifier: "shift" })
            T.equal(out.state.shift, "idle")
            T.deepEqual(out.lines, ["up LFSH"])
        })

        T.test("no click is ever charged a delay: every click answers in one call", function () {
            // The point of issue 17. There is no timer left to wait on, so the
            // latch is in the returned state, not in a state some interval
            // later. Pinned as a property of the reducer's shape: a click
            // event's answer is complete when `reduce` returns.
            var out = Reducer.reduce(idle, { type: "click", modifier: "ctrl" })
            T.equal(Reducer.isActive(out.state, "ctrl"), true)
        })

        // ---- stacking (spec-v1 §5) ----

        T.test("Super+Shift+Alt+E leaves as one chord and clears all three", function () {
            var state = idle
            var order = ["logo", "shift", "alt"]
            for (var i = 0; i < order.length; i++) {
                state = Reducer.reduce(state, { type: "click", modifier: order[i] }).state
            }
            var out = Reducer.reduce(state, { type: "press", position: "AD03" })
            T.deepEqual(out.lines, [
                "down LALT",
                "down LWIN",
                "down LFSH",
                "down AD03"
            ])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines, [
                "up AD03",
                "up LFSH",
                "up LWIN",
                "up LALT"
            ])
            T.equal(out.state.logo, "idle")
            T.equal(out.state.shift, "idle")
            T.equal(out.state.alt, "idle")
        })

        T.test("locked Shift survives ten presses while latched Alt does not", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            var first = Reducer.reduce(state, { type: "press", position: "AB01" })
            T.deepEqual(first.lines, ["down LALT", "down AB01"])
            var firstUp = Reducer.reduce(first.state, { type: "release" })
            T.deepEqual(firstUp.lines, ["up AB01", "up LALT"])
            state = firstUp.state
            for (var i = 0; i < 9; i++) {
                var out = Reducer.reduce(state, { type: "press", position: "AB01" })
                T.deepEqual(out.lines, ["down AB01"])
                var up = Reducer.reduce(out.state, { type: "release" })
                T.deepEqual(up.lines, ["up AB01"])
                state = up.state
            }
            T.equal(state.shift, "locked")
            T.equal(state.alt, "idle")
        })

        T.test("locked Shift and latched Ctrl stack on the same press", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD03" })
            T.deepEqual(out.lines, ["down LCTL", "down AD03"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AD03", "up LCTL"])
        })

        // ---- pages and languages (spec-v1 §5, issues 05 and 10) ----

        T.test("a page switch leaves every modifier and emits nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(state, { type: "pageSwitch" })
            T.equal(out.state.shift, "locked")
            T.equal(out.state.ctrl, "latched")
            T.deepEqual(out.lines, [])
        })

        T.test("a language switch leaves every modifier and emits nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            var out = Reducer.reduce(state, { type: "languageSwitch" })
            T.equal(out.state.shift, "locked")
            T.equal(out.state.alt, "latched")
            T.deepEqual(out.lines, [])
        })

        T.test("Fn is an immediate two-state panel control that emits nothing", function () {
            var on = Reducer.reduce(idle, { type: "fnClick" })
            T.equal(on.state.fn, true)
            T.deepEqual(on.lines, [])
            var off = Reducer.reduce(on.state, { type: "fnClick" })
            T.equal(off.state.fn, false)
            T.deepEqual(off.lines, [])
        })

        T.test("Fn switching preserves every modifier and Caps state", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "capsClick" }).state
            var out = Reducer.reduce(state, { type: "fnClick" })
            T.equal(out.state.shift, "locked")
            T.equal(out.state.ctrl, "latched")
            T.equal(out.state.caps, true)
            T.equal(out.state.fn, true)
            T.deepEqual(out.lines, [])
        })

        T.test("closing releases held keys but keeps session Fn mode", function () {
            var state = Reducer.reduce(idle, { type: "fnClick" }).state
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.equal(out.state.fn, true)
            T.equal(out.state.shift, "idle")
            T.deepEqual(out.lines, ["up LFSH"])
        })

        // ---- the symbols page, whose caps stand for a shift level and have to
        // type it with a real Shift press (spec-v1 §4) ----

        T.test("a shift-level cap presses Shift around the position on its own", function () {
            var out = Reducer.reduce(idle, { type: "press", position: "AE01", shift: true })
            T.deepEqual(out.lines, ["down LFSH", "down AE01"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE01", "up LFSH"])
        })

        T.test("a shift-level cap does not press Shift twice while it is latched", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AE01", shift: true })
            T.deepEqual(out.lines, ["down LFSH", "down AE01"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE01", "up LFSH"])
            T.equal(out.state.shift, "idle")
        })

        T.test("a shift-level cap adds nothing while Shift is locked and held", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AE01", shift: true })
            T.deepEqual(out.lines, ["down AE01"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines, ["up AE01"])
            T.equal(out.state.shift, "locked")
        })

        T.test("a shift-level cap stacks under a latched Ctrl", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AB10", shift: true })
            T.deepEqual(out.lines, ["down LCTL", "down LFSH", "down AB10"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AB10", "up LFSH", "up LCTL"])
            T.equal(out.state.ctrl, "idle")
        })

        T.test("a base-level cap on the symbols page carries no Shift of its own", function () {
            var out = Reducer.reduce(idle, { type: "press", position: "AB10", shift: false })
            T.deepEqual(out.lines, ["down AB10"])
        })

        T.test("a latch survives the switch to the symbols page and is spent there", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "alt" }).state
            state = Reducer.reduce(state, { type: "pageSwitch" }).state
            T.equal(state.alt, "latched")
            var out = Reducer.reduce(state, { type: "press", position: "AE01", shift: true })
            T.deepEqual(out.lines, ["down LALT", "down LFSH", "down AE01"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE01", "up LFSH", "up LALT"])
            T.equal(out.state.alt, "idle")
        })

        T.test("locked Shift still emits its lift after a page switch", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "pageSwitch" }).state
            var out = Reducer.reduce(state, { type: "click", modifier: "shift" })
            T.deepEqual(out.lines, ["up LFSH"])
        })

        // ---- the curated page's AltGr levels (spec-v1.1 §3). Levels 3 and 4
        // are real levels of the complete active keymap, reached the same way
        // level 2 is: a real modifier press around the key, never a character
        // the panel picked. AltGr cannot lock (§16), so it is either idle or
        // latched here. ----

        T.test("a level-3 cap wraps AltGr around the position on its own", function () {
            var out = Reducer.reduce(idle, {
                type: "press", position: "AE05", shift: false, altgr: true, exact: true })
            T.deepEqual(out.lines, ["down RALT", "down AE05"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE05", "up RALT"])
            T.equal(out.state.altgr, "idle")
        })

        T.test("a level-4 cap wraps AltGr and Shift, AltGr going down first", function () {
            var out = Reducer.reduce(idle, {
                type: "press", position: "AE03", shift: true, altgr: true, exact: true })
            T.deepEqual(out.lines, ["down RALT", "down LFSH", "down AE03"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE03", "up LFSH", "up RALT"])
        })

        T.test("a level-3 cap lifts a locked Shift around the press and restores it", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE05", shift: false, altgr: true, exact: true })
            T.deepEqual(out.lines, ["up LFSH", "down RALT", "down AE05"])
            var lifted = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(lifted.lines, ["up AE05", "up RALT", "down LFSH"])
            T.equal(lifted.state.shift, "locked")
        })

        T.test("a level-3 cap under a latched Shift stays level 3 and spends the latch", function () {
            // The chord is the level's, so the armed Shift adds nothing —
            // but a curated cap is an ordinary non-modifier key to §2, so
            // the latch does not outlive it.
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE05", shift: false, altgr: true, exact: true })
            T.deepEqual(out.lines, ["down RALT", "down AE05"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE05", "up RALT"])
            T.equal(out.state.shift, "idle")
        })

        T.test("a level-1 cap under a latched Shift types level 1 and spends the latch", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE04", shift: false, altgr: false, exact: true })
            T.deepEqual(out.lines, ["down AE04"])
            var up = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(up.lines, ["up AE04"])
            T.equal(up.state.shift, "idle")
            // The point of the consumption: the armed Shift must not reach
            // past the symbol, or the next ordinary key is shifted behind
            // the user's back.
            var ordinary = Reducer.reduce(up.state, { type: "press", position: "AD01", letter: true })
            T.deepEqual(ordinary.lines, ["down AD01"])
        })

        T.test("a level-1 cap lifts a locked Shift around the press and restores it", function () {
            // The French ² case (R3's input half): the lock is real, the cap
            // is exact, so the lock is lifted for the press and restored
            // after it — the symbol types level 1 whatever the lock says,
            // and the lock survives to say so.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "TLDE", shift: false, altgr: false, exact: true })
            T.deepEqual(out.lines, ["up LFSH", "down TLDE"])
            var lifted = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(lifted.lines, ["up TLDE", "down LFSH"])
            T.equal(lifted.state.shift, "locked")
        })

        T.test("Caps never shifts an exact cap's chord", function () {
            // Caps is a letters-only semantic toggle (§2/§16). An exact cap
            // answers to its level alone, so Caps on changes nothing about
            // the chord — which is exactly why its display must not change
            // either (the R3 display rule in KeyboardLayout.js).
            var state = Reducer.reduce(idle, { type: "capsClick" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "TLDE", shift: false, altgr: false, exact: true })
            T.deepEqual(out.lines, ["down TLDE"])
            var up = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(up.lines, ["up TLDE"])
            T.equal(up.state.caps, true)
            // The discriminating case: a LEVEL-2 exact press still wraps the
            // Shift its level wants while Caps is on. Caps cancels Shift for
            // LETTERS, but a curated cap is not a letter — the chord is the
            // level's decision alone (gb's £ at AE03 is this shape).
            var shifted = Reducer.reduce(state, {
                type: "press", position: "AE03", shift: true, altgr: false, exact: true })
            T.deepEqual(shifted.lines, ["down LFSH", "down AE03"])
            T.deepEqual(Reducer.reduce(shifted.state, { type: "release" }).lines,
                        ["up AE03", "up LFSH"])
        })

        T.test("a level-4 cap wraps Shift from its level and spends the latch", function () {
            // Shift goes down because the LEVEL is 4, not because a latch
            // armed it — and the latch is spent like §2 spends any
            // non-modifier key's.
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE03", shift: true, altgr: true, exact: true })
            T.deepEqual(out.lines, ["down RALT", "down LFSH", "down AE03"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE03", "up LFSH", "up RALT"])
            T.equal(out.state.shift, "idle")
        })

        T.test("a level-4 cap adds nothing while Shift is locked and held", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE03", shift: true, altgr: true, exact: true })
            T.deepEqual(out.lines, ["down RALT", "down AE03"])
            T.equal(out.state.shift, "locked")
        })

        T.test("a latched AltGr is spent by the level-explicit press it arms", function () {
            // Level 3 needs AltGr at the device, so the wrap goes out even
            // over the latch — the wrap is the level's decision, not the
            // latch's — and the latch is consumed as §2 consumes any
            // non-modifier press's latches.
            var state = Reducer.reduce(idle, { type: "click", modifier: "altgr" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE05", shift: false, altgr: true, exact: true })
            T.deepEqual(out.lines, ["down RALT", "down AE05"])
            var up = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(up.lines, ["up AE05", "up RALT"])
            T.equal(up.state.altgr, "idle")
            var ordinary = Reducer.reduce(up.state, { type: "press", position: "AD03" })
            T.deepEqual(ordinary.lines, ["down AD03"])
        })

        T.test("the chord plan is unique when Shift and AltGr are both latched on level 4", function () {
            // The wrap is a set, not a push history: both latches are spent
            // by this press and both of the level's modifiers wrap exactly
            // once. The pending record must carry each modifier once — the
            // release contract is not allowed to rest on indexOf collapsing
            // a duplicated plan.
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "altgr" }).state
            var out = Reducer.reduce(state, {
                type: "press", position: "AE03", shift: true, altgr: true, exact: true })
            T.deepEqual(out.state.pending.wrap, ["altgr", "shift"])
            T.deepEqual(out.lines, ["down RALT", "down LFSH", "down AE03"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AE03", "up LFSH", "up RALT"])
        })

        T.test("a latched AltGr still wraps an ordinary press without a level", function () {
            // Pre-existing v1 behaviour: a manual AltGr latch wraps whatever
            // non-modifier press follows, whatever page it came from.
            var state = Reducer.reduce(idle, { type: "click", modifier: "altgr" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD03" })
            T.deepEqual(out.lines, ["down RALT", "down AD03"])
            T.equal(out.state.altgr, "idle")
        })

        T.test("every curated level types exactly its level and leaves every latch idle", function () {
            // The whole merged rule in one sweep, latched Shift and AltGr
            // armed before each press: the chord is the level's and nothing
            // else (levels 1 and 3 carry no Shift, level 3 no more Shift
            // than its own flag asks), the latches come back idle after
            // each, and the next ordinary key lands unshifted — the stale
            // armed state must not reach past a symbol (§2).
            var levels = [
                { shift: false, altgr: false, lines: ["down AE04"] },
                { shift: true,  altgr: false, lines: ["down LFSH", "down AE04"] },
                { shift: false, altgr: true,  lines: ["down RALT", "down AE04"] },
                { shift: true,  altgr: true,  lines: ["down RALT", "down LFSH", "down AE04"] }
            ]
            for (var i = 0; i < levels.length; i++) {
                var want = levels[i]
                var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
                state = Reducer.reduce(state, { type: "click", modifier: "altgr" }).state
                var out = Reducer.reduce(state, {
                    type: "press", position: "AE04",
                    shift: want.shift, altgr: want.altgr, exact: true })
                T.deepEqual(out.lines, want.lines, "level " + (i + 1) + " chord")
                var up = Reducer.reduce(out.state, { type: "release" })
                T.equal(up.state.shift, "idle", "level " + (i + 1) + " leaves Shift idle")
                T.equal(up.state.altgr, "idle", "level " + (i + 1) + " leaves AltGr idle")
                var ordinary = Reducer.reduce(up.state, {
                    type: "press", position: "AD01", letter: true })
                T.deepEqual(ordinary.lines, ["down AD01"],
                            "level " + (i + 1) + ": next ordinary key unshifted")
            }
        })

        // ---- caps lock, which is emulated with Shift rather than the CAPS
        // position (grp:caps_toggle makes the real key a layout switch) ----

        T.test("each Caps press toggles its two-state control immediately", function () {
            var on = Reducer.reduce(idle, { type: "capsClick" })
            T.equal(on.state.caps, true)
            T.deepEqual(on.lines, [])

            var ignoredGesture = Reducer.reduce(
                on.state, { type: "doubleClick", modifier: "caps" })
            T.equal(ignoredGesture.state.caps, true)
            T.deepEqual(ignoredGesture.lines, [])

            var off = Reducer.reduce(ignoredGesture.state, { type: "capsClick" })
            T.equal(off.state.caps, false)
            T.deepEqual(off.lines, [])
        })

        T.test("Caps-on state shifts a letter without a physical Caps position", function () {
            var state = Reducer.reduce(idle, { type: "capsClick" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD01", letter: true })
            T.deepEqual(out.lines, ["down LFSH", "down AD01"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AD01", "up LFSH"])
        })

        T.test("caps lock and a latched Shift cancel on a letter, and the latch still clears", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "capsClick" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD01", letter: true })
            T.deepEqual(out.lines, ["down AD01"])
            T.equal(out.state.shift, "idle")
        })

        T.test("caps lock and locked Shift type lowercase, then restore the lock", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "capsClick" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD01", letter: true })
            T.deepEqual(out.lines, ["up LFSH", "down AD01"])
            var lifted = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(lifted.lines, ["up AD01", "down LFSH"])
            T.equal(lifted.state.shift, "locked")
            T.equal(lifted.state.caps, true)
        })

        T.test("closing during Caps cancellation does not pulse locked Shift", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "capsClick" }).state
            state = Reducer.reduce(state,
                { type: "press", position: "AD01", letter: true }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.deepEqual(out.lines, ["up AD01"])
            T.equal(out.state.shift, "idle")
            T.equal(out.state.caps, true)
        })

        T.test("caps lock does not shift a non-letter key", function () {
            var state = Reducer.reduce(idle, { type: "capsClick" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AE01", letter: false })
            T.deepEqual(out.lines, ["down AE01"])
        })

        T.test("releasing held modifiers does not turn persistent Caps off", function () {
            var state = Reducer.reduce(idle, { type: "capsClick" }).state
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.equal(out.state.caps, true)
            T.equal(out.state.shift, "idle")
            T.deepEqual(out.lines, ["up LFSH"])
        })

        // ---- mid-chord configure drains (round 4). A configure that changed
        // the keymap drains the helper's held keys; the panel settles to the
        // device world with the configureDrain event (state only, never
        // lines) and can tell the release of a chord the drain ran past from
        // one it did not touch, by the configure-send stamp the press
        // recorded. ----

        T.test("configureDrain resets held modifiers, keeps Caps and Fn, emits nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            state = Reducer.reduce(state, { type: "capsClick" }).state
            state = Reducer.reduce(state, { type: "fnClick" }).state
            var out = Reducer.reduce(state, { type: "configureDrain", stamp: 3 })
            T.equal(out.state.shift, "idle")
            T.equal(out.state.alt, "idle")
            T.equal(out.state.caps, true)
            T.equal(out.state.fn, true)
            T.deepEqual(out.lines, [])
        })

        T.test("a chord the drain ran past loses its pending record", function () {
            // The send counter increments when the configure is WRITTEN, so
            // a press stamped 1 with the drain at seq 2 means the configure
            // was queued after the press lines: the drain lifted the held
            // key with everything else, and the mouse-up must re-send
            // nothing.
            var state = Reducer.reduce(idle, {
                type: "press", position: "AD01", configureStamp: 1 }).state
            var out = Reducer.reduce(state, { type: "configureDrain", stamp: 2 })
            T.equal(out.state.pending, null)
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines, [])
        })

        T.test("a FAILED configure keeps every pending record, both orderings", function () {
            // The error cannot say whether the helper drained before failing
            // (upload failure) or never got there (compile / rate limit), so
            // the panel settles with stamp -1: every pending record survives
            // (minus the restore plan), whatever the ordering.
            //
            // Never drained (compile / rate limit): the chord's hold is
            // real, its mouse-up lifts for real. Even a drain stamp that
            // would read "configure queued after the press" is overridden by
            // the -1: nothing was drained.
            var state = Reducer.reduce(idle, { type: "capsClick" }).state
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, {
                type: "press", position: "AD01", letter: true, configureStamp: 1 }).state
            var out = Reducer.reduce(state, { type: "configureDrain", stamp: -1 })
            T.equal(out.state.shift, "idle")
            T.equal(out.state.pending === null, false)
            T.deepEqual(out.state.pending.restore, [])
            T.equal(out.state.pending.position, "AD01")
            // The mouse-up lifts the key and never re-presses the lock.
            var up = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(up.lines, ["up AD01"])
            T.equal(up.state.shift, "idle")
            //
            // Drained before failing (upload failure): the same settle; the
            // pending survives too — its mouse-up becomes a forwarded no-op
            // the compositor drops, which is the harmless worst case.
            var down = Reducer.reduce(idle, { type: "press", position: "AC02", configureStamp: 1 }).state
            var out2 = Reducer.reduce(down, { type: "configureDrain", stamp: -1 })
            T.equal(out2.state.pending === null, false)
            T.equal(out2.state.pending.position, "AC02")
            T.deepEqual(Reducer.reduce(out2.state, { type: "release" }).lines,
                        ["up AC02"])
        })

        T.test("release before the refusal keeps the lock for the failure settle", function () {
            // locked Shift → held key → changed configure queued → release
            // arrives BEFORE the refusal. The dropRestore release keeps the
            // reducer's lock — the settle is the reply's job, not the
            // release's — so the failure settle still sees what it must
            // lift, and the mouse-up lifts only the key.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, {
                type: "press", position: "AD01", letter: true, configureStamp: 1 }).state
            var rel = Reducer.reduce(state, { type: "release", dropRestore: true })
            T.deepEqual(rel.lines, ["up AD01"])
            T.equal(rel.state.shift, "locked")
            T.equal(rel.state.pending, null)
            // The failure settle (stamp -1: nothing was drained) ends idle,
            // with nothing pending and nothing left to lift.
            var out = Reducer.reduce(rel.state, { type: "configureDrain", stamp: -1 })
            T.equal(out.state.shift, "idle")
            T.equal(out.state.pending, null)
            T.deepEqual(out.lines, [])
        })

        T.test("an equal stamp means the configure was sent before the press", function () {
            // Production stamps a chord with the send count AT PRESS TIME,
            // so stamp === seq can only mean the configure was already
            // written when the chord went down — the helper drains it ahead
            // of the press lines, and the press's hold is real again. The
            // pending record survives and the mouse-up lifts the key.
            var state = Reducer.reduce(idle, {
                type: "press", position: "AD01", configureStamp: 1 }).state
            var out = Reducer.reduce(state, { type: "configureDrain", stamp: 1 })
            T.equal(out.state.shift, "idle")
            T.equal(out.state.pending === null, false)
            T.equal(out.state.pending.position, "AD01")
            var up = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(up.lines, ["up AD01"])
        })

        T.test("a chord pressed after the drained configure keeps its key, not its restore", function () {
            // Locked Shift + Caps + a letter is the lift-around chord: its
            // press lines went out after the draining configure, so the
            // held key is real and the mouse-up must still lift it — but
            // the restore plan would re-press a lock the drain removed,
            // and the lock itself is gone from the device world.
            var state = Reducer.reduce(idle, { type: "capsClick" }).state
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, {
                type: "press", position: "AD01", letter: true, configureStamp: 5 }).state
            T.deepEqual(state.pending.restore, ["shift"])
            var out = Reducer.reduce(state, { type: "configureDrain", stamp: 3 })
            T.equal(out.state.shift, "idle")
            T.deepEqual(out.state.pending.restore, [])
            T.equal(out.state.pending.position, "AD01")
            var up = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(up.lines, ["up AD01"])
            T.equal(up.state.shift, "idle")
        })

        T.test("a release drops only the restore when the panel says a drain is ahead", function () {
            // Caps + locked Shift is the lift-around pairing: the release's
            // restore is the restorative `down LFSH`.
            var locked = Reducer.reduce(idle, { type: "capsClick" }).state
            locked = Reducer.reduce(locked, { type: "doubleClick", modifier: "shift" }).state
            var down = Reducer.reduce(locked, {
                type: "press", position: "AD01", letter: true }).state
            var out = Reducer.reduce(down, { type: "release", dropRestore: true })
            T.deepEqual(out.lines, ["up AD01"])
            T.equal(out.state.shift, "locked")
            // Without the flag the restorative down still rides: everywhere
            // outside a mid-chord drain, the lock is re-held exactly as
            // before this round.
            var down2 = Reducer.reduce(locked, {
                type: "press", position: "AD01", letter: true }).state
            var plain = Reducer.reduce(down2, { type: "release" })
            T.deepEqual(plain.lines, ["up AD01", "down LFSH"])
            T.equal(plain.state.shift, "locked")
        })

        // ---- purity and housekeeping ----

        T.test("the reducer never mutates the state it is given", function () {
            var state = Reducer.initialState()
            var snapshot = JSON.stringify(state)
            Reducer.reduce(state, { type: "doubleClick", modifier: "ctrl" })
            Reducer.reduce(state, { type: "click", modifier: "shift" })
            Reducer.reduce(state, { type: "press", position: "AD01" })
            T.equal(JSON.stringify(state), snapshot)
        })

        T.test("the same state and event always give the same answer", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "alt" }).state
            var a = Reducer.reduce(state, { type: "press", position: "AD03" })
            var b = Reducer.reduce(state, { type: "press", position: "AD03" })
            T.deepEqual(a.lines, b.lines)
            T.equal(JSON.stringify(a.state), JSON.stringify(b.state))
        })

        T.test("an unknown event leaves the state alone rather than throwing", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "alt" }).state
            var out = Reducer.reduce(state, { type: "nonsense" })
            T.equal(out.state.alt, "latched")
            T.deepEqual(out.lines, [])
        })

        T.test("releaseAll lifts locked Shift and returns every modifier to idle", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.deepEqual(out.lines, ["up LFSH"])
            T.equal(JSON.stringify(out.state), JSON.stringify(Reducer.initialState()))
        })

        // ---- key repeat (spec-v1 §6, issue 06) ----

        T.test("a release with nothing held emits nothing", function () {
            // `canceled` and `released` both route here, and a cap that never
            // typed — a modifier, a command cap — must not lift someone
            // else's key on the way up.
            var out = Reducer.reduce(idle, { type: "release" })
            T.deepEqual(out.lines, [])
            T.equal(JSON.stringify(out.state), JSON.stringify(idle))
        })

        T.test("a second release does not lift the key twice", function () {
            var down = Reducer.reduce(idle, { type: "press", position: "AD03" }).state
            var first = Reducer.reduce(down, { type: "release" })
            T.deepEqual(first.lines, ["up AD03"])
            T.deepEqual(Reducer.reduce(first.state, { type: "release" }).lines, [])
        })

        T.test("one press emits one line, so nothing is repeating on this side", function () {
            // The panel runs no repeat timer: whatever the compositor does
            // between the down and the up is the compositor's, at the user's
            // own repeat_delay and repeat_rate. All the reducer can do is
            // emit the down once, which is what this pins.
            var out = Reducer.reduce(idle, { type: "press", position: "BKSP" })
            T.deepEqual(out.lines, ["down BKSP"])
            // And holding does not change the state further: there is no
            // event the panel could send that would type BKSP a second time
            // without a new press.
            T.deepEqual(Reducer.reduce(out.state, { type: "pageSwitch" }).lines, [])
            T.deepEqual(Reducer.reduce(out.state, { type: "languageSwitch" }).lines, [])
        })

        T.test("releaseAll lifts a key still held, then its wrap, then the locks", function () {
            // Closing the panel mid-hold. Without the key going first it
            // would keep repeating into whatever had focus until the
            // helper's fifteen-second cap noticed.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "press", position: "AD03" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.deepEqual(out.lines, ["up AD03", "up LCTL", "up LFSH"])
            T.equal(JSON.stringify(out.state), JSON.stringify(Reducer.initialState()))
        })

        T.test("isActive reports latched and locked but not idle", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            T.equal(Reducer.isActive(state, "shift"), true)
            T.equal(Reducer.isActive(state, "ctrl"), false)
            T.equal(Reducer.isActive(Reducer.reduce(idle, { type: "doubleClick", modifier: "shift" }).state, "shift"), true)
        })

        Qt.exit(T.report("modifier reducer"))
    }
}
