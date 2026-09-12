import QtQuick
import qs.Commons
import "Config.js" as ConfigFile

// One compact colour row (spec-v1.1 §5, 2026-09-06 amendment): the label in
// the shared label column, and in the control zone two short lines — the
// theme's recommended swatches plus the reset chip, then the hex draft
// field, its Apply button and the Custom colour control. The old embedded
// saturation/value picker is gone from the row; Custom colour opens the
// larger separate editor for everything beyond one click.
//
// The hex field's text is a local draft until Apply. Invalid or incomplete
// text keeps the field editable, shows the inline error, and writes nothing;
// Enter may commit but is never required; Apply reads the draft whatever
// holds focus, so a focus-loss dismissal can never eat a commit. An external
// or theme change re-syncs the field only while no draft stands in it — the
// user's newer text is never silently overwritten.
Item {
    id: colorRow

    // The panel's live Theme facade and the panel itself (configHealthy,
    // setOverride, hasOverride, beginHexEdit, endHexEdit, hexEditing,
    // hexEditField, colorSwatches).
    property var tokens
    property var panel
    property string fieldName: ""
    property string labelText: ""
    // The colour now in force for this field — the override, or the
    // resolved token when none — fed in by the row's caller.
    property color effectiveColor: "transparent"
    // Where the control zone begins inside this row — the popover's shared
    // control column x.
    property real controlX: 0
    // Raised when the Custom colour control is clicked; the popover
    // forwards it to the panel, which opens the larger editor.
    signal customRequested()

    readonly property string effectiveHex: ConfigFile.toHex(effectiveColor).toLowerCase()
    // The field's error state: a refused draft. Nothing was written; the
    // field stays editable for correcting.
    property bool invalid: false
    // Whether the field holds a user draft (typed since the last sync or
    // commit). Only a standing draft blocks the automatic re-sync.
    property bool draftDirty: false

    readonly property bool editingThis: panel.hexEditing && panel.hexEditField === fieldName
    // The second control line is the widest thing any row lays down; the
    // popover measures the same pieces in its own hidden probe, so this row
    // never widens it.
    readonly property real controlLineHeight: tokens.space(26)

    width: parent ? parent.width : 0
    implicitHeight: controlLines.implicitHeight
    opacity: panel.configHealthy ? 1 : 0.55

    onEffectiveColorChanged: {
        if (!draftDirty) {
            invalid = false
            hexInput.text = effectiveHex
        }
    }

    // The §5 focus exception: this field being the active entry is what asks
    // the layer surface for keyboard focus (the panel owns the policy).
    // Focus leaving the field ends the exception but keeps the draft —
    // Apply stays clickable and the text stays correctable.
    function fieldFocusChanged(focused) {
        if (focused) {
            panel.beginHexEdit(colorRow.fieldName)
        } else if (panel.hexEditField === colorRow.fieldName) {
            panel.endHexEdit()
        }
    }

    function applyDraft() {
        // Bare digits are their hex form; a named colour or an incomplete
        // value is refused inline — nothing is written, nothing is closed.
        // The commit reads the draft whatever holds focus, so a focus-loss
        // dismissal can never eat an Apply.
        var result = ConfigFile.normalizeHexDraft(hexInput.text)
        if (!result.ok) {
            invalid = true
            return
        }
        invalid = false
        draftDirty = false
        panel.setOverride(colorRow.fieldName, result.value)
        hexInput.text = result.value
        // A committed Apply ends the entry: drop item focus (the blur runs
        // fieldFocusChanged's exit) and release the panel-side focus policy
        // explicitly, even if this field no longer held active focus.
        hexInput.focus = false
        if (panel.hexEditing && panel.hexEditField === colorRow.fieldName)
            panel.endHexEdit()
    }

    function revertDraft() {
        draftDirty = false
        invalid = false
        hexInput.text = effectiveHex
    }

    // The popover calls this when it (re)opens, so a stale draft never
    // outlives the surface that sanctioned it.
    function resetDraft() {
        revertDraft()
    }

    // The hex-entry pad's edit target: this row's draft field. The pad
    // inserts straight into it — no virtual keystroke leaves the panel.
    function padTarget() {
        return hexInput
    }

    Text {
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
        spacing: tokens.space(6)

        Row {
            spacing: tokens.space(6)

            // Up to four theme-derived swatches (background, foreground,
            // accent, muted; fallbacks maintained, duplicates collapsed).
            // One click writes the resolved colour as an explicit override —
            // immediate, like every non-draft control here.
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

            Item {
                width: 1
                height: tokens.space(18)
            }

            // A reset on THIS row is an explicit row action like a swatch:
            // it also drops the row's uncommitted draft, so the field never
            // sits there contradicting the reset it sits beside. (An
            // external or theme change, by contrast, never stomps a
            // standing draft.)
            SettingsResetChip {
                anchors.verticalCenter: parent.verticalCenter
                tokens: colorRow.tokens
                panel: colorRow.panel
                overrideName: colorRow.fieldName
                onResetClicked: colorRow.revertDraft()
            }
        }

        Row {
            spacing: tokens.space(6)

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
                    // The draft survives focus loss; only Apply/Escape/an
                    // explicit row action consumes it.
                    onTextEdited: {
                        colorRow.draftDirty = true
                        colorRow.invalid = false
                    }
                    onAccepted: colorRow.applyDraft()
                    onActiveFocusChanged: colorRow.fieldFocusChanged(activeFocus)
                    Keys.onEscapePressed: {
                        colorRow.revertDraft()
                        hexInput.focus = false
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.IBeamCursor
                        // A click into the field must focus it for editing,
                        // not only position the caret through the TextInput's
                        // own handling.
                        onClicked: hexInput.forceActiveFocus()
                    }
                }
            }

            Rectangle {
                id: applyButton
                width: applyLabel.implicitWidth + tokens.space(10) * 2
                height: colorRow.controlLineHeight
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
                    font.pixelSize: tokens.fontBodySmall
                    font.bold: true
                }

                MouseArea {
                    id: applyArea
                    anchors.fill: parent
                    enabled: panel.configHealthy
                    Accessible.role: Accessible.Button
                    Accessible.name: "Apply " + colorRow.labelText + " hex"
                    onClicked: colorRow.applyDraft()
                }
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
                    onClicked: colorRow.customRequested()
                }
            }
        }

        Text {
            visible: colorRow.invalid
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
