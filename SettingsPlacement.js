.pragma library

// Settings leftover-centre (live-host tickets 05/07, spec-v1.1 §5).
// Pure rect arithmetic: leftover is the larger full-width strip above or
// below the keyboard band; the popover/editor sits at that strip's centre.
// Leftover input is leftover-only. A card taller than leftover is fitted
// (scroll inside); it must not cover the keyboard band.

function validBox(box) {
    return !!(box
        && isFinite(box.x) && isFinite(box.y)
        && isFinite(box.w) && isFinite(box.h)
        && box.w > 0 && box.h > 0)
}

// Overlay-local keyboard band. Docked is a bottom strip of the overlay;
// floating uses the card's own rect inside a full-screen keyboard window.
function overlayBand(mode, overlay, card) {
    if (!validBox(overlay) || !card || !isFinite(card.w) || !isFinite(card.h))
        return { x: 0, y: 0, w: 0, h: 0 }
    var w = card.w, h = card.h
    if (mode === "docked")
        return { x: isFinite(card.x) ? card.x : 0, y: overlay.h - h, w: w, h: h }
    return {
        x: isFinite(card.x) ? card.x : 0,
        y: isFinite(card.y) ? card.y : 0,
        w: w, h: h
    }
}

// Full-width leftover strip: the larger of the regions above and below
// the band's vertical span. Equal heights prefer above (docked default).
// A band that fills the output falls back to the output itself.
function leftoverRect(output, band) {
    if (!validBox(output)) return { x: 0, y: 0, w: 0, h: 0 }
    if (!band || !isFinite(band.y) || !isFinite(band.h))
        return { x: output.x, y: output.y, w: output.w, h: output.h }
    var aboveH = Math.max(0, band.y - output.y)
    var belowH = Math.max(0, (output.y + output.h) - (band.y + band.h))
    if (aboveH === 0 && belowH === 0)
        return { x: output.x, y: output.y, w: output.w, h: output.h }
    if (aboveH >= belowH)
        return { x: output.x, y: output.y, w: output.w, h: aboveH }
    return { x: output.x, y: band.y + band.h, w: output.w, h: belowH }
}

// Cap a surface to leftover (minus gap). Scroll lives inside the card;
// the card itself must not cover the keyboard band.
function fitSizeInLeftover(output, band, size, gap) {
    var leftover = leftoverRect(output, band)
    var g = Number(gap)
    if (!isFinite(g) || g < 0) g = 0
    var maxW = Math.max(0, leftover.w - 2 * g)
    var maxH = Math.max(0, leftover.h - 2 * g)
    var w = size && isFinite(size.w) ? size.w : 0
    var h = size && isFinite(size.h) ? size.h : 0
    if (w > maxW) w = maxW
    if (h > maxH) h = maxH
    return { w: w, h: h }
}

function centreInLeftover(output, band, size) {
    var leftover = leftoverRect(output, band)
    var w = size && isFinite(size.w) ? size.w : 0
    var h = size && isFinite(size.h) ? size.h : 0
    if (!validBox(output) || w <= 0 || h <= 0) return { x: 0, y: 0 }
    var x = leftover.x + (leftover.w - w) / 2
    var y = leftover.y + (leftover.h - h) / 2
    var minX = leftover.x
    var minY = leftover.y
    var maxX = leftover.x + leftover.w - w
    var maxY = leftover.y + leftover.h - h
    if (maxX < minX) x = leftover.x
    else x = Math.max(minX, Math.min(x, maxX))
    if (maxY < minY) y = leftover.y
    else y = Math.max(minY, Math.min(y, maxY))
    return { x: Math.round(x), y: Math.round(y) }
}

// Leftover dismiss overlay only. Popover and editor are their own
// overlay windows; they must not expand this rect over uncovered keys.
function overlayInputRect(output, band) {
    return leftoverRect(output, band)
}

// ---- the emoji page's free drag (the emoji-drag ticket) ----
//
// The same deterministic-anchor rule the floating card owns
// (spec-v1.1 §4, ConfigFile.floatingAnchor), in this module's rect
// vocabulary: the visible area here is the whole overlay the page may
// be dragged in, not the leftover — free placement may cover the
// keyboard band; that is what "free" means.

// Clamp a w×h surface's top-left so it stays fully inside bounds. A
// surface larger than the bounds pins to the origin rather than
// inverting the clamp. Degenerate input answers null — the caller falls
// back to computed placement instead of trusting a guess.
function clampedTopLeft(point, size, bounds) {
    var w = size && isFinite(size.w) ? size.w : 0
    var h = size && isFinite(size.h) ? size.h : 0
    if (!point || !isFinite(point.x) || !isFinite(point.y)
        || !validBox(bounds) || w <= 0 || h <= 0)
        return null
    var maxX = bounds.x + Math.max(0, bounds.w - w)
    var maxY = bounds.y + Math.max(0, bounds.h - h)
    return {
        x: Math.round(Math.min(Math.max(point.x, bounds.x), maxX)),
        y: Math.round(Math.min(Math.max(point.y, bounds.y), maxY))
    }
}

// Re-derive the top-left from a remembered CENTRE against the CURRENT
// bounds: an unchanged centre, size and bounds restore the exact same
// top-left every time, and a smaller overlay, a different monitor or a
// different page size moves the page no further than staying fully
// visible demands — a remembered top-left instead restored to a
// different visible spot, the defect the card's own centre rule cured.
// No centre (or a degenerate size/bounds) answers null: the caller's
// fallback is today's computed leftover centre.
function centreRestore(center, size, bounds) {
    var w = size && isFinite(size.w) ? size.w : 0
    var h = size && isFinite(size.h) ? size.h : 0
    if (!center || !isFinite(center.x) || !isFinite(center.y)
        || w <= 0 || h <= 0)
        return null
    return clampedTopLeft({ x: center.x - w / 2, y: center.y - h / 2 },
        { w: w, h: h }, bounds)
}
