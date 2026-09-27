import QtQuick
import QtQuick.Controls

// Shared hover-only help for compact controls. The owning MouseArea remains
// the accessibility authority; this is deliberately only visual chrome.
//
// `held` is the touch equivalent of hover: touch synthesizes no hover
// event, so `hovered` alone would never show the tooltip. The caller owns
// the press-and-hold state; release still acts through its own MouseArea —
// help-then-action in one gesture.
//
// Shown imperatively, after every change of text, hover or hold. A
// declarative `ToolTip.text` ignores a text that changes while the popup
// is still waiting out its delay, and the popup then opens with the text
// it had when the wait began — the paste chip's text arrives inside that
// wait. The refresh is deferred to the end of the event, so a caller that
// changes text and hover in one handler is judged by where both ended up.
Item {
    id: tooltipHost
    property bool hovered: false
    property string text: ""
    property bool held: false

    anchors.fill: parent
    ToolTip.delay: 500

    function refresh() {
        if (tooltipHost.text !== "" && (tooltipHost.hovered || tooltipHost.held))
            ToolTip.show(tooltipHost.text, 4000)
        else
            ToolTip.hide()
    }
    onTextChanged: Qt.callLater(refresh)
    onHoveredChanged: Qt.callLater(refresh)
    onHeldChanged: Qt.callLater(refresh)
}
