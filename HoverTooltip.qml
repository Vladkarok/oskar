import QtQuick
import QtQuick.Controls

// Shared hover-only help for compact controls. The owning MouseArea remains
// the accessibility authority; this is deliberately only visual chrome.
Item {
    id: tooltipHost
    property bool hovered: false
    property string text: ""

    anchors.fill: parent
    ToolTip.visible: tooltipHost.hovered && tooltipHost.text !== ""
    ToolTip.text: tooltipHost.text
    ToolTip.delay: 500
    ToolTip.timeout: 4000
}
