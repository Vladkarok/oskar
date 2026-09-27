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
// Shown imperatively, with the wait kept here rather than in the popup. A
// declarative `ToolTip.text` ignores a text that changes while the popup
// waits out its delay, and `ToolTip.show` restarts the delay on every call,
// so the paste chip's peek — its text lands tens of milliseconds after the
// pointer — would open the tooltip a full delay after the TEXT, and a short
// touch-hold might never see it. One wait starts when the pointer lands or
// the hold begins; a text change during it changes nothing but the text the
// tooltip opens with, and a text change while it shows updates it in place.
// Every refresh is deferred to the end of the event, so a caller that
// changes text and hover in one handler is judged by where both ended up.
Item {
    id: tooltipHost
    property bool hovered: false
    property string text: ""
    property bool held: false
    // Whether this hover's (or hold's) wait has run out: the tooltip may
    // show at once from here until the pointer leaves or the hold ends.
    property bool opened: false

    anchors.fill: parent
    // The popup's own delay stays zero: the wait is `opening`'s.
    ToolTip.delay: 0

    Timer {
        id: opening
        interval: 500
        repeat: false
        onTriggered: {
            tooltipHost.opened = true
            tooltipHost.refresh()
        }
    }

    function refresh() {
        if (tooltipHost.text === "" || !(tooltipHost.hovered || tooltipHost.held)) {
            opening.stop()
            ToolTip.hide()
        } else if (tooltipHost.opened) {
            ToolTip.show(tooltipHost.text, 4000)
        } else if (!opening.running) {
            opening.start()
        }
    }
    function ended() {
        if (!tooltipHost.hovered && !tooltipHost.held) tooltipHost.opened = false
    }
    onTextChanged: Qt.callLater(refresh)
    onHoveredChanged: {
        ended()
        Qt.callLater(refresh)
    }
    onHeldChanged: {
        ended()
        Qt.callLater(refresh)
    }
}
