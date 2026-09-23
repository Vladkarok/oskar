import QtQuick
import QtQuick.Controls

// Shared hover-only help for compact controls. The owning MouseArea remains
// the accessibility authority; this is deliberately only visual chrome.
//
// `held` is the touch equivalent of hover: touch synthesizes no hover
// event, so `hovered` alone would never show the tooltip. The caller owns
// the press-and-hold state; release still acts through its own MouseArea —
// help-then-action in one gesture.
Item {
    id: tooltipHost
    property bool hovered: false
    property string text: ""
    property bool held: false

    anchors.fill: parent
    ToolTip.visible: tooltipHost.text !== ""
        && (tooltipHost.hovered || tooltipHost.held)
    ToolTip.text: tooltipHost.text
    ToolTip.delay: 500
    ToolTip.timeout: 4000
}
