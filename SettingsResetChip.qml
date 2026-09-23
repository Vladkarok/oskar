import QtQuick
import qs.Commons
import "UiStrings.js" as UiStrings

// Per-override reset chip: ↺ in a bordered square, shown only while the
// sparse config file actually carries this override. Pure chrome over the
// panel API — the click calls clearOverride and nothing else; no
// persistence policy lives here.
Rectangle {
    id: resetChip

    // The panel's live Theme facade and the panel itself (hasOverride,
    // clearOverride, configHealthy).
    property var tokens
    property var panel
    property string overrideName: ""
    // Raised after the clear ran, so a host row can reconcile its own draft
    // with the now-restored effective value.
    signal resetClicked()

    width: tokens.space(24)
    height: tokens.space(24)
    radius: tokens.cornerRadius
    visible: panel.hasOverride(resetChip.overrideName)
    color: resetChipArea.pressed ? tokens.accent
        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    border.width: tokens.normalBorderWidth

    Text {
        anchors.centerIn: parent
        text: "\u21ba"
        color: tokens.foreground
        font.family: tokens.fontFamily
        font.pixelSize: tokens.fontBodySmall
    }

    MouseArea {
        id: resetChipArea
        anchors.fill: parent
        hoverEnabled: true
        Accessible.role: Accessible.Button
        Accessible.name: UiStrings.tr("access.resetSetting", panel.uiLang)
        enabled: panel.configHealthy
        onClicked: {
            panel.clearOverride(resetChip.overrideName)
            resetChip.resetClicked()
        }
    }
    HoverTooltip {
        text: UiStrings.tr("access.resetSetting", panel.uiLang)
        // Text chrome: hidden under touch (tooltipTextChrome enforced).
        hovered: panel && panel.inputAfford
            ? resetChipArea.containsMouse
                && panel.inputAfford.tooltipHoverShows
            : resetChipArea.containsMouse
    }
}
