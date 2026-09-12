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

        T.test("emote resolves to its recorded GTK application id, with the name as fallback only after the probe", function () {
            var pending = Fit.resolveClasses("emote", "")
            T.equal(pending.indexOf("com.tomjwatson.emote") >= 0, true)
            T.equal(pending.indexOf("emote") >= 0, false)
            var settled = Fit.resolveClasses("emote", "", true)
            T.equal(settled.indexOf("com.tomjwatson.emote") >= 0, true)
            T.equal(settled.indexOf("emote") >= 0, true)
        })

        T.test("a desktop entry's StartupWMClass joins the accepted classes", function () {
            T.deepEqual(Fit.resolveClasses("fancy-picker", "FancyWMClass"), ["fancywmclass"])
            T.deepEqual(Fit.resolveClasses("fancy-picker", "FancyWMClass", true),
                ["fancywmclass", "fancy-picker"])
        })

        T.test("an unknown app resolves to its own name only after the probe", function () {
            T.deepEqual(Fit.resolveClasses("Xmoji", ""), [])
            T.deepEqual(Fit.resolveClasses("Xmoji", "", true), ["xmoji"])
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

        // ---- identity of a compositor address (socket vs clients -j) ----
        // Recorded: closewindow>>55a20b2fac00, clients -j "address":"0x55a20b2fac00".

        T.test("sameAddress treats the socket form and the clients-j 0x form as one window", function () {
            T.equal(Fit.sameAddress("0x55a20b2fac00", "55a20b2fac00"), true)
            T.equal(Fit.sameAddress("55a20b2fac00", "0x55a20b2fac00"), true)
            T.equal(Fit.sameAddress("0x55a20b2fac00", "0x55a20b2fac00"), true)
            T.equal(Fit.sameAddress("55a20b2fac00", "55a20b2fac00"), true)
        })

        T.test("sameAddress rejects a different window and empty values", function () {
            T.equal(Fit.sameAddress("0x55a20b2fac00", "55a20b29b110"), false)
            T.equal(Fit.sameAddress("", "55a20b2fac00"), false)
            T.equal(Fit.sameAddress("0x55a20b2fac00", ""), false)
            T.equal(Fit.sameAddress("", ""), false)
        })

        // ---- Hyprland 0.56.2 event names (no client-geometry event) ----

        T.test("eventAction maps real session events and ignores move-to-workspace", function () {
            T.equal(Fit.eventAction("openwindow"), "open")
            T.equal(Fit.eventAction("closewindow"), "close")
            T.equal(Fit.eventAction("changefloatingmode"), "refit")
            T.equal(Fit.eventAction("windowtitle"), "refit")
            T.equal(Fit.eventAction("windowtitlev2"), "refit")
            T.equal(Fit.eventAction("configreloaded"), "output")
            T.equal(Fit.eventAction("monitoradded"), "output")
            T.equal(Fit.eventAction("monitoraddedv2"), "output")
            T.equal(Fit.eventAction("monitorremoved"), "output")
            T.equal(Fit.eventAction("movewindow"), "")
            T.equal(Fit.eventAction("movewindowv2"), "")
            T.equal(Fit.eventAction("resizewindow"), "")
            T.equal(Fit.eventAction("resizewindowv2"), "")
        })

        // ---- pin: never move a window that is not this session's appearance ----
        // Recorded addresses: emote 0x55a20b2fac00, a second client 0x55a20b29b110.

        function clientsOf() {
            return [
                { address: "0x55a20b2fac00", focusHistoryID: 2, at: [37, 37], size: [565, 549], floating: true },
                { address: "0x55a20b29b110", focusHistoryID: 0, at: [200, 100], size: [400, 300], floating: true }
            ]
        }

        T.test("pickClient keeps the pinned window even when another same-class client is focused", function () {
            var picked = Fit.pickClient(clientsOf(), "0x55a20b2fac00")
            T.equal(picked.address, "0x55a20b2fac00")
        })

        T.test("pickClient matches a pin across the socket and clients-j address forms", function () {
            var picked = Fit.pickClient(clientsOf(), "55a20b2fac00")
            T.equal(picked.address, "0x55a20b2fac00")
        })

        T.test("launchAddress waits for the class probe before claiming an unmatched openwindow", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b2fac00", "FancyWMClass")
            T.equal(Fit.launchAddress(seen, Fit.resolveClasses("fancy-picker", "")), "")
            T.equal(Fit.launchAddress(seen, Fit.resolveClasses("fancy-picker", "FancyWMClass")), "55a20b2fac00")
        })

        T.test("launchAddress is the first matching openwindow, not a later same-class sibling", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b2fac00", "emote")
            seen = Fit.rememberOpenwindow(seen, "55a20b29b110", "emote")
            T.equal(Fit.launchAddress(seen, Fit.resolveClasses("emote", "", true)), "55a20b2fac00")
        })

        T.test("bindLaunch leaves opened empty until the class probe settles", function () {
            var recorded = Fit.rememberOpenwindow([], "55a20b2fac00", "com.tomjwatson.Emote")
            T.deepEqual(Fit.bindLaunch([], recorded, Fit.resolveClasses("emote", ""), false, "emote"), [])
            var fallback = Fit.rememberOpenwindow([], "55a20b29b110", "fancy-picker")
            T.deepEqual(Fit.bindLaunch([], fallback, Fit.resolveClasses("fancy-picker", ""), false, "fancy-picker"), [])
        })

        T.test("bindLaunch after the probe prefers StartupWMClass over an earlier executable-name map", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b29b110", "fancy-picker")
            seen = Fit.rememberOpenwindow(seen, "55a20b2fac00", "FancyWMClass")
            T.deepEqual(Fit.bindLaunch([], seen, Fit.resolveClasses("fancy-picker", "FancyWMClass", true),
                true, "fancy-picker"), ["55a20b2fac00"])
        })

        T.test("bindLaunch after a failed probe uses the executable-name fallback", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b2fac00", "xmoji")
            T.deepEqual(Fit.bindLaunch([], seen, Fit.resolveClasses("Xmoji", "", true), true, "Xmoji"),
                ["55a20b2fac00"])
        })

        T.test("bindLaunch does not recompute opened from later openwindows or a wider class list", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b29b110", "other")
            seen = Fit.rememberOpenwindow(seen, "55a20b2fac00", "emote")
            var opened = Fit.bindLaunch([], seen, Fit.resolveClasses("emote", "", true), true, "emote")
            T.deepEqual(opened, ["55a20b2fac00"])
            seen = Fit.rememberOpenwindow(seen, "aaaa20b2fac00", "emote")
            T.deepEqual(Fit.bindLaunch(opened, seen, Fit.resolveClasses("emote", "other", true),
                true, "emote"), ["55a20b2fac00"])
        })

        T.test("a late matching openwindow is still the launch identity a closer can closewindow", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b2fac00", "emote")
            var opened = Fit.bindLaunch([], seen, Fit.resolveClasses("emote", "", true), true, "emote")
            T.deepEqual(opened, ["55a20b2fac00"])
            T.equal(Fit.pickClient(clientsOf(), "", opened).address, "0x55a20b2fac00")
        })

        T.test("pickClient does not take a later same-class openwindow as this session's picker", function () {
            var picked = Fit.pickClient(clientsOf(), "", ["55a20b2fac00", "55a20b29b110"])
            T.equal(picked.address, "0x55a20b2fac00")
        })

        T.test("pickClient does not adopt a concurrent sibling when the launch window is gone", function () {
            var remaining = [clientsOf()[1]]
            T.equal(Fit.pickClient(remaining, "0x55a20b2fac00", ["55a20b2fac00", "55a20b29b110"]), null)
        })

        T.test("pickClient adopts a recreate only from windows this session opened", function () {
            var remaining = [clientsOf()[1]]
            var picked = Fit.pickClient(remaining, "0x55a20b2fac00", ["55a20b29b110"])
            T.equal(picked.address, "0x55a20b29b110")
            T.equal(Fit.pickClient(remaining, "0x55a20b2fac00", ["55a20b2fac00"]), null)
            T.equal(Fit.pickClient(remaining, "0x55a20b2fac00", []), null)
        })

        T.test("pickClient returns null when nothing mapped", function () {
            T.equal(Fit.pickClient([], "0x55a20b2fac00"), null)
            T.equal(Fit.pickClient(null, ""), null)
        })

        T.test("pickClient does not grab a pre-existing same-class window before this session opens one", function () {
            T.equal(Fit.pickClient(clientsOf(), ""), null)
            T.equal(Fit.pickClient(clientsOf(), "", []), null)
            var opened = Fit.pickClient(clientsOf(), "", ["55a20b2fac00"])
            T.equal(opened.address, "0x55a20b2fac00")
        })

        T.test("pickClient does not take a unique unpinned client as launch ownership", function () {
            T.equal(Fit.pickClient([clientsOf()[0]], ""), null)
            T.equal(Fit.pickClient([clientsOf()[0]], "", []), null)
        })

        T.test("forgetOpenwindow drops a closed address and keeps later maps", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b2fac00", "emote")
            seen = Fit.rememberOpenwindow(seen, "55a20b29b110", "emote")
            var next = Fit.forgetOpenwindow(seen, "0x55a20b2fac00")
            T.equal(next.length, 1)
            T.equal(next[0].address, "55a20b29b110")
        })

        T.test("a dead first-in-seen does not bind after the class probe settles", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b29b110", "other")
            seen = Fit.rememberOpenwindow(seen, "55a20b2fac00", "emote")
            var rebound = Fit.rebindAfterClose(["55a20b29b110"], seen, "55a20b29b110",
                Fit.resolveClasses("emote", "", true), true, "emote")
            T.deepEqual(rebound.opened, ["55a20b2fac00"])
            T.equal(rebound.seen.length, 1)
            T.equal(rebound.seen[0].address, "55a20b2fac00")
        })

        T.test("rebindAfterClose does not retarget an opened address that is still live", function () {
            var seen = Fit.rememberOpenwindow([], "55a20b2fac00", "emote")
            seen = Fit.rememberOpenwindow(seen, "aaaa20b2fac00", "emote")
            var rebound = Fit.rebindAfterClose(["55a20b2fac00"], seen, "deadaddr",
                Fit.resolveClasses("emote", "", true), true, "emote")
            T.deepEqual(rebound.opened, ["55a20b2fac00"])
            T.equal(rebound.seen.length, 2)
        })

        T.test("attempt count keeps burning when only the plan target size-chases", function () {
            var band = { x: 0, y: 500, w: 1280, h: 300 }
            var work = { x: 0, y: 24, w: 1280, h: 776 }
            var key = Fit.placementCycleKey(band, work)
            T.equal(Fit.nextAttempts(3, key, Fit.placementCycleKey(band, work)), 3)
        })

        T.test("attempt count resets when the keyboard band or work area changes", function () {
            var band = { x: 0, y: 500, w: 1280, h: 300 }
            var work = { x: 0, y: 24, w: 1280, h: 776 }
            var key = Fit.placementCycleKey(band, work)
            T.equal(Fit.nextAttempts(3, key, Fit.placementCycleKey(
                { x: 0, y: 400, w: 1280, h: 300 }, work)), 0)
            T.equal(Fit.nextAttempts(3, key, Fit.placementCycleKey(
                band, { x: 0, y: 24, w: 1920, h: 776 })), 0)
        })

        T.test("dockedBand sits at the top of the bottom exclusive stack, not the output edge", function () {
            var output = { x: 0, y: 0, w: 1280, h: 800 }
            T.deepEqual(Fit.dockedBand(output, 300, 0),
                { x: 0, y: 500, w: 1280, h: 300 })
            // Bar 32 + strip 300: reserved[3] is the stack; the strip is the
            // top 300 of it, so the band starts 32 px above the output bottom.
            T.deepEqual(Fit.dockedBand(output, 300, 332),
                { x: 0, y: 468, w: 1280, h: 300 })
        })

        T.test("standalone emoji payload is not an OSK invocation", function () {
            T.equal(Fit.parseOskPayload(""), null)
            T.equal(Fit.parseOskPayload("{}"), null)
            T.equal(Fit.parseOskPayload("{\"menu\":\"root\"}"), null)
            T.equal(Fit.parseOskPayload("{\"osk\":false}"), null)
        })

        T.test("an OSK payload carries band, output and work area in logical units", function () {
            var output = { x: 0, y: 0, w: 1280, h: 800 }
            var workArea = { x: 0, y: 24, w: 1280, h: 476 }
            var band = { x: 0, y: 500, w: 1280, h: 300 }
            var parsed = Fit.parseOskPayload(JSON.stringify(
                Fit.oskPayload(band, output, workArea)))
            T.equal(parsed.osk, true)
            T.deepEqual(parsed.output, output)
            T.deepEqual(parsed.workArea, workArea)
            T.deepEqual(parsed.band, band)
        })

        T.test("the overlay card uses planPlacement, not a client move", function () {
            var payload = Fit.parseOskPayload(JSON.stringify(Fit.oskPayload(
                { x: 0, y: 500, w: 1280, h: 300 },
                { x: 0, y: 0, w: 1280, h: 800 },
                { x: 0, y: 24, w: 1280, h: 476 })))
            var plan = Fit.overlayCardPlan(payload, { x: 0, y: 0, w: 400, h: 500 }, null)
            T.equal(plan.status, "fit")
            T.equal(plan.region, "above")
            T.equal(plan.resized, true)
            T.deepEqual(plan.target, { x: 440, y: 24, w: 400, h: 468 })
        })

        T.test("the overlay mask hole is the panel band in output-local coordinates", function () {
            T.deepEqual(Fit.overlayHole(
                { x: 100, y: 700, w: 500, h: 80 },
                { x: 0, y: 0, w: 1280, h: 800 }),
                { x: 100, y: 700, w: 500, h: 80 })
            T.deepEqual(Fit.overlayHole(
                { x: -1500, y: 20, w: 400, h: 300 },
                { x: -1920, y: -360, w: 1920, h: 1080 }),
                { x: 420, y: 380, w: 400, h: 300 })
        })

        T.test("layer open and close events drive the shell overlay session", function () {
            T.equal(Fit.eventAction("openlayer"), "layerOpen")
            T.equal(Fit.eventAction("closelayer"), "layerClose")
        })

        Qt.exit(T.report("picker fit"))
    }
}
