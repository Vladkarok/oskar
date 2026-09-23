import QtQuick
import qs.Commons

// Compact mouse-only confirm chip beside the hex field.
Rectangle {
    id: chip

    property var tokens
    property var panel
    property string accessName: "Confirm colour"
    signal confirmed()

    width: tokens.space(24)
    height: tokens.space(24)
    radius: tokens.cornerRadius
    color: chipArea.pressed ? tokens.accent
        : chipArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    border.width: tokens.normalBorderWidth
    opacity: enabled ? 1 : 0.55

    Text {
        anchors.centerIn: parent
        text: "\u2713"
        color: chipArea.pressed ? tokens.background : tokens.foreground
        font.family: tokens.fontFamily
        font.pixelSize: tokens.fontBodySmall
        font.bold: true
    }

    MouseArea {
        id: chipArea
        anchors.fill: parent
        hoverEnabled: true
        enabled: chip.enabled
        preventStealing: true
        Accessible.role: Accessible.Button
        Accessible.name: chip.accessName
        onClicked: chip.confirmed()
    }
    HoverTooltip {
        text: chip.accessName
        hovered: panel && panel.inputAfford
            ? chipArea.containsMouse && panel.inputAfford.tooltipHoverShows
            : chipArea.containsMouse
    }
}
