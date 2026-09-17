import QtQuick
import QtQuick.Controls

// Shared hover-only help for compact controls. The owning MouseArea remains
// the accessibility authority; this is deliberately only visual chrome.
//
// Ticket 58: `held` is the touch answer for the header's glyph chrome —
// where the profile's affordance table says "hold" (InputProfile.js),
// a touch-and-hold on the control shows the tooltip the hover used to
// (touch synthesizes no hover, so `hovered` alone would be silence). The
// caller owns the press-and-hold state; the release still acts through its
// own MouseArea — help-then-action, one gesture.
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
