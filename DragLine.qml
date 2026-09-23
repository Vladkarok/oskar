import QtQuick
import qs.Commons

// Three-state drag line, shared by the floating keyboard card's bar and the
// emoji page's free-drag strip so both stay visually identical by
// construction rather than by copy-paste. States: rest (quiet ink, full
// width), press-grab (brighter, shortened SYMMETRICALLY from both ends,
// lifted a touch), carried (held look while the host follows the pointer).
// Hover alone does NOT count as a grab — only the alpha lifts, nothing
// moves.
//
// The host owns the MouseArea and passes its facts in (grabbed = pressed,
// carried = drag.active, hovered = containsMouse), plus the host-scaled
// geometry: the resting inset from each end (and the resting top margin),
// the per-end shortening on grab, the thickness before its 3px floor, and
// the press-grab's rise. The grammar is shared; the proportions belong to
// the host.
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

    // NO left/right anchors: symmetric shortening moves x and width
    // together, and mixing anchors with x lets the anchor win — x gets
    // ignored while the anchor pins that edge in place.
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
