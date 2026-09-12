// Pure picker-fitting policy tests, beside the other panel reducer suites.
// Not a product seam: this drives the same pure PickerFit.js module the
// panel's placement host uses, with no compositor behind it (spec-v1.1 §8).
// The rectangles in the fixture comments are RECORDED from live sessions —
// the host's scale-2 output and a disposable nested Hyprland — not invented
// numbers; see .scratch/next-iteration/evidence/08/ for the raw queries.
import QtQml
import "../PickerFit.js" as Fit
import "harness.js" as T

QtObject {
    // Recorded on the host (2026-09-06, Hyprland 0.56.2): eDP-2, a 2560x1600
    // panel at scale 2 with a top bar reserved [0,24,0,0], and a tiled client
    // at [2,49] sized 1276x749 — logical units, no scale division wanted.
    readonly property var hostMonitor: ({
        name: "eDP-2", x: 0, y: 0, width: 2560, height: 1600, scale: 2,
        reserved: [0, 24, 0, 0]
    })

    Component.onCompleted: {
        // ---- one logical coordinate system ----

        T.test("logicalMonitorBox divides only the pixel size by scale", function () {
            T.deepEqual(Fit.logicalMonitorBox(hostMonitor), { x: 0, y: 0, w: 1280, h: 800 })
        })

        T.test("logicalMonitorBox handles fractional scale", function () {
            T.deepEqual(Fit.logicalMonitorBox(
                { name: "DP-1", x: 0, y: 0, width: 1920, height: 1080, scale: 1.5, reserved: [0, 0, 0, 0] }),
                { x: 0, y: 0, w: 1280, h: 720 })
        })

        T.test("logicalMonitorBox preserves negative monitor origins", function () {
            T.deepEqual(Fit.logicalMonitorBox(
                { name: "HEADLESS-1", x: -1920, y: -360, width: 1920, height: 1080, scale: 1, reserved: [0, 0, 0, 0] }),
                { x: -1920, y: -360, w: 1920, h: 1080 })
        })

        T.test("workArea subtracts reserved as [left, top, right, bottom]", function () {
            T.deepEqual(Fit.workAreaOf(hostMonitor), { x: 0, y: 24, w: 1280, h: 776 })
            T.deepEqual(Fit.workAreaOf(
                { name: "m", x: -100, y: 0, width: 1000, height: 800, scale: 1, reserved: [10, 20, 30, 40] }),
                { x: -90, y: 20, w: 960, h: 740 })
        })

        T.test("a missing or degenerate scale falls back to 1", function () {
            T.deepEqual(Fit.logicalMonitorBox(
                { name: "m", x: 0, y: 0, width: 1280, height: 800, scale: 0, reserved: [] }),
                { x: 0, y: 0, w: 1280, h: 800 })
        })

        // ---- identity: the specific appearance, not the executable name ----

        T.test("emote resolves to its recorded GTK application id, with the name as fallback", function () {
            var classes = Fit.resolveClasses("emote", "")
            T.equal(classes.indexOf("com.tomjwatson.emote") >= 0, true)
            T.equal(classes.indexOf("emote") >= 0, true)
        })

        T.test("a desktop entry's StartupWMClass joins the accepted classes", function () {
            var classes = Fit.resolveClasses("fancy-picker", "FancyWMClass")
            T.deepEqual(classes, ["fancywmclass", "fancy-picker"])
        })

        T.test("an unknown app resolves to its own name, case-insensitively", function () {
            T.deepEqual(Fit.resolveClasses("Xmoji", ""), ["xmoji"])
        })

        T.test("class matching accepts class or initialClass against any accepted class", function () {
            var classes = Fit.resolveClasses("emote", "")
            T.equal(Fit.classMatches("com.tomjwatson.Emote", "emote", classes), true)
            T.equal(Fit.classMatches("something", "com.Tomjwatson.EMOTE", classes), true)
            T.equal(Fit.classMatches("foot", "foot", classes), false)
        })

        // ---- rect helpers ----

        T.test("needsSettling flags zero and degenerate geometry only", function () {
            T.equal(Fit.needsSettling({ x: 0, y: 0, w: 0, h: 0 }), true)
            T.equal(Fit.needsSettling({ x: 10, y: 10, w: 500, h: 0 }), true)
            T.equal(Fit.needsSettling({ x: 10, y: 10, w: 500, h: 450 }), false)
        })

        T.test("sameRect compares within a tolerance", function () {
            T.equal(Fit.sameRect({ x: 100, y: 100, w: 500, h: 450 }, { x: 101, y: 99, w: 501, h: 449 }, 2), true)
            T.equal(Fit.sameRect({ x: 100, y: 100, w: 500, h: 450 }, { x: 104, y: 100, w: 500, h: 450 }, 2), false)
        })

        // ---- the approved fit policy: above (shorter if needed), then side,
        // ---- then expose the constraint ----

        // Recorded host shape: 1280x800 logical, top bar 24, docked strip
        // with the medium preset around 300 logical px tall.
        function dockedInput(picker, overrides) {
            var base = {
                output: { x: 0, y: 0, w: 1280, h: 800 },
                workArea: { x: 0, y: 24, w: 1280, h: 776 },
                band: { x: 0, y: 500, w: 1280, h: 300 },
                picker: picker,
                pickerMin: null
            }
            if (!overrides) return base
            for (var key in overrides) base[key] = overrides[key]
            return base
        }

        T.test("a picker that fits above the docked band is centred over it with the gap", function () {
            var plan = Fit.planPlacement(dockedInput({ x: 390, y: 300, w: 500, h: 450 }))
            T.deepEqual(plan, {
                status: "fit", region: "above", resized: false,
                target: { x: 390, y: 42, w: 500, h: 450 }, reason: ""
            })
        })

        T.test("above placement clamps horizontally into the work area", function () {
            var plan = Fit.planPlacement(dockedInput({ x: 0, y: 350, w: 900, h: 200 }))
            T.equal(plan.status, "fit")
            T.equal(plan.region, "above")
            T.equal(plan.target.x, 190)
            // Wider than the work area: the move clamps, the width is left to
            // the client — a move cannot fix it, so nothing pretends it did.
            var wide = Fit.planPlacement(dockedInput({ x: 0, y: 350, w: 1400, h: 200 }))
            T.equal(wide.status, "fit")
            T.equal(wide.target.x, 0)
        })

        T.test("a picker taller than the space above is planned shorter (scrollable) above the band", function () {
            // Above space: 500 - 24 = 476; a 550-tall picker must shrink to 468.
            var plan = Fit.planPlacement(dockedInput({ x: 390, y: 100, w: 500, h: 550 }))
            T.deepEqual(plan, {
                status: "fit", region: "above", resized: true,
                target: { x: 390, y: 24, w: 500, h: 468 }, reason: ""
            })
        })

        T.test("a picker that refuses the shrink cannot keep the above region, and docked has no side region", function () {
            // The picker refused the shorter resize (a fixed-minimum build;
            // the installed Emote accepts, so this is the mechanism for the
            // apps that do not): the plan is re-run with the observed
            // minimum recorded.
            var plan = Fit.planPlacement(dockedInput({ x: 390, y: 100, w: 500, h: 550 },
                { pickerMin: { w: 500, h: 550 } }))
            T.equal(plan.status, "unfit")
            T.equal(plan.region, "none")
            T.equal(plan.target, null)
            T.equal(plan.reason.indexOf("550") >= 0, true)
            T.equal(plan.reason.indexOf("476") >= 0, true)
        })

        T.test("a space above too small to be usable is not offered as a resize target", function () {
            // A giant band whose top leaves only 108 above the work area:
            // under the usable floor, so no resize-above is planned even for a
            // picker that would in principle scroll.
            var plan = Fit.planPlacement(dockedInput({ x: 390, y: 20, w: 500, h: 550 },
                { band: { x: 0, y: 132, w: 1280, h: 668 } }))
            T.equal(plan.status, "unfit")
            T.equal(plan.reason.indexOf("above") >= 0, true)
        })

        T.test("a fitting side region is used when above cannot take the picker", function () {
            // Floating card at {490,400,300x320}: above space 376 < the
            // picker's minimum 450; left region 490 wide fits a 400-wide picker.
            var plan = Fit.planPlacement({
                output: { x: 0, y: 0, w: 1280, h: 800 },
                workArea: { x: 0, y: 24, w: 1280, h: 776 },
                band: { x: 490, y: 400, w: 300, h: 320 },
                picker: { x: 490, y: 600, w: 400, h: 450 },
                pickerMin: { w: 400, h: 450 }
            })
            T.deepEqual(plan, {
                status: "fit", region: "left", resized: false,
                target: { x: 82, y: 335, w: 400, h: 450 }, reason: ""
            })
        })

        T.test("the side region sits inside the work area when the band is near an edge", function () {
            // A 600-tall picker (at its minimum) with 568 usable above: the
            // left region takes it, vertically clamped into the work area.
            var plan = Fit.planPlacement({
                output: { x: 0, y: 0, w: 1280, h: 800 },
                workArea: { x: 0, y: 24, w: 1280, h: 776 },
                band: { x: 900, y: 600, w: 300, h: 150 },
                picker: { x: 900, y: 500, w: 400, h: 600 },
                pickerMin: { w: 400, h: 600 }
            })
            T.equal(plan.status, "fit")
            T.equal(plan.region, "left")
            T.deepEqual(plan.target, { x: 492, y: 200, w: 400, h: 600 })
        })

        T.test("a picker already clear of the band and inside the work area is kept, not herded", function () {
            var plan = Fit.planPlacement(dockedInput({ x: 100, y: 60, w: 500, h: 400 }))
            T.deepEqual(plan, {
                status: "fit", region: "keep", resized: false,
                target: { x: 100, y: 60, w: 500, h: 400 }, reason: ""
            })
        })

        T.test("a picker clear of the band but outside the work area is re-fitted", function () {
            // Overlaps the top bar's reservation (workArea starts at y 24).
            var plan = Fit.planPlacement(dockedInput({ x: 100, y: 4, w: 500, h: 400 }))
            T.equal(plan.status, "fit")
            T.equal(plan.region, "above")
        })

        T.test("negative origins carry through the whole plan", function () {
            // A 1080-tall output at y -360: bottom edge 720, docked band 700
            // tall starting at y 20, work area from -336. A 340-tall picker
            // fits above as-is; every target coordinate stays negative.
            var plan = Fit.planPlacement({
                output: { x: -1920, y: -360, w: 1920, h: 1080 },
                workArea: { x: -1920, y: -336, w: 1920, h: 1056 },
                band: { x: -1920, y: 20, w: 1920, h: 700 },
                picker: { x: -1500, y: -400, w: 500, h: 340 },
                pickerMin: null
            })
            T.equal(plan.status, "fit")
            T.equal(plan.region, "above")
            T.deepEqual(plan.target, { x: -1210, y: -328, w: 500, h: 340 })
        })

        Qt.exit(T.report("picker fit"))
    }
}
