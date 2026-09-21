import QtQuick
import qs.Commons

// The owner's three-state drag line (the 2026-09-18 sketch), ONE home:
// the floating keyboard card's bar drew it first, the emoji page's
// free-drag strip wears it too — parity by construction, not
// copy-paste. The states are the sketch's: rest (quiet ink, full
// width), press-grab (the moment the hand closes on the host: brighter,
// shorter SYMMETRICALLY from both ends, lifted a touch), carried (the
// held look while the host follows the pointer). Hover alone does NOT
// count — a pointer passing over must not pretend a grab; only the
// alpha lifts, nothing moves.
//
// The host owns the MouseArea and passes its facts in (grabbed =
// pressed, carried = drag.active, hovered = containsMouse), plus the
// host-scaled geometry: the resting inset from each end (and the
// resting top margin), the per-end shortening on grab, the thickness
// before its 3px floor, and the press-grab's rise. The keyboard feeds
// it its cellGap arithmetic; the emoji page feeds it its own — the
// grammar is shared, the proportions belong to the host.
Rectangle {
    id: dragLine

    property var tokens
    property bool grabbed: false
    property bool carried: false
    property bool hovered: false
    // Resting inset from each end of the host bar; also the resting
    // top margin.
    property real edgeGap: 0
    // Per-end shortening while grabbed or carried — the symmetric
    // shrink, x and width together.
    property real shortenBy: 0
    // The line's thickness before the 3px floor.
    property real thickness: 3
    // The press-grab's rise, in the host's units.
    property real liftBy: 0

    // NO left/right anchors: symmetric shortening is x + width
    // together, and mixing anchors with x is what broke the keyboard
    // bar's left edge (x was ignored while the left anchor held the
    // edge in place).
    x: edgeGap + (grabbed || carried ? shortenBy : 0)
    width: parent.width - 2 * edgeGap
        - (grabbed || carried ? 2 * shortenBy : 0)
    height: Math.max(3, Math.round(thickness))
    anchors {
        top: parent.top
        topMargin: edgeGap - (grabbed ? liftBy : 0)
    }
    radius: height / 2
    color: Util.alpha(tokens.foreground,
        grabbed || carried ? 0.75
        : hovered ? 0.55 : 0.35)
    Behavior on x { NumberAnimation {
        duration: 110; easing.type: Easing.OutQuad } }
    Behavior on width { NumberAnimation {
        duration: 110; easing.type: Easing.OutQuad } }
    Behavior on anchors.topMargin { NumberAnimation {
        duration: 110; easing.type: Easing.OutQuad } }
    Behavior on color { ColorAnimation { duration: 110 } }
}
