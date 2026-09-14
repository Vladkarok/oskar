import QtQuick
import QtQuick.Controls
import qs.Commons
import "Config.js" as ConfigFile
import "Dwell.js" as Dwell

// The settings popover (spec-v1.1 §5). Lives on its own overlay window,
// not on the key grid: leftover-centre placement is the panel's, exclusive
// zone stays the keyboard band. Colour rows group swatches with hex and a
// compact confirm; Custom opens the WinUI editor. The panel is the one
// persistence authority — this surface only reads effective values and
// issues changes. Scrolling changes height only.
Rectangle {
    id: popoverRoot

    // Hidden until the gear opens it. Leftover dismiss and this window
    // both key off this flag.
    visible: false

    // The panel (root) and its live Theme facade. The panel is the one
    // home of config state and writes; this file is presentation.
    property var panel
    property var tokens

    // Overlay size the popover may occupy. Placement (leftover centre) is
    // applied by the panel as x/y; this only clamps to the output.
    property real hostWidth: 0
    property real hostHeight: 0

    // Reset-all's confirmation state (spec-v1.1 §5), inline in the footer,
    // reset when the popover closes.
    property bool resetAllArmed: false
    // The emoji chooser reveals its alternatives on demand; closed by a
    // choice, a second press, or the popover closing.
    property bool emojiChooserOpen: false

    signal customColourRequested(string fieldName, string labelText)

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus()
            resetRowDrafts()
            popoverRoot.resetAllArmed = false
        } else {
            popoverRoot.emojiChooserOpen = false
            popoverRoot.resetAllArmed = false
            panel.endHexEdit()
        }
    }

    // A fresh open never shows a stale hex draft (the focus exception and
    // the confirmation state die with the surface, as before).
    function resetRowDrafts() {
        keyBackgroundRow.resetDraft()
        panelBackgroundRow.resetDraft()
        textColorRow.resetDraft()
        accentColorRow.resetDraft()
        borderColorRow.resetDraft()
    }

    function colourRows() {
        return [keyBackgroundRow, panelBackgroundRow, textColorRow,
            accentColorRow, borderColorRow]
    }

    function adoptAppliedColour(fieldName, hex) {
        var rows = colourRows()
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].fieldName === fieldName) {
                rows[i].adoptHex(hex)
                return
            }
        }
    }

    // Current-content paste into the active hex draft (ticket 14): insert
    // locally into the focused row field; never ask the helper to type.
    function insertHexText(text) {
        var rows = [keyBackgroundRow, panelBackgroundRow, textColorRow,
            accentColorRow, borderColorRow]
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i]
            if (panel.hexEditing && panel.hexEditField === row.fieldName) {
                var field = row.padTarget()
                ConfigFile.fieldSelectAll(field)
                ConfigFile.fieldInsert(field, text)
                return
            }
        }
    }

    // Escape closes the popover — but read the constraint before trusting
    // it: the layer surface takes no keyboard focus for its whole life
    // EXCEPT while a hex field is active — the one §5 exception — so this
    // handler can normally never fire: the compositor delivers the surface
    // no keys, and outside click is the dismissal that works. While a hex
    // field holds the surface's OnDemand focus, keys DO arrive — and Escape
    // reaches the focused TextInput's own handler first (it reverts the
    // draft and hands the focus policy back); only when the field's focus
    // has moved does this popover-level handler see anything.
    Keys.onEscapePressed: popoverRoot.visible = false

    // The v3 column geometry: rows are left-packed — every label stands in
    // a column sized to the WIDEST label, measured against the live theme
    // font (hidden real Texts, not a FontMetrics snapshot: a FontMetrics
    // pass was seen measuring the default font before the theme's mono face
    // applied and never re-running), and every control begins at the same x.
    Column {
        id: labelProbe
        visible: false
        Repeater {
            model: popoverRoot.settingsRowLabels
            Text {
                text: modelData
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBody
            }
        }
    }
    readonly property var settingsRowLabels:
        ["Mode", "Size", "Emoji picking", "Emoji page size", "Super mark",
         "Key click sound", "Follow Omarchy theme",
         "Dwell typing", "Dwell delay",
         "Key radius", "Panel radius", "Key background",
         "Panel background", "Text colour", "Accent colour", "Border colour"]
    readonly property real labelColumnWidth: {
        var widest = 0
        for (var i = 0; i < labelProbe.children.length; i++) {
            var w = labelProbe.children[i].implicitWidth
            if (w > widest) widest = w
        }
        return Math.ceil(widest)
    }
    // Where every row's control begins: past the label column, one fixed
    // breath of space between words and values.
    readonly property real controlColumnX: labelColumnWidth + tokens.space(14)

    // The colour now in force for each appearance field: the one mapping
    // lives on the panel (the custom editor's "old" reads the same one);
    // the rows reach it through this guarded call, so whatever order the
    // engine evaluates the first bindings in, a row never gets undefined.
    function effectiveColorFor(fieldName) {
        var panel = popoverRoot.panel
        if (!panel || !panel.colorForField) return "transparent"
        return panel.colorForField(fieldName)
    }

    // The widest control block any row lays down, measured from the same
    // compact pieces the colour rows draw — the committed-colour indicator
    // square (ticket 23), swatches, hex, confirm chip and Custom. The emoji
    // chooser sits inside it.
    Row {
        id: controlProbe
        visible: false
        spacing: tokens.space(6)

        Rectangle { width: tokens.space(24); height: 1 }

        Repeater {
            model: 4
            Rectangle { width: tokens.space(18); height: 1 }
        }

        Rectangle { width: tokens.space(76); height: 1 }
        Rectangle { width: tokens.space(24); height: 1 }

        Rectangle {
            width: customProbeLabel.implicitWidth + tokens.space(10) * 2
            height: 1
            Text {
                id: customProbeLabel
                text: "Custom"
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }
        }

        Rectangle { width: tokens.space(24); height: 1 }
    }
    readonly property real controlZoneWidth: controlProbe.implicitWidth

    // Fixed compact width — fixed by CONTENT: the control column x plus the
    // widest control block any row lays down, plus the popover's own
    // margins. Scaled by the theme's spacing scale, the same ui scale the
    // fonts and paddings inside derive from, rather than tracked to the
    // keyboard's size preset, which scales keys, not text. The emoji
    // chooser's closed control fits inside the zone, so no PATH answer can
    // widen the popover. Clamped to the card so a long label or large
    // theme font cannot overflow the keyboard.
    readonly property real naturalWidth: tokens.space(10) * 2 + controlColumnX
        + Math.max(controlZoneWidth, tokens.space(150) + tokens.space(30))
    readonly property real maxPopoverWidth: hostWidth > 0
        ? Math.max(0, hostWidth - tokens.space(6) * 2) : naturalWidth
    width: maxPopoverWidth > 0 ? Math.min(naturalWidth, maxPopoverWidth)
        : naturalWidth
    readonly property real maxPopoverHeight: hostHeight > 0
        ? Math.max(0, hostHeight - tokens.space(6) * 2) : tokens.space(120)
    height: Math.min(Math.max(contentColumn.implicitHeight + tokens.space(10) * 2,
        tokens.space(120)), maxPopoverHeight)
    // The card's own panel-radius token — an override on panelRadius is
    // honoured here exactly as on the keyboard.
    radius: tokens.panelRadius
    // One step distinct from the card beneath.
    color: tokens.tintTowardForeground(tokens.panelBackground, tokens.hoverFillAlpha)
    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    border.width: tokens.normalBorderWidth
    clip: true
    z: 4

    // The popover's own background accepts clicks: rows, labels and row
    // gaps are INSIDE the popover, so a press on them is never an outside
    // click — the dismiss area under this surface only sees presses that
    // actually left the popover, consistently whether or not the rows
    // overflow into a scroll. Declared ahead of the Flickable (which claims
    // no taps while not interactive) so every unclaimed press inside lands
    // here and stops.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: false
    }

    // ---- shared row parts (ticket 09's, kept verbatim but scoped) ----

    component SettingsSwitch: Rectangle {
        id: switchTrack
        property bool checked: false
        signal toggled()
        width: tokens.space(40)
        height: tokens.space(22)
        radius: height / 2
        color: switchTrack.checked ? tokens.accent
            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
        border.width: tokens.normalBorderWidth

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: switchTrack.checked ? parent.width - width - 2 : 2
            width: parent.height - 4
            height: parent.height - 4
            radius: width / 2
            color: switchTrack.checked ? tokens.background : tokens.foreground
        }

        MouseArea {
            anchors.fill: parent
            enabled: panel.configHealthy
            onClicked: switchTrack.toggled()
        }
    }

    // Radius rows: a compact integer stepper. The ends refuse to step past
    // themselves. One click, one override, one atomic write. `step` is the
    // increment (radii step by one; the dwell delay steps by 100 ms).
    component SettingsStepper: Item {
        id: stepper
        property int value: 0
        property int minimum: 0
        property int maximum: 24
        property int step: 1
        signal stepped(int value)
        width: stepRow.width
        height: tokens.space(24)

        function bump(delta) {
            var next = stepper.value + delta * stepper.step
            if (next < stepper.minimum || next > stepper.maximum) return
            stepper.stepped(next)
        }

        Row {
            id: stepRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: tokens.space(6)

            Rectangle {
                width: tokens.space(24)
                height: tokens.space(24)
                radius: tokens.cornerRadius
                color: stepDownArea.pressed ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth
                opacity: stepper.value > stepper.minimum ? 1 : 0.4

                Text {
                    anchors.centerIn: parent
                    text: "\u2212"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                MouseArea {
                    id: stepDownArea
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Decrease value"
                    enabled: panel.configHealthy
                    onClicked: stepper.bump(-1)
                }
                HoverTooltip {
                    text: "Decrease"
                    hovered: stepDownArea.containsMouse
                }
            }

            Item {
                // Wide enough for the biggest value any row shows — the
                // dwell delay reaches four digits, and a clipped number
                // in a stepper is a wrong number.
                width: Math.max(tokens.space(28), valueText.implicitWidth)
                height: tokens.space(24)

                Text {
                    id: valueText
                    anchors.centerIn: parent
                    text: stepper.value
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    font.bold: true
                }
            }

            Rectangle {
                width: tokens.space(24)
                height: tokens.space(24)
                radius: tokens.cornerRadius
                color: stepUpArea.pressed ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth
                opacity: stepper.value < stepper.maximum ? 1 : 0.4

                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                MouseArea {
                    id: stepUpArea
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Increase value"
                    enabled: panel.configHealthy
                    onClicked: stepper.bump(1)
                }
                HoverTooltip {
                    text: "Increase"
                    hovered: stepUpArea.containsMouse
                }
            }
        }
    }

    // Section hairline: the one separator inside the settings card.
    component SettingsHairline: Rectangle {
        width: parent ? parent.width : 0
        height: 1
        color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    }

    // Segmented chip group — picking one of a few values (mode, size). One
    // bordered container; the active segment is accent-OUTLINED with accent
    // text, never solid-filled: a settings surface reports what is in
    // force, not what is pressed. Fixed-width groups slice the container
    // equally, so choosing never reflows the row.
    component SettingsSegmented: Item {
        id: segmented
        property var segments: [] // [{ value, label }]
        property string current: ""
        signal picked(string value)
        width: tokens.space(150)
        height: tokens.space(26)

        Rectangle {
            anchors.fill: parent
            radius: tokens.cornerRadius
            color: Util.alpha(tokens.foreground, tokens.normalFillAlpha)
            border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
            border.width: tokens.normalBorderWidth
        }

        Row {
            id: contentRow
            anchors.fill: parent
            anchors.margins: 2
            spacing: 2

            Repeater {
                model: segmented.segments

                Rectangle {
                    property string segmentValue: modelData.value
                    property string segmentText: modelData.label
                    property bool active: segmentValue === segmented.current
                    width: (segmented.width - 4 - 2 * (segmented.segments.length - 1))
                        / segmented.segments.length
                    height: parent.height
                    radius: Math.max(0, (tokens.cornerRadius || 0) - 2)
                    color: segmentedArea.containsMouse && !active
                        ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha) : "transparent"
                    border.color: active ? tokens.accent : "transparent"
                    border.width: active ? tokens.normalBorderWidth : 0

                    Text {
                        anchors.centerIn: parent
                        text: parent.segmentText
                        color: parent.active ? tokens.accent : tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBody
                        font.bold: parent.active
                    }

                    MouseArea {
                        id: segmentedArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: panel.configHealthy
                        onClicked: segmented.picked(parent.segmentValue)
                    }
                }
            }
        }
    }

    // ---- content ----

    Flickable {
        id: contentFlickable
        anchors.fill: parent
        anchors.margins: tokens.space(10)
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar {
            policy: contentFlickable.contentHeight > contentFlickable.height
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
            id: contentColumn
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: tokens.space(7)

            Text {
                width: parent.width
                text: "Settings"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            SettingsHairline {}

            // MODE. The chips name the STATE, unlike the bar's button which
            // names the action.
            Text {
                width: parent.width
                text: "MODE"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Mode"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsSegmented {
                    id: modeControl
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    segments: [
                        { value: ConfigFile.MODE_DOCKED, label: "Docked" },
                        { value: ConfigFile.MODE_FLOATING, label: "Floating" }
                    ]
                    current: panel.mode
                    onPicked: function (value) { panel.setMode(value) }
                }

                SettingsResetChip {
                    anchors {
                        left: modeControl.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "mode"
                }
            }

            SettingsHairline {}

            // SIZE: the direct chooser. Choosing the active preset is a
            // no-op; a different one re-derives the floating anchor exactly
            // once, through chooseSizePreset.
            Text {
                width: parent.width
                text: "SIZE"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Size"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsSegmented {
                    id: sizeControl
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    segments: panel.sizePresetOrder.map(function (preset) {
                        return { value: preset, label: panel.sizePresetLabels[preset] }
                    })
                    current: panel.sizePreset
                    onPicked: function (value) { panel.chooseSizePreset(value) }
                }

                SettingsResetChip {
                    anchors {
                        left: sizeControl.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "sizePreset"
                }
            }

            SettingsHairline {}

            Text {
                width: parent.width
                text: "EMOJI PAGE"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Emoji picking"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }
                SettingsSegmented {
                    id: emojiPickingControl
                    x: popoverRoot.controlColumnX
                    anchors.verticalCenter: parent.verticalCenter
                    segments: [
                        { value: false, label: "Keep open" },
                        { value: true, label: "Close" }
                    ]
                    current: panel.emojiCloseAfterPick
                    onPicked: function (value) {
                        panel.setOverride("emojiCloseAfterPick", value)
                    }
                }
                SettingsResetChip {
                    anchors.left: emojiPickingControl.right
                    anchors.leftMargin: tokens.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "emojiCloseAfterPick"
                }
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Emoji page size"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }
                SettingsSegmented {
                    id: emojiPageSizeControl
                    x: popoverRoot.controlColumnX
                    anchors.verticalCenter: parent.verticalCenter
                    segments: [
                        { value: "medium", label: "M" },
                        { value: "large", label: "L" },
                        { value: "x-large", label: "XL" }
                    ]
                    current: panel.emojiPageSize
                    onPicked: function (value) {
                        panel.setOverride("emojiPageSize", value)
                    }
                }
                SettingsResetChip {
                    anchors.left: emojiPageSizeControl.right
                    anchors.leftMargin: tokens.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "emojiPageSize"
                }
            }

            SettingsHairline {}

            // SUPER MARK (ticket 22): what the Super cap draws — the word by
            // default, a mark by choice. Five segments on the same
            // SettingsSegmented the Mode and Size rows use; the instance is
            // wider because five labels cannot fit the two-row width
            // ("Omarchy", "Windows" and "Penguin" each measure ~50px against
            // the default's ~28px segment), and the card's measured control
            // zone (~328 space units) holds the wider control plus its reset
            // chip with room to spare. Choosing the standing mark is a no-op
            // — no movement, no config write — like choosing the active
            // preset.
            Text {
                width: parent.width
                text: "SUPER MARK"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Super mark"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsSegmented {
                    id: superMarkControl
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    width: tokens.space(290)
                    readonly property var superMarkLabels:
                        ({ word: "Word", omarchy: "Omarchy", windows: "Windows",
                           macos: "macOS", penguin: "Penguin" })
                    segments: ConfigFile.SUPER_MARKS.map(function (mark) {
                        return { value: mark, label: superMarkControl.superMarkLabels[mark] }
                    })
                    current: panel.superMark
                    onPicked: function (value) { panel.setSuperMark(value) }
                }

                SettingsResetChip {
                    anchors {
                        left: superMarkControl.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "superMark"
                }
            }

            SettingsHairline {}

            // SOUND: the compact pill switch, whose on state is the accent —
            // the same immediate setOverride path every other control uses.
            Text {
                width: parent.width
                text: "SOUND"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                // The unavailable note takes a line of its own: the row
                // grows only while it shows, so the word is never clipped
                // against the switch.
                height: panel.sound && panel.soundUnavailable
                    ? tokens.space(44) : tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    id: soundRowLabel
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                        verticalCenterOffset:
                            panel.sound && panel.soundUnavailable
                                ? -tokens.space(7) : 0
                    }
                    text: "Key click sound"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                Text {
                    anchors {
                        left: parent.left
                        top: soundRowLabel.bottom
                        topMargin: 1
                    }
                    visible: panel.sound && panel.soundUnavailable
                    text: "unavailable"
                    color: tokens.urgent
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                SettingsSwitch {
                    id: soundSwitch
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    checked: panel.sound
                    onToggled: panel.setOverride("sound", !panel.sound)
                }

                SettingsResetChip {
                    anchors {
                        left: soundSwitch.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "sound"
                }
            }

            SettingsHairline {}

            Text {
                width: parent.width
                text: "THEME"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Follow Omarchy theme"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsSwitch {
                    id: followSwitch
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    checked: panel.followTheme
                    onToggled: panel.setOverride("followTheme", !panel.followTheme)
                }

                SettingsResetChip {
                    anchors {
                        left: followSwitch.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "followTheme"
                }
            }

            SettingsHairline {}

            // ---- DWELL (ticket 50) ----
            //
            // The accessibility pair: rest-to-type, off until it is
            // turned on, and how long a rest must hold before the cap
            // types. The bounds are Dwell.js's own window — the module
            // clamps the timer into exactly this range, and the file
            // validates to it, so the stepper cannot offer a value the
            // keyboard would refuse.
            Text {
                width: parent.width
                text: "DWELL"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Dwell typing"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsSwitch {
                    id: dwellSwitch
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    checked: panel.dwellEnabled
                    onToggled: panel.setOverride("dwellEnabled",
                        !panel.dwellEnabled)
                }

                SettingsResetChip {
                    anchors {
                        left: dwellSwitch.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "dwellEnabled"
                }
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Dwell delay"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsStepper {
                    id: dwellDelayStepper
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    value: panel.dwellDelayMs
                    minimum: Dwell.DELAY_MIN_MS
                    maximum: Dwell.DELAY_MAX_MS
                    step: 100
                    onStepped: function (value) {
                        panel.setOverride("dwellDelayMs", value)
                    }
                }

                SettingsResetChip {
                    anchors {
                        left: dwellDelayStepper.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "dwellDelayMs"
                }
            }

            Text {
                width: parent.width
                text: "Rest a key this long to type it; resting past the type opens its hold-column menu"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            SettingsHairline {}

            // ---- APPEARANCE (spec-v1.1 §5, 2026-09-06 amendment) ----
            //
            // Two radii, five colours. Every control applies through
            // setOverride — immediate, atomic, sparse — except the hex
            // fields' drafts, which wait for their Apply. The caption is
            // the one thing the values cannot show by themselves: with
            // following on, every unoverridden field tracks the theme live
            // and an override pins exactly its own field.
            Text {
                width: parent.width
                text: "APPEARANCE"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
            }

            Text {
                width: parent.width
                text: panel.followTheme
                    ? "Following the Omarchy theme — an override pins its own field"
                    : "Theme following is off — appearance holds the look it had"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Key radius"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsStepper {
                    id: keyRadiusStepper
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    value: tokens.capCorner
                    minimum: 0
                    maximum: 24
                    onStepped: function (value) {
                        panel.setOverride("capCorner", value)
                    }
                }

                SettingsResetChip {
                    anchors {
                        left: keyRadiusStepper.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "capCorner"
                }
            }

            Text {
                width: parent.width
                text: "0–24 relative to M; 24 stays a circle at L and XL"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Panel radius"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                SettingsStepper {
                    id: panelRadiusStepper
                    x: popoverRoot.controlColumnX
                    anchors {
                        verticalCenter: parent.verticalCenter
                    }
                    value: tokens.panelRadius
                    minimum: 0
                    maximum: 32
                    onStepped: function (value) {
                        panel.setOverride("panelRadius", value)
                    }
                }

                SettingsResetChip {
                    anchors {
                        left: panelRadiusStepper.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "panelRadius"
                }
            }

            // The five colour rows: swatches grouped with hex, compact
            // confirm, Custom, reset — each feeding the same panel API.
            SettingsColorRow {
                id: keyBackgroundRow
                tokens: popoverRoot.tokens
                panel: popoverRoot.panel
                controlX: popoverRoot.controlColumnX
                fieldName: "keyBackground"
                labelText: "Key background"
                effectiveColor: panel.effectiveKeyBackground
                onCustomRequested: popoverRoot.customColourRequested(
                    keyBackgroundRow.fieldName, keyBackgroundRow.labelText)
            }

            SettingsColorRow {
                id: panelBackgroundRow
                tokens: popoverRoot.tokens
                panel: popoverRoot.panel
                controlX: popoverRoot.controlColumnX
                fieldName: "panelBackground"
                labelText: "Panel background"
                effectiveColor: panel.effectivePanelBackground
                onCustomRequested: popoverRoot.customColourRequested(
                    panelBackgroundRow.fieldName, panelBackgroundRow.labelText)
            }

            SettingsColorRow {
                id: textColorRow
                tokens: popoverRoot.tokens
                panel: popoverRoot.panel
                controlX: popoverRoot.controlColumnX
                fieldName: "textColor"
                labelText: "Text colour"
                effectiveColor: panel.effectiveTextColor
                onCustomRequested: popoverRoot.customColourRequested(
                    textColorRow.fieldName, textColorRow.labelText)
            }

            SettingsColorRow {
                id: accentColorRow
                tokens: popoverRoot.tokens
                panel: popoverRoot.panel
                controlX: popoverRoot.controlColumnX
                fieldName: "accentColor"
                labelText: "Accent colour"
                effectiveColor: panel.effectiveAccentColor
                onCustomRequested: popoverRoot.customColourRequested(
                    accentColorRow.fieldName, accentColorRow.labelText)
            }

            SettingsColorRow {
                id: borderColorRow
                tokens: popoverRoot.tokens
                panel: popoverRoot.panel
                controlX: popoverRoot.controlColumnX
                fieldName: "borderColor"
                labelText: "Border colour"
                effectiveColor: panel.effectiveBorderColor
                onCustomRequested: popoverRoot.customColourRequested(
                    borderColorRow.fieldName, borderColorRow.labelText)
            }

            Text {
                width: parent.width
                text: "Hex fields accept #RGB / #RRGGBB (an alpha form too); the check commits the draft. Type with the keyboard."
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            // The malformed-file notice (spec-v1.1 §5). While it stands,
            // the rows above dim and their controls refuse writes: the
            // values shown are the last valid runtime state, the bad file
            // is preserved exactly as the external editor wrote it, and
            // fixing the file lets the watched reload clear this line.
            Text {
                width: parent.width
                visible: panel.configurationError !== ""
                    || panel.stateError !== ""
                text: (panel.configurationError
                    ? "config.json: " + panel.configurationError
                      + " \u2014 showing the last valid settings; fix the file to change them"
                    : "")
                    + (panel.configurationError && panel.stateError ? "\n" : "")
                    + (panel.stateError
                    ? "state.json: " + panel.stateError
                      + " \u2014 showing the last valid state; fix the file to change it"
                    : "")
                color: tokens.urgent
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            SettingsHairline { visible: resetAllRow.visible }

            // Reset-all (spec-v1.1 §5), the card's footer row: a bordered
            // ghost button — the quietest voice on the card, because it is
            // the one destructive action — with its confirmation inline:
            // first click arms the row, and only the urgent Reset commits.
            // Hidden entirely while the sparse file carries no overrides.
            Item {
                id: resetAllRow
                width: parent.width
                height: tokens.space(28)
                visible: Object.keys(panel.userOverrides).length > 0

                Rectangle {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    visible: !popoverRoot.resetAllArmed
                    width: resetAllLabel.implicitWidth + tokens.space(10) * 2
                    height: tokens.space(24)
                    radius: tokens.cornerRadius
                    color: resetAllArea.pressed
                        ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha) : "transparent"
                    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth

                    Text {
                        id: resetAllLabel
                        anchors.centerIn: parent
                        text: "Reset all"
                        color: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: resetAllArea
                        anchors.fill: parent
                        enabled: panel.configHealthy
                        onClicked: popoverRoot.resetAllArmed = true
                    }
                }

                Row {
                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: tokens.space(6)
                    visible: popoverRoot.resetAllArmed

                    // No anchors on the Row's children — a positioner owns
                    // their positions — so every child is a uniform 24-high
                    // slot like the ghost button, with the text centred
                    // inside its own.
                    Item {
                        width: confirmPrompt.implicitWidth
                        height: tokens.space(24)

                        Text {
                            id: confirmPrompt
                            anchors.centerIn: parent
                            text: "Reset every override?"
                            color: tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                        }
                    }

                    Rectangle {
                        width: confirmResetLabel.implicitWidth + tokens.space(8) * 2
                        height: tokens.space(24)
                        radius: tokens.cornerRadius
                        // The popover's one destructive action reads as the
                        // urgent colour, the close button's own.
                        color: tokens.urgent

                        Text {
                            id: confirmResetLabel
                            anchors.centerIn: parent
                            text: "Reset"
                            color: tokens.background
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: true
                        }

                        MouseArea {
                            id: confirmResetArea
                            anchors.fill: parent
                            onClicked: {
                                popoverRoot.resetAllArmed = false
                                panel.clearAllOverrides()
                            }
                        }
                    }

                    Rectangle {
                        width: cancelResetLabel.implicitWidth + tokens.space(8) * 2
                        height: tokens.space(24)
                        radius: tokens.cornerRadius
                        color: cancelResetArea.pressed
                            ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha) : "transparent"
                        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: tokens.normalBorderWidth

                        Text {
                            id: cancelResetLabel
                            anchors.centerIn: parent
                            text: "Keep"
                            color: tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                        }

                        MouseArea {
                            id: cancelResetArea
                            anchors.fill: parent
                            onClicked: popoverRoot.resetAllArmed = false
                        }
                    }
                }
            }
        }
    }
}
