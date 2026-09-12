import QtQuick
import qs.Commons
import "Config.js" as ConfigFile

// One colour row (spec-v1.1 §5): label, then one control group — swatches,
// hex draft, compact confirm, Custom, reset. Swatches belong to this row,
// not a shared strip. The hex field is a local draft until confirm.
Item {
    id: colorRow

    property var tokens
    property var panel
    property string fieldName: ""
    property string labelText: ""
    property color effectiveColor: "transparent"
    property real controlX: 0
    signal customRequested()

    readonly property string effectiveHex: ConfigFile.toHex(effectiveColor).toLowerCase()
    property bool invalid: false
    property bool draftDirty: false
    readonly property bool editingThis: panel.hexEditing && panel.hexEditField === fieldName
    readonly property real controlLineHeight: tokens.space(26)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, controlLines.implicitHeight)
    opacity: panel.configHealthy ? 1 : 0.55

    onEffectiveColorChanged: {
        if (editingThis) return
        invalid = false
        draftDirty = false
        hexInput.text = effectiveHex
    }

    function fieldFocusChanged(focused) {
        if (focused) {
            panel.beginHexEdit(colorRow.fieldName)
            hexInput.selectAll()
        } else if (panel.hexEditField === colorRow.fieldName) {
            panel.endHexEdit()
        }
    }

    function applyDraft() {
        var result = ConfigFile.commitHexDraft(hexInput.text, panel.configHealthy)
        if (result.action === "reject") {
            invalid = true
            return
        }
        if (result.action === "hold") return
        invalid = false
        draftDirty = false
        panel.setOverride(colorRow.fieldName, result.value)
        hexInput.text = result.value
        hexInput.focus = false
        if (panel.hexEditing && panel.hexEditField === colorRow.fieldName)
            panel.endHexEdit()
    }

    // Custom Apply (and swatches) write the hex field themselves. Do not
    // wait for effectiveColor — that binding sits behind `property var panel`
    // and does not notify.
    function adoptHex(hex) {
        var result = ConfigFile.commitHexDraft(hex, true)
        if (result.action === "reject") return
        draftDirty = false
        invalid = false
        hexInput.text = String(result.value).toLowerCase()
    }

    function revertDraft() {
        draftDirty = false
        invalid = false
        hexInput.text = effectiveHex
    }

    function resetDraft() {
        revertDraft()
    }

    function padTarget() {
        return hexInput
    }

    Text {
        id: rowLabel
        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
        }
        text: colorRow.labelText
        color: tokens.foreground
        font.family: tokens.fontFamily
        font.pixelSize: tokens.fontBody
    }

    Column {
        id: controlLines
        x: colorRow.controlX
        width: parent.width - x
        spacing: tokens.space(4)

        Flow {
            width: parent.width
            spacing: tokens.space(6)

            Repeater {
                model: panel.colorSwatches

                Rectangle {
                    property string hex: modelData
                    readonly property bool current: colorRow.effectiveHex === hex
                    width: tokens.space(18)
                    height: tokens.space(18)
                    radius: tokens.space(4)
                    color: hex
                    border.color: current ? tokens.accent
                        : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: current ? 2 : tokens.normalBorderWidth
                    Accessible.role: Accessible.Button
                    Accessible.name: "Set " + colorRow.labelText + " to " + hex

                    MouseArea {
                        anchors.fill: parent
                        enabled: panel.configHealthy
                        onClicked: {
                            colorRow.draftDirty = false
                            colorRow.invalid = false
                            panel.setOverride(colorRow.fieldName, parent.hex)
                            hexInput.text = parent.hex
                        }
                    }
                }
            }

            Rectangle {
                id: hexField
                width: tokens.space(76)
                height: colorRow.controlLineHeight
                radius: tokens.cornerRadius
                color: Util.alpha(tokens.background, 0.6)
                border.color: colorRow.invalid ? tokens.urgent
                    : colorRow.editingThis ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: colorRow.editingThis || colorRow.invalid
                    ? tokens.focusBorderWidth : tokens.normalBorderWidth

                TextInput {
                    id: hexInput
                    anchors.fill: parent
                    anchors.margins: tokens.space(5)
                    verticalAlignment: TextInput.AlignVCenter
                    maximumLength: 9
                    color: colorRow.invalid ? tokens.urgent : tokens.foreground
                    selectionColor: tokens.accent
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    clip: true
                    selectByMouse: true
                    persistentSelection: true
                    onTextEdited: {
                        colorRow.draftDirty = true
                        colorRow.invalid = false
                    }
                    onActiveFocusChanged: colorRow.fieldFocusChanged(activeFocus)
                    Keys.onEscapePressed: {
                        colorRow.revertDraft()
                        hexInput.focus = false
                    }
                }
            }

            SettingsConfirmChip {
                tokens: colorRow.tokens
                enabled: panel.configHealthy
                accessName: "Confirm " + colorRow.labelText + " hex"
                z: 2
                onConfirmed: colorRow.applyDraft()
            }

            Rectangle {
                id: customButton
                width: customLabel.implicitWidth + tokens.space(10) * 2
                height: colorRow.controlLineHeight
                radius: tokens.cornerRadius
                color: customArea.pressed ? tokens.accent
                    : customArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    id: customLabel
                    anchors.centerIn: parent
                    text: "Custom"
                    color: customArea.pressed ? tokens.background : tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                MouseArea {
                    id: customArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: panel.configHealthy
                    Accessible.role: Accessible.Button
                    Accessible.name: "Open the custom colour editor for " + colorRow.labelText
                    onClicked: {
                        panel.endHexEdit()
                        colorRow.customRequested()
                    }
                }
            }

            SettingsResetChip {
                tokens: colorRow.tokens
                panel: colorRow.panel
                overrideName: colorRow.fieldName
                onResetClicked: colorRow.revertDraft()
            }
        }

        Text {
            visible: colorRow.invalid
            width: parent.width
            wrapMode: Text.Wrap
            text: "invalid hex — use #RGB or #RRGGBB"
            color: tokens.urgent
            font.family: tokens.fontFamily
            font.pixelSize: tokens.fontBodySmall
        }
    }

    Component.onCompleted: {
        if (!draftDirty) hexInput.text = colorRow.effectiveHex
    }
}
