import QtQuick
import QtQuick.Controls
import qs.Commons
import "Config.js" as ConfigFile
import "UiStrings.js" as UiStrings

// WinUI-style custom colour editor (spec-v1.1 §5, live-host ticket 07):
// large hue×saturation square, thin value slider, hex + RGB/HSV fields.
// Preview only until confirm. No hex pad — the main OSK types into the
// focused field. Confirm/Cancel are mouse-only.
Rectangle {
    id: editor

    property var tokens
    property var panel
    property string fieldName: ""
    property string labelText: ""
    property color oldColor: "transparent"

    property real workHue: 0
    property real workSat: 0
    property real workVal: 1
    property real workAlpha: 1
    property bool invalid: false
    property bool draftDirty: false
    property string channelMode: "rgb"
    property bool modeChooserOpen: false
    property bool syncingFields: false

    readonly property color workColor: Qt.hsva(workHue, workSat, workVal, workAlpha)
    readonly property var workRgb: ConfigFile.hsvToRgb(workHue, workSat, workVal)

    readonly property color liveColor: {
        if (!panel || panel.customEditorField === ""
            || panel.customEditorField !== editor.fieldName)
            return editor.oldColor
        return panel.colorForField(panel.customEditorField)
    }

    signal dismissed()

    function syncFromColor(color) {
        workHue = color.hsvHue >= 0 ? color.hsvHue : 0
        workSat = color.hsvSaturation
        workVal = color.hsvValue
        workAlpha = typeof color.a === "number" && color.a >= 0 ? color.a : 1
    }

    function followLiveIfClean() {
        if (!visible || draftDirty) return
        if (!panel || panel.customEditorField === ""
            || panel.customEditorField !== editor.fieldName)
            return
        editor.syncFromColor(liveColor)
        invalid = false
        editor.pushFields()
    }

    function markDraftDirty() {
        editor.draftDirty = true
    }

    function pushFields(skipHex) {
        editor.syncingFields = true
        if (!skipHex)
            hexInput.text = ConfigFile.toHex(editor.workColor).toLowerCase()
        if (editor.channelMode === "hsv") {
            c1Input.text = String(Math.round(editor.workHue * 360))
            c2Input.text = String(Math.round(editor.workSat * 100))
            c3Input.text = String(Math.round(editor.workVal * 100))
        } else {
            var rgb = editor.workRgb
            c1Input.text = String(Math.round(rgb.r * 255))
            c2Input.text = String(Math.round(rgb.g * 255))
            c3Input.text = String(Math.round(rgb.b * 255))
        }
        editor.syncingFields = false
    }

    function applyRgbChannels(r, g, b) {
        var hsv = ConfigFile.rgbToHsv(r, g, b)
        workHue = hsv.h
        workSat = hsv.s
        workVal = hsv.v
        editor.markDraftDirty()
        editor.pushFields()
    }

    function applyChannelEdit() {
        if (editor.syncingFields) return
        var max1 = editor.channelMode === "hsv" ? 360 : 255
        var max2 = editor.channelMode === "hsv" ? 100 : 255
        var p1 = ConfigFile.parseChannel(c1Input.text, max1)
        var p2 = ConfigFile.parseChannel(c2Input.text, max2)
        var p3 = ConfigFile.parseChannel(c3Input.text, max2)
        if (!p1.ok || !p2.ok || !p3.ok) {
            editor.invalid = true
            editor.markDraftDirty()
            return
        }
        editor.invalid = false
        if (editor.channelMode === "hsv") {
            workHue = ConfigFile.channelUnit(p1.value, 360)
            workSat = ConfigFile.channelUnit(p2.value, 100)
            workVal = ConfigFile.channelUnit(p3.value, 100)
            editor.markDraftDirty()
            editor.syncingFields = true
            hexInput.text = ConfigFile.toHex(editor.workColor).toLowerCase()
            editor.syncingFields = false
            return
        }
        editor.applyRgbChannels(
            ConfigFile.channelUnit(p1.value, 255),
            ConfigFile.channelUnit(p2.value, 255),
            ConfigFile.channelUnit(p3.value, 255))
    }

    function focusedField() {
        if (hexInput.activeFocus) return hexInput
        if (c1Input.activeFocus) return c1Input
        if (c2Input.activeFocus) return c2Input
        if (c3Input.activeFocus) return c3Input
        return null
    }

    function insertHexText(text) {
        var field = editor.focusedField()
        if (!field) field = hexInput
        ConfigFile.fieldSelectAll(field)
        ConfigFile.fieldInsert(field, text)
    }

    function applyDraft() {
        var hex = ConfigFile.toHex(editor.workColor).toLowerCase()
        if (!hex) hex = hexInput.text
        var result = ConfigFile.commitHexDraft(hex, panel.configHealthy)
        if (result.action === "reject") {
            invalid = true
            return
        }
        if (result.action === "hold") return
        invalid = false
        panel.applyColourOverride(editor.fieldName, result.value)
        editor.dismissed()
    }

    function beginField(name) {
        if (panel) panel.beginHexEdit(name)
    }

    function endField(name) {
        if (panel && panel.hexEditField === name) panel.endHexEdit()
    }

    onLiveColorChanged: editor.followLiveIfClean()
    onVisibleChanged: {
        if (visible) {
            draftDirty = false
            invalid = false
            modeChooserOpen = false
            channelMode = "rgb"
            editor.syncFromColor(oldColor)
            editor.pushFields()
        } else if (panel) {
            panel.endHexEdit()
        }
    }

    property real hostWidth: 0
    property real hostHeight: 0

    implicitWidth: tokens.space(10) * 2 + editorRow.implicitWidth
    implicitHeight: tokens.space(10) * 2 + editorColumn.implicitHeight
    readonly property real maxEditorWidth: hostWidth > 0
        ? Math.max(0, hostWidth - tokens.space(6) * 2) : implicitWidth
    readonly property real maxEditorHeight: hostHeight > 0
        ? Math.max(0, hostHeight - tokens.space(6) * 2) : implicitHeight
    width: maxEditorWidth > 0 ? Math.min(implicitWidth, maxEditorWidth) : implicitWidth
    height: maxEditorHeight > 0 ? Math.min(implicitHeight, maxEditorHeight)
        : implicitHeight
    radius: tokens.panelRadius
    color: tokens.tintTowardForeground(tokens.panelBackground, tokens.hoverFillAlpha)
    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    border.width: tokens.normalBorderWidth
    clip: true

    MouseArea {
        anchors.fill: parent
        hoverEnabled: false
        z: 0
    }

    Flickable {
        id: editorFlickable
        anchors.fill: parent
        anchors.margins: tokens.space(10)
        contentWidth: width
        contentHeight: editorColumn.implicitHeight
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        z: 1
        ScrollBar.vertical: ScrollBar {
            policy: editorFlickable.contentHeight > editorFlickable.height
                ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            implicitWidth: tokens.space(6)
            contentItem: Rectangle {
                implicitWidth: tokens.space(4)
                radius: width / 2
                color: parent.pressed ? tokens.accent
                    : Util.alpha(tokens.foreground, parent.hovered ? 0.45 : 0.28)
            }
            background: Item { implicitWidth: tokens.space(6) }
        }

        Column {
            id: editorColumn
            width: editorFlickable.width
            spacing: tokens.space(8)

        Text {
            text: UiStrings.tr("color.editor.title", editor.panel && editor.panel.uiLang)
            color: tokens.foreground
            font.family: tokens.fontFamily
            font.pixelSize: tokens.fontBody
            font.bold: true
        }

        Row {
            id: editorRow
            spacing: tokens.space(8)

            Rectangle {
                id: plane
                width: tokens.space(168)
                height: tokens.space(168)
                radius: tokens.space(4)
                clip: true
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "#ff0000" }
                    GradientStop { position: 0.17; color: "#ffff00" }
                    GradientStop { position: 0.33; color: "#00ff00" }
                    GradientStop { position: 0.5; color: "#00ffff" }
                    GradientStop { position: 0.67; color: "#0000ff" }
                    GradientStop { position: 0.83; color: "#ff00ff" }
                    GradientStop { position: 1.0; color: "#ff0000" }
                }

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#00ffffff" }
                        GradientStop { position: 1; color: "#ffffffff" }
                    }
                }

                Rectangle {
                    width: 14
                    height: 14
                    radius: 7
                    x: editor.workHue * (plane.width - width)
                    y: (1 - editor.workSat) * (plane.height - height)
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
                        editor.workHue = plane.width > 0
                            ? Math.max(0, Math.min(1, mouse.x / plane.width)) : 0
                        editor.workSat = plane.height > 0
                            ? 1 - Math.max(0, Math.min(1, mouse.y / plane.height)) : 1
                        editor.invalid = false
                        editor.markDraftDirty()
                        editor.pushFields()
                    }
                    onPressed: function (mouse) { planeArea.move(mouse) }
                    onPositionChanged: function (mouse) {
                        if (pressed) planeArea.move(mouse)
                    }
                }
            }

            Rectangle {
                width: tokens.space(22)
                height: plane.height
                radius: tokens.space(4)
                color: editor.workColor
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth
            }

            Rectangle {
                id: valueBar
                width: tokens.space(14)
                height: plane.height
                radius: tokens.space(4)
                gradient: Gradient {
                    GradientStop {
                        position: 0.0
                        color: Qt.hsva(editor.workHue, editor.workSat, 1, 1)
                    }
                    GradientStop { position: 1.0; color: "#000000" }
                }

                Rectangle {
                    width: parent.width + 4
                    height: 10
                    radius: 5
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: (1 - editor.workVal) * (parent.height - height)
                    color: "#ffffff"
                    border.color: "#000000"
                    border.width: 1
                }

                MouseArea {
                    id: valueArea
                    anchors.fill: parent
                    preventStealing: true

                    function move(mouse) {
                        editor.workVal = valueBar.height > 0
                            ? 1 - Math.max(0, Math.min(1, mouse.y / valueBar.height)) : 1
                        editor.invalid = false
                        editor.markDraftDirty()
                        editor.pushFields()
                    }
                    onPressed: function (mouse) { valueArea.move(mouse) }
                    onPositionChanged: function (mouse) {
                        if (pressed) valueArea.move(mouse)
                    }
                }
            }

            Column {
                spacing: tokens.space(6)
                width: tokens.space(132)

                Rectangle {
                    id: hexFieldBox
                    width: parent.width
                    height: tokens.space(26)
                    radius: tokens.cornerRadius
                    color: Util.alpha(tokens.background, 0.6)
                    border.color: editor.invalid ? tokens.urgent
                        : hexInput.activeFocus ? tokens.accent
                        : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: hexInput.activeFocus || editor.invalid
                        ? tokens.focusBorderWidth : tokens.normalBorderWidth

                    TextField {
                        id: hexInput
                        anchors.fill: parent
                        anchors.margins: tokens.space(5)
                        background: Item {}
                        padding: 0
                        leftPadding: 0
                        rightPadding: 0
                        topPadding: 0
                        bottomPadding: 0
                        verticalAlignment: TextInput.AlignVCenter
                        maximumLength: 9
                        color: editor.invalid ? tokens.urgent : tokens.foreground
                        selectionColor: tokens.accent
                        selectedTextColor: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        clip: true
                        selectByMouse: true
                        persistentSelection: true
                        onTextEdited: {
                            if (editor.syncingFields) return
                            editor.markDraftDirty()
                            var result = ConfigFile.normalizeHexDraft(hexInput.text)
                            if (!result.ok) {
                                editor.invalid = true
                                return
                            }
                            editor.invalid = false
                            editor.syncFromColor(Qt.color(result.value))
                            editor.pushFields(true)
                        }
                        onActiveFocusChanged: {
                            if (activeFocus) {
                                editor.beginField(editor.fieldName + ":hex")
                                hexInput.selectAll()
                            } else editor.endField(editor.fieldName + ":hex")
                        }
                        Keys.onEscapePressed: hexInput.focus = false
                    }
                }

                Item {
                    width: parent.width
                    height: tokens.space(26)
                    z: editor.modeChooserOpen ? 10 : 0
                    clip: false

                    Rectangle {
                        id: modeChooser
                        width: parent.width
                        height: parent.height
                        radius: tokens.cornerRadius
                        color: modeChooserArea.pressed ? tokens.accent
                            : editor.modeChooserOpen ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: tokens.normalBorderWidth

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: tokens.space(8)
                                verticalCenter: parent.verticalCenter
                            }
                            text: editor.channelMode === "hsv" ? "HSV" : "RGB"
                            color: modeChooserArea.pressed ? tokens.background : tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                        }

                        Text {
                            anchors {
                                right: parent.right
                                rightMargin: tokens.space(6)
                                verticalCenter: parent.verticalCenter
                            }
                            text: editor.modeChooserOpen ? "\u25b4" : "\u25be"
                            color: modeChooserArea.pressed ? tokens.background : tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                        }

                        MouseArea {
                            id: modeChooserArea
                            anchors.fill: parent
                            onClicked: editor.modeChooserOpen = !editor.modeChooserOpen
                        }
                    }

                    Rectangle {
                        visible: editor.modeChooserOpen
                        y: parent.height + tokens.space(2)
                        width: parent.width
                        height: menuColumn.implicitHeight + tokens.space(4)
                        radius: tokens.cornerRadius
                        color: tokens.panelBackground
                        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: tokens.normalBorderWidth
                        z: 2

                        Column {
                            id: menuColumn
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: tokens.space(2)
                            }
                            spacing: tokens.space(2)

                            Repeater {
                                model: [
                                    { value: "rgb", label: "RGB" },
                                    { value: "hsv", label: "HSV" }
                                ]
                                Rectangle {
                                    width: parent.width
                                    height: tokens.space(24)
                                    radius: tokens.cornerRadius
                                    color: optArea.containsMouse
                                        ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                                        : "transparent"
                                    border.color: modelData.value === editor.channelMode
                                        ? tokens.accent
                                        : "transparent"
                                    border.width: tokens.normalBorderWidth

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: tokens.foreground
                                        font.family: tokens.fontFamily
                                        font.pixelSize: tokens.fontBodySmall
                                    }

                                    MouseArea {
                                        id: optArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            editor.channelMode = modelData.value
                                            editor.modeChooserOpen = false
                                            editor.pushFields()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    spacing: tokens.space(6)
                    Rectangle {
                        width: tokens.space(64)
                        height: tokens.space(26)
                        radius: tokens.cornerRadius
                        color: Util.alpha(tokens.background, 0.6)
                        border.color: c1Input.activeFocus ? tokens.accent
                            : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: c1Input.activeFocus
                            ? tokens.focusBorderWidth : tokens.normalBorderWidth
                        TextInput {
                            id: c1Input
                            anchors.fill: parent
                            anchors.margins: tokens.space(5)
                            verticalAlignment: TextInput.AlignVCenter
                            maximumLength: 3
                            color: tokens.foreground
                            selectionColor: tokens.accent
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            onTextEdited: editor.applyChannelEdit()
                            onActiveFocusChanged: {
                                if (activeFocus) editor.beginField(editor.fieldName + ":c1")
                                else editor.endField(editor.fieldName + ":c1")
                            }
                            Keys.onEscapePressed: c1Input.focus = false
                        }
                    }
                    Text {
                        height: tokens.space(26)
                        verticalAlignment: Text.AlignVCenter
                        text: UiStrings.tr(editor.channelMode === "hsv"
                            ? "color.slider.hue" : "color.slider.red",
                            editor.panel && editor.panel.uiLang)
                        color: tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }
                }

                Row {
                    spacing: tokens.space(6)
                    Rectangle {
                        width: tokens.space(64)
                        height: tokens.space(26)
                        radius: tokens.cornerRadius
                        color: Util.alpha(tokens.background, 0.6)
                        border.color: c2Input.activeFocus ? tokens.accent
                            : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: c2Input.activeFocus
                            ? tokens.focusBorderWidth : tokens.normalBorderWidth
                        TextInput {
                            id: c2Input
                            anchors.fill: parent
                            anchors.margins: tokens.space(5)
                            verticalAlignment: TextInput.AlignVCenter
                            maximumLength: 3
                            color: tokens.foreground
                            selectionColor: tokens.accent
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            onTextEdited: editor.applyChannelEdit()
                            onActiveFocusChanged: {
                                if (activeFocus) editor.beginField(editor.fieldName + ":c2")
                                else editor.endField(editor.fieldName + ":c2")
                            }
                            Keys.onEscapePressed: c2Input.focus = false
                        }
                    }
                    Text {
                        height: tokens.space(26)
                        verticalAlignment: Text.AlignVCenter
                        text: UiStrings.tr(editor.channelMode === "hsv"
                            ? "color.slider.sat" : "color.slider.green",
                            editor.panel && editor.panel.uiLang)
                        color: tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }
                }

                Row {
                    spacing: tokens.space(6)
                    Rectangle {
                        width: tokens.space(64)
                        height: tokens.space(26)
                        radius: tokens.cornerRadius
                        color: Util.alpha(tokens.background, 0.6)
                        border.color: c3Input.activeFocus ? tokens.accent
                            : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: c3Input.activeFocus
                            ? tokens.focusBorderWidth : tokens.normalBorderWidth
                        TextInput {
                            id: c3Input
                            anchors.fill: parent
                            anchors.margins: tokens.space(5)
                            verticalAlignment: TextInput.AlignVCenter
                            maximumLength: 3
                            color: tokens.foreground
                            selectionColor: tokens.accent
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            onTextEdited: editor.applyChannelEdit()
                            onActiveFocusChanged: {
                                if (activeFocus) editor.beginField(editor.fieldName + ":c3")
                                else editor.endField(editor.fieldName + ":c3")
                            }
                            Keys.onEscapePressed: c3Input.focus = false
                        }
                    }
                    Text {
                        height: tokens.space(26)
                        verticalAlignment: Text.AlignVCenter
                        text: UiStrings.tr(editor.channelMode === "hsv"
                            ? "color.slider.val" : "color.slider.blue",
                            editor.panel && editor.panel.uiLang)
                        color: tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }
                }
            }
        }

        Row {
            spacing: tokens.space(6)

            SettingsConfirmChip {
                tokens: editor.tokens
                enabled: editor.panel && editor.panel.configHealthy
                accessName: UiStrings.tr("color.editor.confirm",
                    editor.panel && editor.panel.uiLang, [editor.labelText])
                onConfirmed: editor.applyDraft()
            }

            Rectangle {
                width: tokens.space(24)
                height: tokens.space(24)
                radius: tokens.cornerRadius
                color: cancelArea.pressed ? tokens.accent
                    : cancelArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    anchors.centerIn: parent
                    text: "\u2715"
                    color: cancelArea.pressed ? tokens.background : tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                MouseArea {
                    id: cancelArea
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: UiStrings.tr("color.editor.cancelDraft", editor.panel && editor.panel.uiLang)
                    onClicked: {
                        editor.panel.endHexEdit()
                        editor.dismissed()
                    }
                }
                HoverTooltip {
                    text: UiStrings.tr("color.editor.cancelEdit", editor.panel && editor.panel.uiLang)
                    hovered: cancelArea.containsMouse
                }
            }

            Text {
                visible: editor.invalid
                height: tokens.space(24)
                verticalAlignment: Text.AlignVCenter
                text: UiStrings.tr("color.editor.invalid", editor.panel && editor.panel.uiLang)
                color: tokens.urgent
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }
        }
    }
    }
}
