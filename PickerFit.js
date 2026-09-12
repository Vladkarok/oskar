// Pure picker-fitting policy (ticket 08, spec-v1.1 §1). No imports, no QML:
// every function here is deterministic rect arithmetic so the host suite in
// tests/picker-fit.qml can drive the exact policy the panel applies.
//
// UNITS. Everything is one logical coordinate system — the compositor's
// layout units, which are the units Quickshell screens, `hyprctl clients`
// at/size, and the move/resize dispatchers already speak. On the inspected
// stack (Hyprland 0.56.2, scale 2) client geometry is LOGICAL; the old code's
// divide-by-DPR here was the demonstrated defect. The ONLY remaining unit
// split is inside `hyprctl monitors -j`, whose width/height are the
// framebuffer's PHYSICAL pixels (m_pixelSize) while x/y are layout positions
// and `reserved` is logical — logicalMonitorBox is the one place that
// converts, verified against v0.56.2's HyprCtl.cpp and recorded in
// .scratch/next-iteration/evidence/08/.
//
// RECTangles are {x, y, w, h}. All arithmetic is integer-safe (compositor
// units are whole logical pixels in practice; callers pass what the JSON
// gave them and targets come out rounded).
//
// INTERFACE FOR THE SHELL INTEGRATION (ticket 10 consumes this). The Omarchy
// shell's emoji overlay needs the same fitting decision its own coordinates.
// The contract is planPlacement below: give it the output and work area from
// hyprctl monitors -j (through logicalMonitorBox/workAreaOf), the keyboard's
// band, and the picker's current rect and minimum size — all logical — and
// it returns the region, the exact target rectangle, and whether a shorter
// (scrollable) resize is part of the plan, or an honest "unfit" with the
// measured numbers when no region can take the picker. This module has no
// dependencies, so the shell can vendor it verbatim.

// ---- recorded identity ----
//
// The configured picker is named by its executable; the window it maps is
// not guaranteed to share the name. Matching therefore accepts several
// classes per app: the recorded table, the desktop entry's StartupWMClass
// (resolveClasses), Hyprland's initialClass, and the executable name as the
// last fallback. Recorded evidence (nested session, 2026-09-06,
// evidence/08): the installed Emote maps with class "emote" — its GTK
// application_id com.tomjwatson.Emote from the source is what OTHER
// versions/stacks may surface — so both are listed and either matches.
var KNOWN_WINDOW_CLASSES = {
    emote: ["com.tomjwatson.Emote"]
}

// Accepted window classes for a configured app: the recorded table, plus the
// StartupWMClass the one-shot desktop-entry probe found (already extracted,
// passed as a string), plus the executable name as the last fallback —
// always lowercase, deduplicated. `desktopEntryText` may be null/empty when
// the probe has not answered or found nothing.
function resolveClasses(app, desktopEntryText) {
    var out = []
    function push(name) {
        if (!name) return
        var low = String(name).toLowerCase()
        if (out.indexOf(low) === -1) out.push(low)
    }
    var known = KNOWN_WINDOW_CLASSES[String(app).toLowerCase()] || []
    for (var i = 0; i < known.length; i++) push(known[i])
    if (desktopEntryText) push(String(desktopEntryText).trim())
    push(app)
    return out
}

// A client identifies with the appearance when either of Hyprland's class
// fields matches any accepted class, case-insensitively.
function classMatches(clientClass, initialClass, classes) {
    function norm(value) { return value ? String(value).toLowerCase() : "" }
    for (var i = 0; i < classes.length; i++) {
        if (norm(clientClass) === classes[i]) return true
        if (norm(initialClass) === classes[i]) return true
    }
    return false
}

// ---- monitors -j conversions ----

// One monitors -j entry → the output's LOGICAL box. width/height are the
// physical pixel size (m_pixelSize in the compositor source) and divide by
// the scale once; x/y are already layout positions. A degenerate scale is
// treated as 1 rather than producing an Infinity box.
function logicalMonitorBox(mon) {
    var scale = mon && mon.scale > 0 ? mon.scale : 1
    return {
        x: mon.x,
        y: mon.y,
        w: Math.round(mon.width / scale),
        h: Math.round(mon.height / scale)
    }
}

// The work area: the output minus the compositor's reserved edges (layer
// surfaces with exclusive zones — Omarchy's bar, our own docked strip). The
// JSON order is [left, top, right, bottom] (HyprCtl.cpp, v0.56.2).
function workAreaOf(mon) {
    var box = logicalMonitorBox(mon)
    var r = mon.reserved || []
    var left = r[0] || 0
    var top = r[1] || 0
    var right = r[2] || 0
    var bottom = r[3] || 0
    return {
        x: box.x + left,
        y: box.y + top,
        w: Math.max(0, box.w - left - right),
        h: Math.max(0, box.h - top - bottom)
    }
}

// ---- rect helpers ----

function overlaps(a, b) {
    return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

function contains(outer, inner) {
    return inner.x >= outer.x && inner.y >= outer.y
        && inner.x + inner.w <= outer.x + outer.w
        && inner.y + inner.h <= outer.y + outer.h
}

// A freshly mapped window can report 0x0 until its first commit settles;
// planning against that would "place" it nowhere. The host waits (bounded)
// for real geometry instead.
function needsSettling(rect) {
    return !(rect && rect.w > 0 && rect.h > 0)
}

function sameRect(a, b, tolerance) {
    if (!a || !b) return false
    return Math.abs(a.x - b.x) <= tolerance && Math.abs(a.y - b.y) <= tolerance
        && Math.abs(a.w - b.w) <= tolerance && Math.abs(a.h - b.h) <= tolerance
}

function clampRect(value, low, high) {
    if (high < low) return low
    return Math.max(low, Math.min(high, value))
}

// ---- the approved fit policy ----
//
// Owner-settled 2026-09-06 (ticket 08 Comments): prefer a shorter/scrollable
// picker ABOVE the keyboard first; then a fitting SIDE region; where the
// app's minimum size prevents every region from fitting, say so instead of
// declaring an overlapping placement a success.
//
// Input, all logical:
//   output    — the target output's logical box (the panel's screen)
//   workArea  — the output minus reserved edges (workAreaOf)
//   band      — the keyboard band to keep clear: the docked strip, or the
//               floating card
//   picker    — the identified picker window's current rect
//   pickerMin — the smallest size the picker has been observed to accept
//               (after a refused shrink), or null while unknown
//   gap       — clearance between picker and band (default 8)
//   minUsableHeight — the shortest "shorter/scrollable" above-region still
//               worth asking the picker to shrink into (default 160): below
//               it the region is not offered at all, so the policy never
//               squanders a picker nobody can use.
//
// Result:
//   status  "fit" | "unfit"
//   region  "keep" (already clear and inside the work area — positioning,
//            not herding), "above", "left", "right", or "none"
//   resized plan asks the compositor to shrink the picker (scrollable) to
//           reach the region
//   target  the exact rectangle the picker should end up at (null on unfit)
//   reason  "" on success; on unfit, the measured numbers, so the panel can
//           expose the constraint honestly instead of a vague failure.
function planPlacement(input) {
    var band = input.band
    var picker = input.picker
    var workArea = input.workArea
    var gap = input.gap === undefined ? 8 : input.gap
    var minUsableHeight = input.minUsableHeight === undefined ? 160 : input.minUsableHeight
    var min = input.pickerMin
        ? {
            w: Math.max(picker.w, input.pickerMin.w),
            h: Math.max(picker.h, input.pickerMin.h)
        }
        : { w: picker.w, h: picker.h }

    // Already clear of the band and fully inside the work area: the courtesy
    // is positioning, not herding — leave it where the user has it.
    if (!overlaps(picker, band) && contains(workArea, picker)) {
        return {
            status: "fit", region: "keep", resized: false,
            target: { x: picker.x, y: picker.y, w: picker.w, h: picker.h },
            reason: ""
        }
    }

    var numbers = { picker: min.w + "x" + min.h }

    // Region 1: above the band, bounded by the work area's top edge. (In
    // docked mode our own reservation is part of `reserved`, so the work
    // area's bottom edge is the band's top; aboveSpace covers either mode.)
    var aboveSpace = band.y - workArea.y
    numbers.above = aboveSpace
    if (picker.h <= aboveSpace - gap) {
        var w = picker.w
        var x = clampRect(band.x + Math.floor((band.w - w) / 2),
            workArea.x, workArea.x + workArea.w - w)
        return {
            status: "fit", region: "above", resized: false,
            target: { x: x, y: band.y - gap - picker.h, w: w, h: picker.h },
            reason: ""
        }
    }
    // Same region, shorter: ask the compositor to resize the picker to the
    // space that exists (a shorter, scrollable picker). Whether the app
    // accepts is empirical — the installed Emote does, a fixed-minimum
    // build may refuse — so the attempt is the experiment, and the host
    // verifies the resulting rectangle and records a refusal as pickerMin
    // for the next plan. Never offered below the usable floor.
    if (aboveSpace - gap >= minUsableHeight
        && (input.pickerMin === null || input.pickerMin === undefined
            || min.h <= aboveSpace - gap)) {
        var targetH = aboveSpace - gap
        var targetW = Math.min(picker.w, workArea.w)
        return {
            status: "fit", region: "above", resized: true,
            target: {
                x: clampRect(band.x + Math.floor((band.w - targetW) / 2),
                    workArea.x, workArea.x + workArea.w - targetW),
                y: band.y - gap - targetH,
                w: targetW,
                h: targetH
            },
            reason: ""
        }
    }

    // Region 2: a fitting side region — only when the band leaves output
    // beside it (floating mode; a docked strip spans the whole width and
    // genuinely has none). The picker is taken at its minimum; no resize is
    // offered sideways. The wider side wins, reading order breaks a tie.
    var leftWidth = band.x - workArea.x
    var rightWidth = workArea.x + workArea.w - (band.x + band.w)
    numbers.left = leftWidth
    numbers.right = rightWidth
    var sides = [
        { region: "left", width: leftWidth },
        { region: "right", width: rightWidth }
    ].sort(function (a, b) { return b.width - a.width || (a.region === "left" ? -1 : 1) })
    for (var i = 0; i < sides.length; i++) {
        var side = sides[i]
        if (min.w > side.width - gap) continue
        var tx = side.region === "left"
            ? band.x - gap - min.w
            : band.x + band.w + gap
        var ty = clampRect(band.y + Math.floor((band.h - min.h) / 2),
            workArea.y, workArea.y + workArea.h - min.h)
        return {
            status: "fit", region: side.region, resized: false,
            target: { x: tx, y: ty, w: min.w, h: min.h },
            reason: ""
        }
    }

    // No region: expose the constraint with its numbers rather than
    // declaring an overlapping placement successful.
    return {
        status: "unfit", region: "none", resized: false, target: null,
        reason: "picker " + numbers.picker + " fits no clear region: above offers "
            + aboveSpace + "px, left " + leftWidth + "px, right " + rightWidth + "px"
    }
}
