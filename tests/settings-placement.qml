// Leftover-centre placement for the settings overlay (live-host ticket 05).
// Pure SettingsPlacement.js, no compositor (spec-v1.1 §8).
import QtQml
import "../SettingsPlacement.js" as Place
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

        Qt.exit(T.report("settings-placement"))
    }
}
