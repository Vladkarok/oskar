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
                keyRadius: 8,
                panelRadius: 12,
                keyBackground: "#303030",
                panelBackground: "#202020",
                textColor: "#f5f5f5",
                accentColor: "#7aa2f7",
                borderColor: "#5a5a5a"
            })
            T.deepEqual(Config.stateDefaults(), { position: null })
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

        T.test("invalid known overrides preserve the last valid value", function () {
            var previous = { sound: true }
            var out = Config.reloadOverrides(previous, '{"sound":"yes"}')
            T.equal(out.value, previous)
            T.equal(out.error, "Invalid value for sound")
        })

        T.test("valid external state reloads while malformed state is retained", function () {
            var first = Config.reloadState(Config.stateDefaults(), '{"position":{"x":12,"y":34}}')
            T.deepEqual(first.value, { position: { x: 12, y: 34 } })
            var malformed = Config.reloadState(first.value, '{"position":{"x":12}}')
            T.equal(malformed.value, first.value)
            T.equal(malformed.error, "Invalid value for position")
        })

        T.test("state serialization cannot copy preferences into state", function () {
            T.equal(Config.serializeState({ position: { x: 5, y: 9 }, mode: "floating" }),
                '{\n  "position": {\n    "x": 5,\n    "y": 9\n  }\n}\n')
        })

        // ---- the curated symbols page (spec-v1.1 §3, decisions §17) ----
        //
        // Availability is decided by a reverse index over the keycap
        // pipeline's own symbolMap: a curated entry is a keysym token, and it
        // is enabled only when some position and level of the complete active
        // keymap carries it. The tests below drive that pure layer with
        // synthetic keymaps.

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

        T.test("a complete keymap fills every slot and the rows still sum to the grid", function () {
            var full = {}
            for (var i = 0; i < Layout.curatedTokens.length; i++)
                full["K" + (i < 10 ? "0" + i : i)] = [Layout.curatedTokens[i], ""]
            var page = Layout.curatedPageRows(full)
            T.equal(page.available, Layout.curatedTokens.length)
            // Three content rows sized for the whole palette, then the
            // command row — which is identical to the other pages' but for
            // its own label.
            T.equal(page.rows.length, 4)
            T.deepEqual(page.rows[3], Layout.commandRow("ABC"))
            for (var r = 0; r < page.rows.length; r++) {
                var sum = 0
                for (var c = 0; c < page.rows[r].length; c++) {
                    var w = page.rows[r][c].w || 1
                    T.equal((w * 2) % 1, 0)
                    sum += w
                    // The free row's trailing half-unit pad is the one
                    // deliberately blank entry; with the palette complete,
                    // every other slot is a real cap.
                    if (Layout.isBlank(page.rows[r][c]))
                        T.equal(page.rows[r][c].w, 0.5)
                    else
                        T.equal(page.rows[r][c].hasOwnProperty("k")
                            || page.rows[r][c].hasOwnProperty("label"), true)
                }
                T.equal(sum, 15.5)
            }
            // Row shapes: esc .. ⌫, a free row, Shift .. Enter.
            T.deepEqual(page.rows[0][0], { label: "esc", key: "Escape", w: 1.0 })
            T.deepEqual(page.rows[0][page.rows[0].length - 1],
                { label: "\u232b", key: "BackSpace", w: 1.5 })
            T.deepEqual(page.rows[2][0], { label: "Shift", key: "shift", w: 2.5 })
            T.deepEqual(page.rows[2][page.rows[2].length - 1],
                { label: "Enter", key: "Return", w: 2.0 })
            // Every slot is a real level cap pointing where the index said.
            T.equal(page.rows[0][1].k, "K00")
            T.equal(page.rows[0][1].lvl, 1)
            T.equal(page.rows[2][1].k, "K28")
        })

        T.test("an incomplete keymap keeps the table order and pads with invisible spacers", function () {
            // EuroSign from the currency category, then section and
            // numerosign from the legal marks: three survivors, everything
            // between them in the table unavailable.
            var page = Layout.curatedPageRows({
                AE04: ["four", "EuroSign"],
                AE03: ["three", "numerosign", "section"]
            })
            T.equal(page.available, 3)
            T.equal(page.rows.length, 2)
            var row = page.rows[0]
            T.equal(row[1].k, "AE04")
            T.equal(row[1].lvl, 2)
            T.equal(row[2].k, "AE03")
            T.equal(row[2].lvl, 3)
            // Slots the keymap cannot fill are invisible spacers that keep
            // the row on the grid; the rest of the row is exactly the row's
            // fixed caps.
            var spacers = 0
            var sum = 0
            for (var c = 0; c < row.length; c++) {
                sum += row[c].w || 1
                if (Layout.isBlank(row[c])) {
                    spacers += 1
                    T.equal(row[c].hasOwnProperty("k"), false)
                    T.equal(row[c].hasOwnProperty("label"), false)
                }
            }
            T.equal(spacers, 10)
            T.equal(sum, 15.5)
            // The only other row is the command row.
            T.deepEqual(page.rows[1], Layout.commandRow("ABC"))
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

        Qt.exit(T.report("configuration"))
    }
}
