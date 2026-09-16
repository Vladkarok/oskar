// Leftover-centre placement for the settings overlay (live-host ticket 05).
// Pure SettingsPlacement.js, no compositor (spec-v1.1 §8). Ticket 23 also
// pins here, beside the placement it must not break: the colour row's
// control block (indicator square included) against the popover's own width
// formula at every size preset, and the committed values the indicator's
// fill displays — the pure layer of the row; the QML itself stays invisible
// to the suites (decisions §36).
import QtQml
import "../SettingsPlacement.js" as Place
import "../Config.js" as Config
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        var output = { x: 0, y: 0, w: 1280, h: 800 }

        T.test("docked leftover is the full-width strip above the band", function () {
            var band = Place.overlayBand("docked", output, { x: 0, y: 0, w: 1280, h: 240 })
            T.deepEqual(band, { x: 0, y: 560, w: 1280, h: 240 })
            T.deepEqual(Place.leftoverRect(output, band), { x: 0, y: 0, w: 1280, h: 560 })
        })

        T.test("settings sit at leftover centre, not glued to the band", function () {
            var band = { x: 0, y: 560, w: 1280, h: 240 }
            var pos = Place.centreInLeftover(output, band, { w: 400, h: 200 })
            T.deepEqual(pos, { x: 440, y: 180 })
            T.equal(pos.y + 200 < band.y, true)
        })

        T.test("keyboard parked at the top still leaves settings on-screen", function () {
            var band = { x: 0, y: 0, w: 1280, h: 240 }
            T.deepEqual(Place.leftoverRect(output, band), { x: 0, y: 240, w: 1280, h: 560 })
            var pos = Place.centreInLeftover(output, band, { w: 400, h: 200 })
            T.deepEqual(pos, { x: 440, y: 420 })
            T.equal(pos.y >= 240, true)
        })

        T.test("floating leftover uses the larger strip above or below the card", function () {
            var band = Place.overlayBand("floating", output,
                { x: 200, y: 500, w: 800, h: 240 })
            T.deepEqual(band, { x: 200, y: 500, w: 800, h: 240 })
            T.deepEqual(Place.leftoverRect(output, band), { x: 0, y: 0, w: 1280, h: 500 })
        })

        T.test("a surface taller than leftover is shrunk so it does not cover the band", function () {
            var band = { x: 0, y: 560, w: 1280, h: 240 }
            var fitted = Place.fitSizeInLeftover(output, band, { w: 400, h: 700 }, 8)
            T.equal(fitted.w, 400)
            T.equal(fitted.h, 560 - 16)
            var pos = Place.centreInLeftover(output, band, fitted)
            T.equal(pos.x, 440)
            T.equal(pos.y + fitted.h <= band.y, true)
        })

        T.test("leftover input is leftover, not a bounding union with the popover", function () {
            var band = { x: 0, y: 560, w: 1280, h: 240 }
            var leftover = Place.leftoverRect(output, band)
            var popover = { x: 400, y: 0, w: 480, h: 700 }
            T.deepEqual(leftover, { x: 0, y: 0, w: 1280, h: 560 })
            T.deepEqual(Place.overlayInputRect(output, band, popover, null), leftover)
            T.equal(popover.y + popover.h > leftover.y + leftover.h, true)
        })

        T.test("leftover input stays leftover when a tall editor overlaps the band", function () {
            var band = { x: 0, y: 560, w: 1280, h: 240 }
            var editor = { x: 440, y: 0, w: 400, h: 700 }
            T.deepEqual(Place.overlayInputRect(output, band, null, editor),
                { x: 0, y: 0, w: 1280, h: 560 })
        })

        T.test("a band that fills the output falls back to output centre", function () {
            var band = { x: 0, y: 0, w: 1280, h: 800 }
            T.deepEqual(Place.leftoverRect(output, band), output)
            T.deepEqual(Place.centreInLeftover(output, band, { w: 200, h: 100 }),
                { x: 540, y: 350 })
        })

        // ---- ticket 23: the colour row's indicator square ----
        //
        // The widest control block a colour row lays down grew by the
        // committed-colour indicator square. Nothing loads the QML, so the
        // block is restated here from the same pieces SettingsColorRow's
        // Flow draws and the popover's controlProbe measures — indicator
        // 24, four swatches 18, hex 76, confirm 24, Custom, reset 24, on
        // 6-space gaps — and a change to the row or the probe has to be
        // carried here by hand. That duplication is the offscreen suite's
        // standing limit, not new slack.

        // The popover's width formula: 2×10 margins + label column + the
        // widest of the control block and the 150+30 emoji-chooser floor.
        // Controls ride the theme's spacing scale, never the size preset —
        // presets scale keys — so the block is scale-1 arithmetic.
        function naturalPopoverWidth(customWidth, labelColumn) {
            var pieces = [24, 18, 18, 18, 18, 76, 24, customWidth, 24]
            var total = (pieces.length - 1) * 6
            for (var i = 0; i < pieces.length; i++) total += pieces[i]
            return 2 * 10 + labelColumn + Math.max(total, 150 + 30)
        }

        T.test("the control block with the indicator stays the card's width-setter", function () {
            // While the row's block exceeds the emoji chooser's floor, the
            // popover's width is derived FROM the row, so the row fits by
            // construction and any row widening propagates into the card.
            // Pinned so a block falling under the floor is a conscious
            // change, not a silent understatement. Custom's 64 is the
            // recorded width of the word and its padding at the reference
            // font; the label column 220 is deliberately wider than any
            // recorded theme label.
            var block = naturalPopoverWidth(64, 220) - 2 * 10 - 220
            T.equal(block > 150 + 30, true)
        })

        T.test("the row fits the card at every size preset, and the card scrolls", function () {
            var presets = Config.SIZE_PRESET_SCALES
            var tried = 0
            for (var preset in presets) {
                // The suite's recorded medium band, scaled as the keyboard's
                // card is by the preset.
                var band = Place.overlayBand("docked", output,
                    { x: 0, y: 0, w: 1280, h: Math.round(240 * presets[preset]) })
                var natural = {
                    w: naturalPopoverWidth(64, 220),
                    h: 700
                }
                var fitted = Place.fitSizeInLeftover(output, band, natural, 8)
                // Width untouched: the control block, indicator included,
                // fits the card at this preset.
                T.equal(fitted.w, natural.w)
                // Height clamped into the leftover — the card scrolls inside
                // rather than covering the band.
                var leftover = Place.leftoverRect(output, band)
                T.equal(fitted.h, leftover.h - 2 * 8)
                T.equal(fitted.h < natural.h, true)
                var pos = Place.centreInLeftover(output, band, fitted)
                T.equal(pos.y + fitted.h <= band.y, true)
                tried += 1
            }
            T.equal(tried, 3)
        })

        T.test("the indicator's committed values carry the awkward shapes", function () {
            // The shipped swatch palette is what the owner's five rows
            // showed; a custom colour must commit to a value distinct from
            // every swatch — the case that had no colour answer before the
            // square.
            var swatches = Config.recommendedSwatches(null)
            var custom = Config.commitHexDraft("#e06c75", true)
            T.equal(custom.action, "commit")
            T.equal(swatches.indexOf(custom.value), -1)
            // Very dark and very light values commit: the fills the
            // two-contrast edge exists to keep visible on the card.
            T.equal(Config.commitHexDraft("#0b0b0b", true).action, "commit")
            T.equal(Config.commitHexDraft("#f7f7f7", true).action, "commit")
            // An alpha-carrying commit keeps its alpha through the hex the
            // square and field display — not collapsed to opaque. Parsed
            // back to channels (the plain-QML runtime has no color provider,
            // so the parse is by hand) the committed value round-trips with
            // its alpha byte intact.
            var alpha = Config.commitHexDraft("#80e06c75", true)
            T.equal(alpha.action, "commit")
            T.equal(Config.toHex({ r: 224 / 255, g: 108 / 255, b: 117 / 255,
                a: 128 / 255 }), alpha.value)
        })

        Qt.exit(T.report("settings-placement"))
    }
}
