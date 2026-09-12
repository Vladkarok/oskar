import QtQuick
import qs.Commons
import "Config.js" as ConfigFile

// The custom colour editor (spec-v1.1 §5, 2026-09-06 amendment): one
// larger, separate surface for the selected setting — a generous
// saturation/value plane, a hue bar and a brightness bar, a synchronized
// hex field with the same local hex pad the popover rows use, and a clear
// old/new preview. Inspired by the owner's reference screenshot's size and
// interaction; its RGB/HSL mode menus, saved palettes, colour history and
// extra opacity controls are explicitly not built.
//
// Commit semantics: everything here is a LOCAL PREVIEW. Plane, bar and hex
// edits move the working HSV and the new swatch; nothing touches the
// overrides until Apply. Cancel — or any dismissal — drops only the
// uncommitted draft; previously applied settings survive. The editor never
// changes the panel's height or the docked reservation: it overlays the key
// grid inside the card, and its content scrolls when the card cannot
// host it all.
Rectangle {
    id: editor

    // The panel's live Theme facade and the panel itself (configHealthy,
    // setOverride, beginHexEdit, endHexEdit, hexEditing, hexEditField).
    property var tokens
    property var panel
    property string fieldName: ""
    property string labelText: ""

    // The colour in force when the editor opened — the preview's "old".
    property color oldColor: "transparent"

    // The working HSV. A grey has no hue: anchor the marker at red rather
    // than NaN-ing it off the bar.
    property real workHue: 0
    property real workSat: 0
    property real workVal: 1
    property bool invalid: false

    readonly property color workColor: Qt.hsva(workHue, workSat, workVal, 1)

    signal dismissed()

    function syncFromColor(color) {
        workHue = color.hsvHue >= 0 ? color.hsvHue : 0
        workSat = color.hsvSaturation
        workVal = color.hsvValue
    }

    onOldColorChanged: if (visible) editor.syncFromColor(oldColor)
    onVisibleChanged: {
        if (visible) {
            editor.syncFromColor(oldColor)
            invalid = false
            hexInput.text = ConfigFile.toHex(oldColor).toLowerCase()
        } else if (panel.hexEditField === editor.fieldName) {
            panel.endHexEdit()
        }
    }

    function applyHexText() {
        var result = ConfigFile.normalizeHexDraft(hexInput.text)
        if (!result.ok) {
            invalid = true
            return
        }
        invalid = false
        panel.setOverride(editor.fieldName, result.value)
        editor.dismissed()
    }

    radius: tokens.panelRadius
    color: tokens.tintTowardForeground(tokens.panelBackground, tokens.hoverFillAlpha)
    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    border.width: tokens.normalBorderWidth
    clip: true

    Flickable {
        id: editorScroll
        anchors.fill: parent
        anchors.margins: tokens.space(10)
        contentWidth: width
        contentHeight: editorColumn.implicitHeight
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: editorColumn
            width: editorScroll.width
            spacing: tokens.space(8)

        Text {
            text: editor.labelText + " — custom colour"
            color: tokens.foreground
            font.family: tokens.fontFamily
            font.pixelSize: tokens.fontBody
            font.bold: true
        }

        Row {
            spacing: tokens.space(8)

            // The plane: white fades over the working hue left-to-right
            // (saturation), black fades in bottom-up (value) — the classic
            // two-axis picker, three rectangles and no shader, at several
            // times the old embedded square's size.
            Rectangle {
                id: plane
                width: editor.width - tokens.space(24) - hueBar.width
                    - valueBar.width - tokens.space(16)
                height: tokens.space(120)
                radius: tokens.space(4)
                color: Qt.hsva(editor.workHue, 1, 1, 1)
                clip: true

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "#ffffffff" }
                        GradientStop { position: 1; color: "#00ffffff" }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#00000000" }
                        GradientStop { position: 1; color: "#ff000000" }
                    }
                }

                // Marker ring. Deliberate literals: the ring contrasts
                // against the colour being picked — an arbitrary,
                // user-chosen one — not against the theme.
                Rectangle {
                    width: 14
                    height: 14
                    radius: 7
                    x: editor.workSat * (plane.width - width)
                    y: (1 - editor.workVal) * (plane.height - height)
                    color: "transparent"
                    border.color: "#000000"
                    border.width: 3
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 1
                        radius: 6
                        color: "transparent"
                        border.color: "#ffffff"
                        border.width: 1
                    }
                }

                MouseArea {
                    id: planeArea
                    anchors.fill: parent
                    preventStealing: true

                    function move(mouse) {
                        editor.workSat = plane.width > 0
                            ? Math.max(0, Math.min(1, mouse.x / plane.width)) : 0
                        editor.workVal = plane.height > 0
                            ? 1 - Math.max(0, Math.min(1, mouse.y / plane.height)) : 1
                        hexInput.text = ConfigFile.toHex(editor.workColor).toLowerCase()
                    }
                    onPressed: function (mouse) { planeArea.move(mouse) }
                    onPositionChanged: function (mouse) {
                        if (pressed) planeArea.move(mouse)
                    }
                }
            }

            // The hue bar. Six stops walk the wheel; the marker agrees with
            // the plane and the hex at every step, because all three read
            // the one working HSV.
            Rectangle {
                id: hueBar
                width: tokens.space(18)
                height: plane.height
                radius: tokens.space(4)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#ff0000" }
                    GradientStop { position: 0.17; color: "#ffff00" }
                    GradientStop { position: 0.33; color: "#00ff00" }
                    GradientStop { position: 0.5; color: "#00ffff" }
                    GradientStop { position: 0.67; color: "#0000ff" }
                    GradientStop { position: 0.83; color: "#ff00ff" }
                    GradientStop { position: 1.0; color: "#ff0000" }
                }

                Rectangle {
                    width: parent.width
                    height: 4
                    radius: 2
                    y: editor.workHue * (parent.height - height)
                    color: "transparent"
                    border.color: "#ffffff"
                    border.width: 1
                }

                MouseArea {
                    id: hueArea
                    anchors.fill: parent
                    preventStealing: true

                    function move(mouse) {
                        editor.workHue = hueBar.height > 0
                            ? Math.max(0, Math.min(1, mouse.y / hueBar.height)) : 0
                        hexInput.text = ConfigFile.toHex(editor.workColor).toLowerCase()
                    }
                    onPressed: function (mouse) { hueArea.move(mouse) }
                    onPositionChanged: function (mouse) {
                        if (pressed) hueArea.move(mouse)
                    }
                }
            }

            // The brightness bar: the working hue at full saturation, from
            // black to full value — the named brightness control the plane's
            // value axis summarises, for pointing at brightness directly.
            Rectangle {
                id: valueBar
                width: tokens.space(18)
                height: plane.height
                radius: tokens.space(4)
                gradient: Gradient {
                    GradientStop {
                        position: 0.0
                        color: Qt.hsva(editor.workHue, 1, 1, 1)
                    }
                    GradientStop {
                        position: 1.0
                        color: Qt.hsva(editor.workHue, 1, 0, 1)
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 4
                    radius: 2
                    y: (1 - editor.workVal) * (parent.height - height)
                    color: "transparent"
                    border.color: editor.workVal > 0.5 ? "#000000" : "#ffffff"
                    border.width: 1
                }

                MouseArea {
                    id: valueArea
                    anchors.fill: parent
                    preventStealing: true

                    function move(mouse) {
                        editor.workVal = valueBar.height > 0
                            ? 1 - Math.max(0, Math.min(1, mouse.y / valueBar.height)) : 1
                        hexInput.text = ConfigFile.toHex(editor.workColor).toLowerCase()
                    }
                    onPressed: function (mouse) { valueArea.move(mouse) }
                    onPositionChanged: function (mouse) {
                        if (pressed) valueArea.move(mouse)
                    }
                }
            }
        }

        Row {
            spacing: tokens.space(8)

            Rectangle {
                width: tokens.space(64)
                height: tokens.space(24)
                radius: tokens.space(4)
                color: editor.oldColor
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "\u2192"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBody
            }

            Rectangle {
                width: tokens.space(64)
                height: tokens.space(24)
                radius: tokens.space(4)
                color: editor.workColor
                border.color: editor.invalid ? tokens.urgent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: editor.invalid ? tokens.focusBorderWidth
                    : tokens.normalBorderWidth
            }

            Rectangle {
                id: hexFieldBox
                width: tokens.space(84)
                height: tokens.space(26)
                radius: tokens.cornerRadius
                color: Util.alpha(tokens.background, 0.6)
                border.color: editor.invalid ? tokens.urgent
                    : hexInput.activeFocus ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: hexInput.activeFocus || editor.invalid
                    ? tokens.focusBorderWidth : tokens.normalBorderWidth

                TextInput {
                    id: hexInput
                    anchors.fill: parent
                    anchors.margins: tokens.space(5)
                    verticalAlignment: TextInput.AlignVCenter
                    maximumLength: 9
                    color: editor.invalid ? tokens.urgent : tokens.foreground
                    selectionColor: tokens.accent
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    clip: true

                    onTextEdited: {
                        // A valid draft moves the preview and the markers at
                        // once (synchronized); an invalid one is refused
                        // inline and leaves the last valid preview standing.
                        var result = ConfigFile.normalizeHexDraft(hexInput.text)
                        if (!result.ok) {
                            editor.invalid = true
                            return
                        }
                        editor.invalid = false
                        editor.syncFromColor(Qt.color(result.value))
                    }
                    onAccepted: editor.applyHexText()
                    onActiveFocusChanged: {
                        if (activeFocus) editor.panel.beginHexEdit(editor.fieldName)
                        else if (editor.panel.hexEditField === editor.fieldName)
                            editor.panel.endHexEdit()
                    }
                    Keys.onEscapePressed: hexInput.focus = false
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.IBeamCursor
                        onClicked: hexInput.forceActiveFocus()
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: editor.invalid
                text: "invalid hex"
                color: tokens.urgent
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }
        }

        SettingsHexPad {
            width: parent.width
            tokens: editor.tokens
            field: hexInput
        }

        Row {
            spacing: tokens.space(8)

            Rectangle {
                width: applyLabel.implicitWidth + tokens.space(12) * 2
                height: tokens.space(28)
                radius: tokens.cornerRadius
                color: applyArea.pressed ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    id: applyLabel
                    anchors.centerIn: parent
                    text: "Apply"
                    color: applyArea.pressed ? tokens.background : tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                    font.bold: true
                }

                MouseArea {
                    id: applyArea
                    anchors.fill: parent
                    enabled: editor.panel.configHealthy
                    Accessible.role: Accessible.Button
                    Accessible.name: "Apply the custom " + editor.labelText + " colour"
                    onClicked: editor.applyHexText()
                }
            }

            Rectangle {
                width: cancelLabel.implicitWidth + tokens.space(12) * 2
                height: tokens.space(28)
                radius: tokens.cornerRadius
                color: cancelArea.pressed ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    id: cancelLabel
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: cancelArea.pressed ? tokens.background : tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                MouseArea {
                    id: cancelArea
                    anchors.fill: parent
                    Accessible.role: Accessible.Button
                    Accessible.name: "Cancel the custom colour draft"
                    onClicked: editor.dismissed()
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "preview only — Apply writes the setting"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }
        }
        }
    }
}
