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

        T.test("idle + press -> unchanged, a bare tap", function () {
            var out = Reducer.reduce(idle, { type: "press", position: "AD03" })
            T.equal(out.state.ctrl, "idle")
            T.deepEqual(out.lines, ["tap AD03"])
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
            T.deepEqual(out.lines, ["down LCTL", "tap AD03", "up LCTL"])
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
            T.deepEqual(out.lines, ["tap AD03"])
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
                "tap AD03",
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
            T.deepEqual(first.lines, ["down LALT", "tap AB01", "up LALT"])
            state = first.state
            for (var i = 0; i < 9; i++) {
                var out = Reducer.reduce(state, { type: "press", position: "AB01" })
                T.deepEqual(out.lines, ["tap AB01"])
                state = out.state
            }
            T.equal(state.ctrl, "locked")
            T.equal(state.alt, "idle")
        })

        T.test("locked and latched stack on the same press", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD03" })
            T.deepEqual(out.lines, ["down LFSH", "tap AD03", "up LFSH"])
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

        T.test("a locked modifier still emits its hold after a page switch releases nothing", function () {
            var state = Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state
            state = Reducer.reduce(state, { type: "pageSwitch" }).state
            var out = Reducer.reduce(state, { type: "click", modifier: "ctrl" })
            T.deepEqual(out.lines, ["up LCTL"])
        })

        // ---- caps lock, which is emulated with Shift rather than the CAPS
        // position (grp:caps_toggle makes the real key a layout switch) ----

        T.test("caps lock shifts a letter key on its own", function () {
            var out = Reducer.reduce(idle, { type: "press", position: "AD01", letter: true, caps: true })
            T.deepEqual(out.lines, ["down LFSH", "tap AD01", "up LFSH"])
        })

        T.test("caps lock and a latched Shift cancel on a letter, and the latch still clears", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            var out = Reducer.reduce(state, { type: "press", position: "AD01", letter: true, caps: true })
            T.deepEqual(out.lines, ["tap AD01"])
            T.equal(out.state.shift, "idle")
        })

        T.test("caps lock does not shift a non-letter key", function () {
            var out = Reducer.reduce(idle, { type: "press", position: "AE01", letter: false, caps: true })
            T.deepEqual(out.lines, ["tap AE01"])
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

        T.test("isActive reports latched and locked but not idle", function () {
            var state = Reducer.reduce(idle, { type: "click", modifier: "shift" }).state
            T.equal(Reducer.isActive(state, "shift"), true)
            T.equal(Reducer.isActive(state, "ctrl"), false)
            T.equal(Reducer.isActive(Reducer.reduce(idle, { type: "doubleClick", modifier: "ctrl" }).state, "ctrl"), true)
        })

        Qt.exit(T.report("modifier reducer"))
    }
}
