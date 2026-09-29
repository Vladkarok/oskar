import QtQuick
import qs.Commons
import "UiStrings.js" as UiStrings

// Per-override reset: a borderless muted glyph, accent under the pointer,
// shown only while resetting would change something (Config.resetOffered,
// through panel.resetOffered). Pure chrome over the panel API — the click
// calls clearOverride and nothing else; no persistence policy lives here.
Item {
    id: resetChip

    // The chrome tokens (the popover's live Omarchy theme) and the panel
    // itself (resetOffered, clearOverride, configHealthy).
    property var tokens
    property var panel
    property string overrideName: ""
    // False while the row it belongs to is inert (a setting that cannot
    // apply right now): the glyph stays where it is and takes no clicks.
    property bool active: true
    // Raised after the clear ran, so a host row can reconcile its own draft
    // with the now-restored effective value.
    signal resetClicked()

    width: tokens.space(24)
    height: tokens.space(24)
    visible: panel.resetOffered(resetChip.overrideName)

    // The Material "restore" icon from the Nerd Font set Omarchy itself
    // depends on (ttf-jetbrains-mono-nerd-basic): the theme face draws it
    // when it carries it, fontconfig falls back to that font when not. The
    // plain U+21BA is absent from the monospace faces and fell back to an
    // unrelated hook.
    Text {
        anchors.centerIn: parent
        text: String.fromCodePoint(0xF0450)
        color: resetChipArea.pressed || resetChipArea.containsMouse
            ? tokens.accent : tokens.muted
        font.family: tokens.fontFamily
        font.pixelSize: Math.round(tokens.fontBody * 1.25)
    }

    MouseArea {
        id: resetChipArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        Accessible.role: Accessible.Button
        Accessible.name: UiStrings.tr("access.resetSetting", panel.uiLang)
        enabled: panel.configHealthy && resetChip.active
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
