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

        T.test("idle + double click -> locked, the modifier goes down", function () {
            var out = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" })
            T.equal(out.state.ctrl, "locked")
            T.deepEqual(out.lines, ["down LCTL"])
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

        T.test("latched + double click -> locked, the modifier goes down", function () {
            var latched = Reducer.reduce(idle, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(latched, { type: "doubleClick", modifier: "ctrl" })
            T.equal(out.state.ctrl, "locked")
            T.deepEqual(out.lines, ["down LCTL"])
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

        T.test("locked + click -> idle, the modifier comes back up", function () {
            var locked = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            var out = Reducer.reduce(locked, { type: "click", modifier: "ctrl" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["up LCTL"])
        })

        T.test("locked + double click -> idle, the modifier comes back up", function () {
            var locked = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            var out = Reducer.reduce(locked, { type: "doubleClick", modifier: "ctrl" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["up LCTL"])
        })

        T.test("locked + press -> still locked, and the press emits no extra hold", function () {
            var locked = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            var out = Reducer.reduce(locked, { type: "press", position: "AD03" })
            T.equal(out.state.ctrl, "locked")
            T.deepEqual(out.lines, ["down AD03"])
            // A locked modifier is held at the device, so the release lifts
            // the key alone and leaves the lock exactly where it was.
            var lifted = Reducer.reduce(out.state, { type: "release" })
            T.deepEqual(lifted.lines, ["up AD03"])
            T.equal(lifted.state.ctrl, "locked")
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

        T.test("click, click, doubleClick from idle ends locked and held once", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "ctrl" })
            T.equal(state.state.ctrl, "latched")
            T.deepEqual(state.lines, [])
            var second = Reducer.reduce(state.state, { type: "click", modifier: "ctrl" })
            // The second press of the double click is seen first as a click on
            // a latched modifier, which §5 says returns it to idle without
            // passing through locked. It must not emit anything either, or the
            // lock's `down` would be preceded by a stray `up`.
            T.equal(second.state.ctrl, "idle")
            T.deepEqual(second.lines, [])
            var out = Reducer.reduce(second.state, { type: "doubleClick", modifier: "ctrl" })
            T.equal(out.state.ctrl, "locked")
            T.deepEqual(out.lines, ["down LCTL"])
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

        T.test("click, click, doubleClick from locked ends idle, lifted exactly once", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "alt" }).state
            T.equal(state.alt, "locked")
            var first = Reducer.reduce(state, { type: "click", modifier: "alt" })
            // The first press of the gesture already lifted it.
            T.deepEqual(first.lines, ["up LALT"])
            var second = Reducer.reduce(first.state, { type: "click", modifier: "alt" })
            T.deepEqual(second.lines, [])
            var out = Reducer.reduce(second.state, { type: "doubleClick", modifier: "alt" })
            T.equal(out.state.alt, "idle")
            // And the rollback must not lift it a second time: the helper is
            // no longer holding LALT, so a second `up` would be a line about a
            // key nothing is down on.
            T.deepEqual(out.lines, [])
        })

        T.test("a single click that unlocks does not poison the next double click", function () {
            // The sequence that a one-click-deep memory gets wrong: unlock,
            // then double click. The gesture starts from idle, so it must
            // lock — not read the `locked` that preceded the unlocking click.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            T.equal(state.ctrl, "idle")
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "ctrl" }).state
            var out = Reducer.reduce(state, { type: "doubleClick", modifier: "ctrl" })
            T.equal(out.state.ctrl, "locked")
            T.deepEqual(out.lines, ["down LCTL"])
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

        T.test("the gesture memory does not survive into the next gesture", function () {
            // lock, then unlock by a plain single click much later: the
            // doubleClick that made the lock must have cleared its own
            // bookkeeping, or the click would roll back instead of lifting.
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "logo" }).state
            var out = Reducer.reduce(state, { type: "click", modifier: "logo" })
            T.equal(out.state.logo, "idle")
            T.deepEqual(out.lines, ["up LWIN"])
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

        T.test("a locked modifier survives ten presses while a latched one does not", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
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
            T.equal(state.ctrl, "locked")
            T.equal(state.alt, "idle")
        })

        T.test("locked and latched stack on the same press", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD03" })
            T.deepEqual(out.lines, ["down LFSH", "down AD03"])
            T.deepEqual(Reducer.reduce(out.state, { type: "release" }).lines,
                        ["up AD03", "up LFSH"])
        })

        // ---- pages and languages (spec-v1 §5, issues 05 and 10) ----

        T.test("a page switch leaves every modifier and emits nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "pageSwitch" })
            T.equal(out.state.ctrl, "locked")
            T.equal(out.state.shift, "latched")
            T.deepEqual(out.lines, [])
        })

        T.test("a language switch leaves every modifier and emits nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "logo" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            var out = Reducer.reduce(state, { type: "languageSwitch" })
            T.equal(out.state.logo, "locked")
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
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "capsClick" }).state
            var out = Reducer.reduce(state, { type: "fnClick" })
            T.equal(out.state.ctrl, "locked")
            T.equal(out.state.shift, "latched")
            T.equal(out.state.caps, true)
            T.equal(out.state.fn, true)
            T.deepEqual(out.lines, [])
        })

        T.test("closing releases held keys but keeps session Fn mode", function () {
            var state = Reducer.reduce(idle, { type: "fnClick" }).state
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "ctrl" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.equal(out.state.fn, true)
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["up LCTL"])
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

        T.test("a locked modifier still emits its hold after a page switch releases nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "pageSwitch" }).state
            var out = Reducer.reduce(state, { type: "click", modifier: "ctrl" })
            T.deepEqual(out.lines, ["up LCTL"])
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
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "ctrl" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.equal(out.state.caps, true)
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["up LCTL"])
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

        T.test("releaseAll lifts every locked modifier and returns to idle", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "doubleClick", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "alt" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.deepEqual(out.lines, ["up LFSH", "up LCTL"])
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
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            state = Reducer.reduce(state, { type: "press", position: "AD03" }).state
            var out = Reducer.reduce(state, { type: "releaseAll" })
            T.deepEqual(out.lines, ["up AD03", "up LFSH", "up LCTL"])
            T.equal(JSON.stringify(out.state), JSON.stringify(Reducer.initialState()))
        })

        T.test("isActive reports latched and locked but not idle", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            T.equal(Reducer.isActive(state, "shift"), true)
            T.equal(Reducer.isActive(state, "ctrl"), false)
            T.equal(Reducer.isActive(Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state, "ctrl"), true)
        })

        Qt.exit(T.report("modifier reducer"))
    }
}
