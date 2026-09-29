import QtQuick
import qs.Commons
import qs.Ui
import "Config.js" as ConfigFile
import "UiStrings.js" as UiStrings

// One colour row: label, then one control group — the current-colour
// square (the button that opens the custom editor), the hex draft, the
// confirm check while a draft is dirty, and the reset glyph. The hex field
// is a local draft until confirm or Return. A row may lead with an on/off
// switch for the setting the colour belongs to (the border): the colour
// group then shows only while the switch is on.
Item {
    id: colorRow

    property var tokens
    property var panel
    property string fieldName: ""
    property string labelText: ""
    property color effectiveColor: "transparent"
    // The committed colour as the row last wrote it: the indicator
    // square's fill. effectiveColor's binding is not relied on to notify
    // (see adoptHex below), so the square must not read it; every commit
    // point that writes the hex field writes this too — always a value a
    // commit path already validated, never a raw draft. Transparent, not
    // "": QML renders an empty-string colour as opaque black.
    property string currentHex: "#00000000"
    property real controlX: 0
    // False while the setting this colour belongs to is off (the border
    // colour with the border hidden): the colour group takes no writes.
    property bool active: true
    // A custom colour belongs to the custom look: while the theme answers,
    // the row is hidden by its host and must hold no focus and no draft (a
    // hidden field keeps keyboard focus; a disabled one gives it up).
    readonly property bool reachable: active && !panel.followTheme
    readonly property bool writable: panel.configHealthy && reachable
    // A row that stops being reachable drops its draft: a draft nobody can
    // see must not come back, and must never be committed.
    onReachableChanged: if (!reachable) showCommitted()
    // The leading switch: shown when the row carries one, bound by the host
    // to the setting's state, and its reset chip's override name.
    property bool hasSwitch: false
    property bool switchChecked: false
    property string switchOverrideName: ""
    // The row's label while it carries a switch: it names the setting the
    // switch turns on, and labelText stays the colour's own name for the
    // square's tooltip and the editor.
    property string switchLabel: ""
    readonly property bool colourShown: !hasSwitch || switchChecked
    signal customRequested()
    signal switchToggled()

    readonly property string effectiveHex: ConfigFile.toHex(effectiveColor).toLowerCase()
    property bool invalid: false
    property bool draftDirty: false
    readonly property bool editingThis: panel.hexEditing && panel.hexEditField === fieldName
    readonly property real controlLineHeight: tokens.space(26)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, controlLines.implicitHeight)
    // A row with a switch stays lit while the switch is live; its colour
    // group simply hides with the switch off.
    opacity: (hasSwitch ? panel.configHealthy : writable) ? 1 : 0.55

    // Show the committed value: the field and the square as Config.rowHex
    // says (the stored override as written while one is in force — a
    // translucent key background stays translucent, where effectiveHex is
    // the opaque cap it paints — else the colour now drawn). Clears any
    // draft state; callers decide whether a draft may be dropped.
    function showCommitted() {
        invalid = false
        draftDirty = false
        var shown = panel && panel.rowHexForField
            ? panel.rowHexForField(colorRow.fieldName)
            : { text: effectiveHex, square: effectiveHex }
        hexInput.text = shown.text
        currentHex = shown.square
    }

    onEffectiveColorChanged: {
        if (editingThis || draftDirty) return
        // Belt and braces: whether this binding notifies is not relied on
        // (the popover resyncs the rows), but when it does, the field and
        // the square move together.
        showCommitted()
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
        showCommitted()
        hexInput.focus = false
        if (panel.hexEditing && panel.hexEditField === colorRow.fieldName)
            panel.endHexEdit()
    }

    // Custom Apply writes the hex field itself. Do not
    // wait for effectiveColor — that binding sits behind `property var panel`
    // and is not relied on to notify.
    function adoptHex(hex) {
        var result = ConfigFile.commitHexDraft(hex, true)
        if (result.action === "reject") return
        draftDirty = false
        invalid = false
        hexInput.text = String(result.value).toLowerCase()
        currentHex = String(result.value).toLowerCase()
    }

    function revertDraft() {
        showCommitted()
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
        text: colorRow.hasSwitch ? colorRow.switchLabel : colorRow.labelText
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

            // The leading switch, track aligned with every other row's
            // control column: the shell's hover ring pads outside the
            // track, so the switch sits one pad to the left of its slot.
            Item {
                visible: colorRow.hasSwitch
                width: leadingSwitch.trackWidth
                height: colorRow.controlLineHeight

                ToggleSwitch {
                    id: leadingSwitch
                    x: -leadingSwitch.cursorPad
                    anchors.verticalCenter: parent.verticalCenter
                    foreground: tokens.foreground
                    accent: tokens.accent
                    interactive: colorRow.panel.configHealthy
                    cursorRing: true
                    checked: colorRow.switchChecked
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: colorRow.switchLabel
                    Accessible.checked: colorRow.switchChecked
                    onToggled: colorRow.switchToggled()
                }
            }

            SettingsResetChip {
                visible: colorRow.hasSwitch
                    && colorRow.panel.resetOffered(colorRow.switchOverrideName)
                tokens: colorRow.tokens
                panel: colorRow.panel
                overrideName: colorRow.switchOverrideName
            }

            // The colour in force, drawn as a colour, and the way into the
            // custom editor: a scan of the rows reads colours, not hexes.
            // The checkerboard underlay (foreground at two ladder steps)
            // shows through only when the committed colour carries alpha,
            // and the foreground/background ring pair bounds every fill —
            // very light, very dark or translucent — against either
            // theme's card. The fill is currentHex, updated at the commit
            // points.
            Rectangle {
                id: currentColourSquare
                visible: colorRow.colourShown
                width: tokens.space(24)
                height: colorRow.controlLineHeight
                radius: tokens.space(4)
                color: Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                opacity: colorRow.writable ? 1 : 0.55

                Rectangle {
                    width: parent.width / 2
                    height: parent.height / 2
                    color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                }

                Rectangle {
                    x: parent.width / 2
                    y: parent.height / 2
                    width: parent.width / 2
                    height: parent.height / 2
                    color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, tokens.space(4) - 1)
                    color: colorRow.currentHex
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, tokens.space(4) - 1)
                    color: "transparent"
                    border.color: Util.alpha(tokens.background, 0.9)
                    border.width: 1
                }

                Rectangle {
                    anchors.fill: parent
                    radius: tokens.space(4)
                    color: "transparent"
                    border.color: squareArea.containsMouse && colorRow.writable
                        ? tokens.accent : Util.alpha(tokens.foreground, 0.9)
                    border.width: squareArea.containsMouse && colorRow.writable
                        ? tokens.focusBorderWidth : tokens.normalBorderWidth
                }

                MouseArea {
                    id: squareArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: colorRow.writable
                    Accessible.role: Accessible.Button
                    Accessible.name: UiStrings.tr("color.openEditor",
                        colorRow.panel.uiLang, [colorRow.labelText])
                    Accessible.description: UiStrings.tr("color.currently",
                        colorRow.panel.uiLang,
                        [colorRow.labelText, colorRow.currentHex])
                    onClicked: {
                        panel.endHexEdit()
                        colorRow.customRequested()
                    }
                }
                HoverTooltip {
                    text: UiStrings.tr("color.openEditor", colorRow.panel.uiLang,
                        [colorRow.labelText])
                    hovered: panel && panel.inputAfford
                        ? squareArea.containsMouse
                            && panel.inputAfford.tooltipHoverShows
                        : squareArea.containsMouse
                }
            }

            Rectangle {
                id: hexField
                visible: colorRow.colourShown
                width: tokens.space(76)
                height: colorRow.controlLineHeight
                radius: tokens.cornerRadius
                color: Util.alpha(tokens.background, 0.6)
                opacity: colorRow.writable ? 1 : 0.55
                border.color: colorRow.invalid ? tokens.urgent
                    : colorRow.editingThis ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: colorRow.editingThis || colorRow.invalid
                    ? tokens.focusBorderWidth : tokens.normalBorderWidth

                TextInput {
                    id: hexInput
                    // An inert row takes no focus: the keys would go into a
                    // draft no Apply could commit.
                    enabled: colorRow.writable
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
                    // Keys reach this field only during the hex-edit focus
                    // exception, so Return is the typed twin of the check:
                    // it commits a dirty draft and nothing else.
                    Keys.onReturnPressed: if (colorRow.draftDirty) colorRow.applyDraft()
                    Keys.onEnterPressed: if (colorRow.draftDirty) colorRow.applyDraft()
                    Keys.onEscapePressed: {
                        colorRow.revertDraft()
                        hexInput.focus = false
                    }
                }
            }

            // A fixed slot, so the check appearing with a dirty draft never
            // shifts the reset glyph beside it.
            Item {
                visible: colorRow.colourShown
                width: tokens.space(24)
                height: colorRow.controlLineHeight

                SettingsConfirmChip {
                    anchors.centerIn: parent
                    visible: colorRow.draftDirty
                    tokens: colorRow.tokens
                    panel: colorRow.panel
                    enabled: colorRow.writable
                    accessName: UiStrings.tr("color.confirmHex",
                        colorRow.panel.uiLang, [colorRow.labelText])
                    z: 2
                    onConfirmed: colorRow.applyDraft()
                }
            }

            SettingsResetChip {
                visible: colorRow.colourShown
                    && colorRow.panel.resetOffered(colorRow.fieldName)
                tokens: colorRow.tokens
                panel: colorRow.panel
                overrideName: colorRow.fieldName
                active: colorRow.active
                onResetClicked: colorRow.revertDraft()
            }
        }

        Text {
            visible: colorRow.invalid && colorRow.colourShown
            width: parent.width
            wrapMode: Text.Wrap
            text: UiStrings.tr("color.invalidHex", colorRow.panel.uiLang)
            color: tokens.urgent
            font.family: tokens.fontFamily
            font.pixelSize: tokens.fontBodySmall
        }
    }

    Component.onCompleted: {
        if (!draftDirty) colorRow.showCommitted()
    }
}
