// The header's language control has three shapes, and the chooser's menu
// is pure data. Run with tools/run-tests.sh — no compositor, no display.
//
// The shapes are the owner's 2026-09-13 call (ticket 35, audit backlog
// item 1): one layout hides the control (an inert chip is noise), two
// toggle directly (the shape the panel always had), three or more open a
// chooser that moves the seat to an absolute group. A count >= 2 with no
// positively identified switch set stays visible but grey — hidden means
// "nothing to switch", not "nobody safe to move".
import QtQml
import "../LanguageControl.js" as LanguageControl
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("one layout hides the control", function () {
            T.equal(LanguageControl.controlState(1, 3), "hidden")
            T.equal(LanguageControl.controlState(1, 0), "hidden")
        })

        T.test("two layouts toggle directly", function () {
            T.equal(LanguageControl.controlState(2, 1), "direct")
            T.equal(LanguageControl.controlState(2, 3), "direct")
        })

        T.test("three or more open the chooser", function () {
            T.equal(LanguageControl.controlState(3, 2), "menu")
            T.equal(LanguageControl.controlState(4, 1), "menu")
        })

        T.test("no safe switch set stays visible but disabled", function () {
            T.equal(LanguageControl.controlState(2, 0), "disabled")
            T.equal(LanguageControl.controlState(5, 0), "disabled")
        })

        T.test("zero and junk counts read as nothing to switch", function () {
            T.equal(LanguageControl.controlState(0, 2), "hidden")
            T.equal(LanguageControl.controlState(-1, 2), "hidden")
        })

        T.test("menu entries keep group order and flag the active one", function () {
            var entries = LanguageControl.menuEntries(
                ["us", "ua", "de"], { us: "English (US)", ua: "Ukrainian" }, 1)
            T.deepEqual(entries, [
                { group: 0, code: "us", title: "English (US)", active: false },
                { group: 1, code: "ua", title: "Ukrainian", active: true },
                { group: 2, code: "de", title: "DE", active: false }
            ])
        })

        T.test("a missing title falls back to the uppercased code", function () {
            var entries = LanguageControl.menuEntries(["ru"], {}, 0)
            T.deepEqual(entries, [
                { group: 0, code: "ru", title: "RU", active: true }
            ])
        })

        T.test("duplicate codes stay distinct entries keyed by group", function () {
            // An xkb list can repeat a code across variants ("us,us" with
            // per-variant layouts); merging them would lose a group.
            var entries = LanguageControl.menuEntries(
                ["us", "us"], { us: "English (US)" }, 1)
            T.equal(entries.length, 2)
            T.equal(entries[0].group, 0)
            T.equal(entries[1].group, 1)
            T.equal(entries[1].active, true)
            T.equal(entries[0].active, false)
        })

        // ---- ticket 40: the chooser's field contract ----
        //
        // Panel.qml's chooser rows read entry.group (the click switches by
        // it, the armed row compares it to the live cursor) and entry.title
        // (the label and the accessible name). A rename in menuEntries
        // must break this suite, not read as `undefined` in the menu.
        T.test("every menu entry carries exactly the fields the chooser reads", function () {
            var entries = LanguageControl.menuEntries(
                ["us", "ua", "us"], { us: "English (US)", ua: "Ukrainian" }, 1)
            T.equal(entries.length, 3)
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i]
                T.deepEqual(Object.keys(entry).sort(),
                    ["active", "code", "group", "title"])
                T.equal(typeof entry.group, "number")
                T.equal(typeof entry.code, "string")
                T.equal(entry.code.length > 0, true)
                T.equal(typeof entry.title, "string")
                T.equal(entry.title.length > 0, true)
                T.equal(typeof entry.active, "boolean")
            }
            T.equal(entries[1].group, 1)
            T.equal(entries[1].active, true)
        })

        Qt.exit(T.report("language control"))
    }
}
