import QtQuick
import qs.Commons
import "Config.js" as ConfigFile

// The settings popover (spec-v1.1 §5), extracted from Panel.qml by ticket
// 07's prefactor. Ticket 09 shipped the behaviour; the 2026-09-05 owner
// round left-packed the rows; the 2026-09-06 amendment narrowed it: the
// width comes from the label column plus the compact colour controls (the
// old embedded pickers are gone), the emoji app is one chooser with its
// alternatives revealed on demand, and the colour rows carry theme swatches,
// a hex draft with Apply, Custom colour and reset. The reset chips, the
// immediate-apply writes and reset-all's inline confirmation keep the
// semantics they had; the panel stays the one persistence authority — this
// surface only reads effective values and issues changes.
//
// It overlays the grid from the bar down and never touches the card's size,
// so no settings interaction can churn the docked reservation. Scrolling
// changes height only: every row keeps to the shared control column, the
// emoji alternatives wrap inside it, and the width binding reads nothing
// that scrolling moves.
Rectangle {
    id: popoverRoot

    // Hidden until the gear opens it — the dismissal mask in Panel.qml keys
    // off this, so a popover that started visible would eat every gear
    // click from creation onward.
    visible: false

    // The panel (root) and its live Theme facade. The panel is the one
    // home of config state and writes; this file is presentation.
    property var panel
    property var tokens

    // Geometry the panel feeds in: the gear the popover hangs from, the
    // drag bar above, and the card that bounds it.
    property real gearX: 0
    property real barHeight: 0
    property real cardWidth: 0
    property real cardHeight: 0

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
        } else {
            popoverRoot.emojiChooserOpen = false
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
        ["Mode", "Size", "Key click sound", "Follow Omarchy theme", "Emoji app",
         "Key radius", "Panel radius", "Key background", "Panel background",
         "Text colour", "Accent colour", "Border colour"]
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
        if (!panel || !panel.effectiveColorForField) return "transparent"
        var value = panel.effectiveColorForField[fieldName]
        return value === undefined || value === null ? "transparent" : value
    }

    // The widest control block any row lays down, measured from the same
    // compact pieces the colour rows draw — the hex field, the Apply button
    // and the Custom colour button at their real fonts. This, not the old
    // 238-unit picker zone, is what the popover is wide for; the emoji
    // chooser sits inside it.
    Row {
        id: controlProbe
        visible: false
        spacing: tokens.space(6)

        Rectangle {
            width: tokens.space(76)
            height: 1
        }

        Rectangle {
            width: applyProbeLabel.implicitWidth + tokens.space(10) * 2
            height: 1
            Text {
                id: applyProbeLabel
                text: "Apply"
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                font.bold: true
            }
        }

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
    }
    readonly property real controlZoneWidth: controlProbe.implicitWidth

    // Fixed compact width — fixed by CONTENT: the control column x plus the
    // widest control block any row lays down, plus the popover's own
    // margins. Scaled by the theme's spacing scale, the same ui scale the
    // fonts and paddings inside derive from, rather than tracked to the
    // keyboard's size preset, which scales keys, not text. The emoji
    // chooser's closed control fits inside the zone, so no PATH answer can
    // widen the popover.
    width: tokens.space(10) * 2 + controlColumnX
        + Math.max(controlZoneWidth, tokens.space(150) + tokens.space(30))
    x: Math.max(tokens.space(6), Math.min(gearX, cardWidth - width - tokens.space(6)))
    y: barHeight + tokens.space(6)
    // Compact: never taller than the space under the bar, and only as tall
    // as the sections it hosts. The Flickable below is the "scrolls only if
    // content requires it" half of the contract — with the standard fields
    // first, only the appearance section ever scrolls.
    readonly property real maxPopoverHeight: Math.max(cardHeight - y - tokens.space(6), 0)
    height: Math.min(Math.max(Math.min(contentColumn.implicitHeight + tokens.space(10) * 2,
        maxPopoverHeight), tokens.space(120)), maxPopoverHeight)
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
    // themselves. One click, one override, one atomic write.
    component SettingsStepper: Item {
        id: stepper
        property int value: 0
        property int minimum: 0
        property int maximum: 24
        signal stepped(int value)
        width: stepRow.width
        height: tokens.space(24)

        function bump(delta) {
            var next = stepper.value + delta
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
                    enabled: panel.configHealthy
                    onClicked: stepper.bump(-1)
                }
            }

            Item {
                width: tokens.space(28)
                height: tokens.space(24)

                Text {
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
                    enabled: panel.configHealthy
                    onClicked: stepper.bump(1)
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

            // EMOJI (spec-v1.1 §1): which app the ☺ cap execs. The chooser
            // names the selected app; the alternatives — the pickers the
            // PATH probe found — reveal on demand beneath the row, wrapping
            // inside the control zone so no candidate list widens the
            // popover. An override naming an app the probe did not find is
            // still honoured at click time; its failure answers as the
            // transient hint.
            Text {
                width: parent.width
                text: "EMOJI"
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
                    text: "Emoji app"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                }

                Rectangle {
                    id: emojiChooser
                    x: popoverRoot.controlColumnX
                    width: tokens.space(150)
                    height: tokens.space(26)
                    radius: tokens.cornerRadius
                    color: emojiChooserArea.pressed ? tokens.accent
                        : popoverRoot.emojiChooserOpen ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(
                        popoverRoot.emojiChooserOpen || emojiChooserArea.containsMouse
                            ? tokens.accent : tokens.foreground,
                        tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: tokens.space(8)
                            right: emojiChevron.left
                            rightMargin: tokens.space(4)
                            verticalCenter: parent.verticalCenter
                        }
                        text: panel.emojiApp.indexOf("omarchy-") === 0
                            ? panel.emojiApp.slice("omarchy-".length) : panel.emojiApp
                        color: emojiChooserArea.pressed ? tokens.background : tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        elide: Text.ElideRight
                    }

                    Text {
                        id: emojiChevron
                        anchors {
                            right: parent.right
                            rightMargin: tokens.space(6)
                            verticalCenter: parent.verticalCenter
                        }
                        text: popoverRoot.emojiChooserOpen ? "\u25b4" : "\u25be"
                        color: emojiChooserArea.pressed ? tokens.background : tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: emojiChooserArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: panel.configHealthy && panel.detectedEmojiPickers.length > 0
                        Accessible.role: Accessible.Button
                        Accessible.name: "Emoji app: " + panel.emojiApp
                        onClicked: popoverRoot.emojiChooserOpen = !popoverRoot.emojiChooserOpen
                    }
                }

                Text {
                    anchors {
                        left: emojiChooser.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    visible: panel.detectedEmojiPickers.length === 0
                    text: "no picker found on PATH"
                    color: tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                SettingsResetChip {
                    anchors {
                        left: emojiChooser.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    visible: panel.detectedEmojiPickers.length > 0
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "emojiApp"
                }
            }

            // The alternatives, revealed on demand. The Flow is pinned to
            // the control zone's width, so even the longest candidate list
            // wraps instead of widening the popover.
            Flow {
                width: parent.width - popoverRoot.controlColumnX
                x: popoverRoot.controlColumnX
                spacing: tokens.space(6)
                visible: popoverRoot.emojiChooserOpen
                    && panel.detectedEmojiPickers.length > 0

                Repeater {
                    model: panel.detectedEmojiPickers

                    Rectangle {
                        property string app: modelData
                        readonly property bool active: app === panel.emojiApp
                        width: chooserLabel.implicitWidth + tokens.space(10) * 2
                        height: tokens.space(24)
                        radius: tokens.cornerRadius
                        color: chooserArea.pressed ? tokens.accent
                            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        border.color: active ? tokens.accent
                            : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: active ? tokens.focusBorderWidth
                            : tokens.normalBorderWidth

                        Text {
                            id: chooserLabel
                            anchors.centerIn: parent
                            text: parent.app.indexOf("omarchy-") === 0
                                ? parent.app.slice("omarchy-".length) : parent.app
                            color: chooserArea.pressed ? tokens.background : tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: parent.active
                        }

                        MouseArea {
                            id: chooserArea
                            anchors.fill: parent
                            enabled: panel.configHealthy
                            onClicked: {
                                if (parent.app !== panel.emojiApp)
                                    panel.setOverride("emojiApp", parent.app)
                                popoverRoot.emojiChooserOpen = false
                            }
                        }
                    }
                }
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
                    value: tokens.keyRadius
                    minimum: 0
                    maximum: 24
                    onStepped: function (value) {
                        panel.setOverride("keyRadius", value)
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
                    overrideName: "keyRadius"
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

            // The five colour rows: swatches, hex draft with Apply, Custom
            // colour, reset — each feeding the same panel API the rest of
            // the popover speaks.
            SettingsColorRow {
                id: keyBackgroundRow
                tokens: popoverRoot.tokens
                panel: popoverRoot.panel
                controlX: popoverRoot.controlColumnX
                fieldName: "keyBackground"
                labelText: "Key background"
                effectiveColor: popoverRoot.effectiveColorFor("keyBackground")
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
                effectiveColor: popoverRoot.effectiveColorFor("panelBackground")
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
                effectiveColor: popoverRoot.effectiveColorFor("textColor")
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
                effectiveColor: popoverRoot.effectiveColorFor("accentColor")
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
                effectiveColor: popoverRoot.effectiveColorFor("borderColor")
                onCustomRequested: popoverRoot.customColourRequested(
                    borderColorRow.fieldName, borderColorRow.labelText)
            }

            // The hex grammar in one muted line, and the local pad: while a
            // hex field is the active entry, the OSK's own controls sit here
            // — #, digits, A–F, caret and delete — routed into the field
            // locally, never through the helper, never to the previously
            // focused app.
            Text {
                width: parent.width
                text: "Hex fields accept #RGB / #RRGGBB (an alpha form too); Apply commits the draft"
                color: tokens.muted
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            SettingsHexPad {
                anchors.left: parent.left
                anchors.leftMargin: popoverRoot.controlColumnX
                width: popoverRoot.controlZoneWidth
                visible: panel.hexEditing && panel.customEditorField === ""
                tokens: popoverRoot.tokens
                // The field is whichever row's hex TextInput currently holds
                // active focus; the pad edits it in place.
                field: {
                    var rows = [keyBackgroundRow, panelBackgroundRow, textColorRow,
                        accentColorRow, borderColorRow]
                    for (var i = 0; i < rows.length; i++) {
                        var row = rows[i]
                        if (panel.hexEditing && panel.hexEditField === row.fieldName)
                            return row.padTarget()
                    }
                    return null
                }
                onVisibleChanged: {
                    // Keep the pad itself in view when the entry opens: the
                    // popover scrolls, it never widens.
                    if (visible)
                        contentFlickable.contentY = Math.max(0,
                            contentFlickable.contentHeight - contentFlickable.height)
                }
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
