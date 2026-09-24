import QtQuick
import QtQuick.Shapes
import qs.Commons
import "UiStrings.js" as UiStrings

// Per-override reset chip: a counter-clockwise arrow in a bordered square, shown only while the
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

    // Drawn, not a glyph: the theme's monospace faces carry no U+21BA, and a
    // fallback face renders it as an unrelated hook.
    Shape {
        id: resetIcon
        readonly property real r: resetChip.width * 0.24
        readonly property real cx: resetChip.width / 2
        readonly property real cy: resetChip.height / 2
        // The arc's end (+30°, lower right), the direction of travel there
        // (counter-clockwise: up, slightly right) and the outward normal.
        readonly property real ea: Math.PI / 6
        readonly property real ex: cx + r * Math.cos(ea)
        readonly property real ey: cy + r * Math.sin(ea)
        readonly property real dx: Math.sin(ea)
        readonly property real dy: -Math.cos(ea)
        readonly property real nx: Math.cos(ea)
        readonly property real ny: Math.sin(ea)
        readonly property real head: resetChip.width * 0.18
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        // Three quarters of a circle, open on the right, and a chevron at
        // its end pointing counter-clockwise — one stroked path.
        ShapePath {
            strokeColor: resetChipArea.pressed ? tokens.background : tokens.foreground
            strokeWidth: Math.max(1.5, resetChip.width / 14)
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathAngleArc {
                centerX: resetIcon.cx; centerY: resetIcon.cy
                radiusX: resetIcon.r; radiusY: resetIcon.r
                startAngle: -60; sweepAngle: -270
            }
            PathMove {
                x: resetIcon.ex - resetIcon.dx * resetIcon.head + resetIcon.nx * resetIcon.head * 0.8
                y: resetIcon.ey - resetIcon.dy * resetIcon.head + resetIcon.ny * resetIcon.head * 0.8
            }
            PathLine { x: resetIcon.ex; y: resetIcon.ey }
            PathLine {
                x: resetIcon.ex - resetIcon.dx * resetIcon.head - resetIcon.nx * resetIcon.head * 0.8
                y: resetIcon.ey - resetIcon.dy * resetIcon.head - resetIcon.ny * resetIcon.head * 0.8
            }
        }
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
