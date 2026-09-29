import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Config.js" as ConfigFile
import "Dwell.js" as Dwell
import "UiStrings.js" as UiStrings

// The settings popover. Lives on its own overlay window,
// not on the key grid: leftover-centre placement is the panel's, exclusive
// zone stays the keyboard band. Four sections — General, Emoji page, Dwell,
// Appearance — each under one separator and one header, drawn with the
// shell's own panel parts. The panel is the one persistence authority —
// this surface only reads effective values and issues changes. Scrolling
// changes height only.
Rectangle {
    id: popoverRoot

    // Hidden until the gear opens it. Leftover dismiss and this window
    // both key off this flag.
    visible: false

    // The panel (root), the chrome this card draws with (the live Omarchy
    // theme, whatever the keyboard's look), and the keyboard's own Theme
    // facade, read only for the values the rows show (radii, border on/off).
    // The panel is the one home of config state and writes; this file is
    // presentation.
    property var panel
    property var tokens
    property var keyTokens

    // Overlay size the popover may occupy. Placement (leftover centre) is
    // applied by the panel as x/y; this only clamps to the output.
    property real hostWidth: 0
    property real hostHeight: 0

    // Reset-all's confirmation state, inline in the footer, reset when
    // the popover closes.
    property bool resetAllArmed: false

    signal customColourRequested(string fieldName, string labelText)

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus()
            resetRowDrafts()
            popoverRoot.resetAllArmed = false
        } else {
            popoverRoot.resetAllArmed = false
            panel.endHexEdit()
        }
    }

    // A fresh open never shows a stale hex draft — the focus exception
    // and the confirmation state die with the surface.
    function resetRowDrafts() {
        var rows = colourRows()
        for (var i = 0; i < rows.length; i++) rows[i].resetDraft()
    }

    function colourRows() {
        return [keyBackgroundRow, panelBackgroundRow, textColorRow,
            accentColorRow, borderColorRow]
    }

    // Every row not being typed into takes the colour now in force. Called
    // on a follow flip and on any override change (reset-all, an external
    // edit), after the change settles. The rows write their hex fields
    // imperatively, so this does not rely on their effective-colour binding
    // notifying (SettingsColorRow.showCommitted).
    function syncColourRows() {
        Qt.callLater(popoverRoot.syncColourRowsNow)
    }
    function syncColourRowsNow() {
        var rows = colourRows()
        for (var i = 0; i < rows.length; i++) {
            // A draft the user typed and has not applied is theirs.
            if (rows[i].editingThis || rows[i].draftDirty) continue
            rows[i].showCommitted()
        }
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

    // Current-content paste into the active hex draft: insert locally
    // into the focused row field; never ask the helper to type.
    function insertHexText(text) {
        var rows = colourRows()
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
    // EXCEPT while a hex field is active — the one exception — so this
    // handler can normally never fire: the compositor delivers the surface
    // no keys, and outside click is the dismissal that works. While a hex
    // field holds the surface's OnDemand focus, keys DO arrive — and Escape
    // reaches the focused TextInput's own handler first (it reverts the
    // draft and hands the focus policy back); only when the field's focus
    // has moved does this popover-level handler see anything.
    Keys.onEscapePressed: popoverRoot.visible = false

    // Column geometry: rows are left-packed — every label stands in a
    // column sized to the WIDEST label, measured against the live theme
    // font (hidden real Texts, not a FontMetrics snapshot — that can
    // measure the default font before the theme's mono face applies and
    // never re-run), and every control begins at the same x.
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
    // The row labels in the UI's language, one per row that exists: this
    // array feeds the width probe, so the column sizes itself to the WIDEST
    // TRANSLATION while the language stands — a Cyrillic label must not
    // clip against a column measured in English.
    readonly property var settingsRowLabels:
        [UiStrings.tr("settings.row.mode", panel.uiLang),
         UiStrings.tr("settings.row.size", panel.uiLang),
         UiStrings.tr("settings.row.language", panel.uiLang),
         UiStrings.tr("settings.row.inputProfile", panel.uiLang),
         UiStrings.tr("settings.row.superMark", panel.uiLang),
         UiStrings.tr("settings.row.sound", panel.uiLang),
         UiStrings.tr("settings.row.emojiPicking", panel.uiLang),
         UiStrings.tr("settings.row.emojiPageSize", panel.uiLang),
         UiStrings.tr("settings.row.emojiDrag", panel.uiLang),
         UiStrings.tr("settings.row.dwellTyping", panel.uiLang),
         UiStrings.tr("settings.row.dwellDelay", panel.uiLang),
         UiStrings.tr("settings.row.look", panel.uiLang),
         UiStrings.tr("settings.row.keyRadius", panel.uiLang),
         UiStrings.tr("settings.row.panelRadius", panel.uiLang),
         UiStrings.tr("settings.row.keyBackground", panel.uiLang),
         UiStrings.tr("settings.row.panelBackground", panel.uiLang),
         UiStrings.tr("settings.row.textColor", panel.uiLang),
         UiStrings.tr("settings.row.accentColor", panel.uiLang),
         UiStrings.tr("settings.row.panelBorder", panel.uiLang)]
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

    // The widest non-choice control line: the border row — its switch, the
    // switch's reset, then the colour group (square, hex, check slot,
    // reset). The other colour rows are that line without the switch.
    Row {
        id: controlProbe
        visible: false
        spacing: tokens.space(6)

        Rectangle { width: probeSwitch.trackWidth; height: 1 }
        ToggleSwitch { id: probeSwitch; visible: false }
        Rectangle { width: tokens.space(24); height: 1 }
        Rectangle { width: tokens.space(24); height: 1 }
        Rectangle { width: tokens.space(76); height: 1 }
        Rectangle { width: tokens.space(24); height: 1 }
        Rectangle { width: tokens.space(24); height: 1 }
    }
    // The widest choice row plus its reset chip must fit the zone too, or
    // the chip is cut off at the popover's edge. The shell's chips size to
    // their labels (in the theme's mono face a bold selected label is the
    // same width as a plain one, so choosing never reflows the row).
    readonly property real widestChoice: Math.max(modeControl.implicitWidth,
        sizeControl.implicitWidth, languageControl.implicitWidth,
        inputProfileControl.implicitWidth, superMarkControl.implicitWidth,
        emojiPickingControl.implicitWidth, emojiPageSizeControl.implicitWidth,
        emojiDragControl.implicitWidth, lookControl.implicitWidth)
    readonly property real controlZoneWidth: Math.max(controlProbe.implicitWidth,
        widestChoice + tokens.space(6) + tokens.space(24))

    // Fixed compact width — fixed by CONTENT: the control column x plus the
    // widest control block any row lays down, plus the popover's own
    // margins. Scaled by the theme's spacing scale, the same ui scale the
    // fonts and paddings inside derive from, rather than tracked to the
    // keyboard's size preset, which scales keys, not text. Clamped to the
    // card so a long label or large theme font cannot overflow the keyboard.
    readonly property real naturalWidth: tokens.space(10) * 2 + controlColumnX
        + Math.max(controlZoneWidth, tokens.space(180))
    readonly property real maxPopoverWidth: hostWidth > 0
        ? Math.max(0, hostWidth - tokens.space(6) * 2) : naturalWidth
    width: maxPopoverWidth > 0 ? Math.min(naturalWidth, maxPopoverWidth)
        : naturalWidth
    readonly property real maxPopoverHeight: hostHeight > 0
        ? Math.max(0, hostHeight - tokens.space(6) * 2) : tokens.space(120)
    height: Math.min(Math.max(contentColumn.implicitHeight + tokens.space(10) * 2,
        tokens.space(120)), maxPopoverHeight)
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

    // ---- shared row parts ----

    // A section's head: the shell's separator and section header, the pair
    // every Omarchy panel opens a section with.
    component SettingsSection: Column {
        property string title: ""
        width: parent ? parent.width : 0
        spacing: tokens.space(6)
        topPadding: tokens.space(3)

        PanelSeparator {
            foreground: tokens.foreground
        }
        PanelSectionHeader {
            text: parent.title
            foreground: tokens.foreground
            fontFamily: tokens.fontFamily
        }
    }

    component SettingsRowLabel: Text {
        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
        }
        color: tokens.foreground
        font.family: tokens.fontFamily
        font.pixelSize: tokens.fontBody
    }

    // The shell's switch, track aligned with every other row's control
    // column (its hover ring pads outside the track, so the switch sits
    // one pad left of the column). Refuses clicks while a malformed file
    // stands.
    component SettingsSwitch: ToggleSwitch {
        x: popoverRoot.controlColumnX - cursorPad
        foreground: tokens.foreground
        accent: tokens.accent
        interactive: panel.configHealthy
        // The ring's pad is part of the geometry above; it stays while the
        // switch refuses clicks.
        cursorRing: true
    }

    // The shell's pick-one chips. Never a Tab stop: this surface takes no
    // keyboard focus. The group emits on every click; the rows write only
    // a change. Rows handle `picked`, relayed from the group's `changed`:
    // qmllint cannot match an `onChanged` handler to a declared signal,
    // and the static check gates on exactly that message.
    component SettingsChoice: ButtonGroup {
        id: choice
        signal picked(string value)
        Component.onCompleted: choice.changed.connect(choice.picked)
        x: popoverRoot.controlColumnX
        focusable: false
        spacing: tokens.space(4)
        foreground: tokens.foreground
        accent: tokens.accent
        fontFamily: tokens.fontFamily
        fontSize: tokens.fontBody
        enabled: panel.configHealthy
    }

    // One step button of the stepper: the shell's bordered button, dimmed
    // at the end it cannot pass.
    component StepButton: Button {
        id: stepButton
        property bool canStep: true
        property string accessName: ""
        property string tipText: ""
        width: tokens.space(24)
        height: tokens.space(24)
        horizontalPadding: 0
        verticalPadding: 0
        bordered: true
        foreground: tokens.foreground
        accent: tokens.accent
        fontFamily: tokens.fontFamily
        fontSize: tokens.fontBodySmall
        opacity: canStep ? 1 : 0.4
        Accessible.role: Accessible.Button
        Accessible.name: accessName
        HoverTooltip {
            text: stepButton.tipText
            hovered: popoverRoot.panel.inputAfford.tooltipHoverShows
                ? stepButton.hot : false
        }
    }

    // Radius and delay rows: a compact integer stepper. The ends refuse to
    // step past themselves. One click, one override, one atomic write.
    // `step` is the increment (radii step by one; the dwell delay steps by
    // 100 ms). `writable` false keeps the value shown and takes no clicks.
    component SettingsStepper: Item {
        id: stepper
        property int value: 0
        property int minimum: 0
        property int maximum: 24
        property int step: 1
        property bool writable: true
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

            StepButton {
                text: "−"
                canStep: stepper.value > stepper.minimum
                enabled: panel.configHealthy && stepper.writable
                accessName: UiStrings.tr("access.decreaseValue", panel.uiLang)
                tipText: UiStrings.tr("settings.decrease", panel.uiLang)
                onClicked: stepper.bump(-1)
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

            StepButton {
                text: "+"
                canStep: stepper.value < stepper.maximum
                enabled: panel.configHealthy && stepper.writable
                accessName: UiStrings.tr("access.increaseValue", panel.uiLang)
                tipText: UiStrings.tr("settings.increase", panel.uiLang)
                onClicked: stepper.bump(1)
            }
        }
    }

    component SettingsHint: Text {
        width: parent ? parent.width : 0
        color: tokens.muted
        font.family: tokens.fontFamily
        font.pixelSize: tokens.fontBodySmall
        wrapMode: Text.Wrap
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
                text: UiStrings.tr("settings.title", panel.uiLang)
                color: tokens.foreground
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBody
                font.bold: true
            }

            // ---- GENERAL ----

            SettingsSection {
                title: UiStrings.tr("settings.section.general", panel.uiLang)
            }

            // Mode. The chips name the STATE, unlike the bar's button which
            // names the action.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.mode", panel.uiLang)
                }

                SettingsChoice {
                    id: modeControl
                    anchors.verticalCenter: parent.verticalCenter
                    options: [
                        { value: ConfigFile.MODE_DOCKED,
                          label: UiStrings.tr("settings.mode.docked", panel.uiLang) },
                        { value: ConfigFile.MODE_FLOATING,
                          label: UiStrings.tr("settings.mode.floating", panel.uiLang) }
                    ]
                    value: panel.mode
                    onPicked: function (picked) {
                        if (picked !== modeControl.value) panel.setMode(picked)
                    }
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

            // Size: the direct chooser. Choosing the active preset is a
            // no-op; a different one re-derives the floating anchor exactly
            // once, through chooseSizePreset.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.size", panel.uiLang)
                }

                SettingsChoice {
                    id: sizeControl
                    anchors.verticalCenter: parent.verticalCenter
                    options: panel.sizePresetOrder.map(function (preset) {
                        return { value: preset, label: panel.sizePresetLabels[preset] }
                    })
                    value: panel.sizePreset
                    onPicked: function (picked) { panel.chooseSizePreset(picked) }
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

            // Interface language: the override every word on this card
            // hangs off. "auto" follows the active layout (ua -> Ukrainian,
            // ru -> Russian, anything else English — the shipped
            // searchPlaceholder mapping), en/ru/uk pin the UI regardless of
            // the layout. The pinned choices are endonyms — a chooser's
            // entries name themselves in their own language, whatever the
            // rest of the card is speaking — so only "Auto" translates.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.language", panel.uiLang)
                }

                SettingsChoice {
                    id: languageControl
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property var languageLabels: ({
                        auto: UiStrings.tr("settings.lang.auto", panel.uiLang),
                        en: "English", ru: "Русский", uk: "Українська"
                    })
                    // The offered languages mirror the seat's layouts:
                    // Auto and English always, plus each translation
                    // whose layout is installed — a us,ua seat never
                    // sees a Русский segment it cannot type.
                    options: UiStrings.languageChoices(panel.seatLayoutCodes)
                        .map(function (code) {
                            return { value: code,
                                label: languageControl.languageLabels[code] }
                        })
                    value: panel.uiLanguageDisplay
                    onPicked: function (picked) {
                        if (picked !== languageControl.value)
                            panel.setOverride("uiLanguage", picked)
                    }
                }

                SettingsResetChip {
                    anchors {
                        left: languageControl.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "uiLanguage"
                }
            }

            // Pointer profile: which pointer world the panel answers as.
            // auto (the default) activates the touch affordances when the
            // panel observes touch events — a 2-in-1 flipping modes never
            // visits Settings — and mouse/touch pin the world over the
            // observation. The effective behaviour (release-typing, no
            // dwell, grown chrome targets) is InputProfile.js's table;
            // this row only writes the setting.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.inputProfile", panel.uiLang)
                }

                SettingsChoice {
                    id: inputProfileControl
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property var profileLabels: ({
                        auto: UiStrings.tr("settings.profile.auto", panel.uiLang),
                        mouse: UiStrings.tr("settings.profile.mouse", panel.uiLang),
                        touch: UiStrings.tr("settings.profile.touch", panel.uiLang)
                    })
                    options: ConfigFile.INPUT_PROFILES.map(function (value) {
                        var label = inputProfileControl.profileLabels[value]
                        // The flip made visible: when the OBSERVATION
                        // flipped auto to touch, the AUTO chip says so —
                        // typing semantics changed and the user deserves
                        // the one-word notice where the escape lives. The
                        // fact is the OBSERVATION (a synthesized press
                        // arrived), not the effective profile: a
                        // hand-pinned Touch has no news to announce.
                        // The dwell guard hides the notice too: with
                        // dwell enabled the observation never flips
                        // anything, and a lit notice over unchanged mouse
                        // semantics would be a lying notice.
                        if (value === "auto"
                                && panel.touchObserved
                                && panel.inputProfile === "auto"
                                && !panel.dwellEnabled)
                            label = UiStrings.tr("settings.profile.autoTouch",
                                panel.uiLang)
                        return { value: value, label: label }
                    })
                    value: panel.inputProfile
                    onPicked: function (picked) {
                        if (picked !== inputProfileControl.value)
                            panel.setOverride("inputProfile", picked)
                    }
                }

                SettingsResetChip {
                    anchors {
                        left: inputProfileControl.right
                        leftMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "inputProfile"
                }
            }

            // Super mark: what the Super cap draws — the word by default, a
            // mark by choice. Choosing the standing mark is a no-op — no
            // movement, no config write — like choosing the active preset.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.superMark", panel.uiLang)
                }

                SettingsChoice {
                    id: superMarkControl
                    anchors.verticalCenter: parent.verticalCenter
                    // Omarchy, Windows and macOS are names and stay; the
                    // word and the penguin translate.
                    readonly property var superMarkLabels:
                        ({ word: UiStrings.tr("settings.superMark.word", panel.uiLang),
                           omarchy: "Omarchy", windows: "Windows",
                           macos: "macOS",
                           penguin: UiStrings.tr("settings.superMark.penguin", panel.uiLang) })
                    options: ConfigFile.SUPER_MARKS.map(function (mark) {
                        return { value: mark, label: superMarkControl.superMarkLabels[mark] }
                    })
                    value: panel.superMark
                    onPicked: function (picked) { panel.setSuperMark(picked) }
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

            // Sound: the same immediate setOverride path every other control
            // uses.
            Item {
                width: parent.width
                // The unavailable note takes a line of its own: the row
                // grows only while it shows, so the word is never clipped
                // against the switch.
                height: panel.sound && panel.soundUnavailable
                    ? tokens.space(44) : tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    id: soundRowLabel
                    anchors.verticalCenterOffset:
                        panel.sound && panel.soundUnavailable
                            ? -tokens.space(7) : 0
                    text: UiStrings.tr("settings.row.sound", panel.uiLang)
                }

                Text {
                    anchors {
                        left: parent.left
                        top: soundRowLabel.bottom
                        topMargin: 1
                    }
                    visible: panel.sound && panel.soundUnavailable
                    text: UiStrings.tr("settings.sound.unavailable", panel.uiLang)
                    color: tokens.urgent
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                SettingsSwitch {
                    id: soundSwitch
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.sound
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: soundRowLabel.text
                    Accessible.checked: panel.sound
                    onToggled: panel.setOverride("sound", !panel.sound)
                }

                SettingsResetChip {
                    anchors {
                        left: soundSwitch.right
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "sound"
                }
            }

            // ---- EMOJI PAGE ----

            SettingsSection {
                title: UiStrings.tr("settings.section.emoji", panel.uiLang)
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55
                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.emojiPicking", panel.uiLang)
                }
                SettingsChoice {
                    id: emojiPickingControl
                    anchors.verticalCenter: parent.verticalCenter
                    options: [
                        { value: "false",
                          label: UiStrings.tr("settings.emoji.keepOpen", panel.uiLang) },
                        { value: "true",
                          label: UiStrings.tr("settings.emoji.close", panel.uiLang) }
                    ]
                    value: String(panel.emojiCloseAfterPick)
                    onPicked: function (picked) {
                        // The chips carry strings; this row is a boolean,
                        // and writing "true"/"false" to config.json
                        // resurrects exactly the legacy string form the
                        // loader's heal exists to cure — every other
                        // boolean saves as a real boolean.
                        if (picked !== emojiPickingControl.value)
                            panel.setOverride("emojiCloseAfterPick",
                                picked === "true")
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
                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.emojiPageSize", panel.uiLang)
                }
                SettingsChoice {
                    id: emojiPageSizeControl
                    anchors.verticalCenter: parent.verticalCenter
                    options: [
                        { value: "medium", label: "M" },
                        { value: "large", label: "L" },
                        { value: "x-large", label: "XL" }
                    ]
                    value: panel.emojiPageSize
                    onPicked: function (picked) {
                        if (picked !== emojiPageSizeControl.value)
                            panel.setOverride("emojiPageSize", picked)
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

            // Whether the emoji page grows its drag strip. The picking
            // row's own shape and the same string-carrying rule (the value
            // arrives as "true"/"false" and must be written a real boolean).
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55
                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.emojiDrag", panel.uiLang)
                }
                SettingsChoice {
                    id: emojiDragControl
                    anchors.verticalCenter: parent.verticalCenter
                    options: [
                        { value: "false",
                          label: UiStrings.tr("settings.emojiDrag.inPlace", panel.uiLang) },
                        { value: "true",
                          label: UiStrings.tr("settings.emojiDrag.movable", panel.uiLang) }
                    ]
                    value: String(panel.emojiDrag)
                    onPicked: function (picked) {
                        if (picked !== emojiDragControl.value)
                            panel.setOverride("emojiDrag", picked === "true")
                    }
                }
                SettingsResetChip {
                    anchors.left: emojiDragControl.right
                    anchors.leftMargin: tokens.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "emojiDrag"
                }
            }

            // ---- DWELL ----
            //
            // The accessibility pair: rest-to-type, off until it is
            // turned on, and how long a rest must hold before the cap
            // types. The bounds are Dwell.js's own window — the module
            // clamps the timer into exactly this range, and the file
            // validates to it, so the stepper cannot offer a value the
            // keyboard would refuse.

            SettingsSection {
                title: UiStrings.tr("settings.section.dwell", panel.uiLang)
            }

            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    id: dwellRowLabel
                    text: UiStrings.tr("settings.row.dwellTyping", panel.uiLang)
                }

                SettingsSwitch {
                    id: dwellSwitch
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.dwellEnabled
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: dwellRowLabel.text
                    Accessible.checked: panel.dwellEnabled
                    onToggled: panel.setOverride("dwellEnabled",
                        !panel.dwellEnabled)
                }

                SettingsResetChip {
                    anchors {
                        left: dwellSwitch.right
                        verticalCenter: parent.verticalCenter
                    }
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    overrideName: "dwellEnabled"
                }
            }

            // The delay means nothing while dwell typing is off: the row
            // dims and takes no writes, like the border colour with the
            // border off.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy && panel.dwellEnabled ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.dwellDelay", panel.uiLang)
                }

                SettingsStepper {
                    id: dwellDelayStepper
                    x: popoverRoot.controlColumnX
                    anchors.verticalCenter: parent.verticalCenter
                    value: panel.dwellDelayMs
                    minimum: Dwell.DELAY_MIN_MS
                    maximum: Dwell.DELAY_MAX_MS
                    step: 100
                    writable: panel.dwellEnabled
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
                    active: panel.dwellEnabled
                }
            }

            SettingsHint {
                text: UiStrings.tr("settings.hint.dwellDelay", panel.uiLang)
            }

            // ---- APPEARANCE ----
            //
            // The Look choice heads the fields it governs (decisions §116):
            // "Omarchy theme" hands all eight to the theme and hides the
            // rows; "Custom" shows them. Every control applies through
            // setOverride — immediate, atomic, sparse — except the hex
            // fields' drafts, which wait for their check or Return.

            SettingsSection {
                title: UiStrings.tr("settings.section.appearance", panel.uiLang)
            }

            // The choice writes followTheme exactly as a switch would, and
            // carries no reset: each segment is itself the way back.
            Item {
                width: parent.width
                height: tokens.space(28)
                opacity: panel.configHealthy ? 1 : 0.55

                SettingsRowLabel {
                    text: UiStrings.tr("settings.row.look", panel.uiLang)
                }

                SettingsChoice {
                    id: lookControl
                    anchors.verticalCenter: parent.verticalCenter
                    options: [
                        { value: "theme",
                          label: UiStrings.tr("settings.look.theme", panel.uiLang) },
                        { value: "custom",
                          label: UiStrings.tr("settings.look.custom", panel.uiLang) }
                    ]
                    value: panel.followTheme ? "theme" : "custom"
                    onPicked: function (picked) {
                        var follow = picked === "theme"
                        if (follow === panel.followTheme) return
                        // An editor left open would apply a custom colour
                        // onto a look that has just been handed back.
                        if (follow) panel.closeCustomEditor()
                        panel.setOverride("followTheme", follow)
                    }
                }
            }

            SettingsHint {
                visible: panel.followTheme
                text: UiStrings.tr("settings.hint.lookTheme", panel.uiLang)
            }

            // The user's own look. Hidden while the theme answers: a stored
            // override is dormant then (Config.overrideApplies), and the
            // rows would only show the theme's values back.
            Column {
                id: customRows
                width: parent.width
                spacing: parent.spacing
                visible: !panel.followTheme

                Item {
                    width: parent.width
                    height: tokens.space(28)
                    opacity: panel.configHealthy ? 1 : 0.55

                    SettingsRowLabel {
                        text: UiStrings.tr("settings.row.keyRadius", panel.uiLang)
                    }

                    SettingsStepper {
                        id: keyRadiusStepper
                        x: popoverRoot.controlColumnX
                        anchors.verticalCenter: parent.verticalCenter
                        value: keyTokens.capCorner
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

                SettingsHint {
                    text: UiStrings.tr("settings.hint.keyRadius", panel.uiLang)
                }

                // The docked card is always square, so the panel radius
                // means nothing while docked: the row dims and takes no
                // writes, like the border colour with the border off.
                Item {
                    width: parent.width
                    height: tokens.space(28)
                    readonly property bool applies:
                        panel.mode !== ConfigFile.MODE_DOCKED
                    opacity: panel.configHealthy && applies ? 1 : 0.55

                    SettingsRowLabel {
                        text: UiStrings.tr("settings.row.panelRadius", panel.uiLang)
                    }

                    SettingsStepper {
                        id: panelRadiusStepper
                        x: popoverRoot.controlColumnX
                        anchors.verticalCenter: parent.verticalCenter
                        value: keyTokens.panelRadius
                        minimum: 0
                        maximum: 32
                        writable: parent.applies
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
                        active: parent.applies
                    }
                }

                // The colour rows: square (opens the custom editor), hex,
                // check while a draft is dirty, reset — each feeding the
                // same panel API.
                SettingsColorRow {
                    id: keyBackgroundRow
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    controlX: popoverRoot.controlColumnX
                    fieldName: "keyBackground"
                    labelText: UiStrings.tr("settings.row.keyBackground", panel.uiLang)
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
                    labelText: UiStrings.tr("settings.row.panelBackground", panel.uiLang)
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
                    labelText: UiStrings.tr("settings.row.textColor", panel.uiLang)
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
                    labelText: UiStrings.tr("settings.row.accentColor", panel.uiLang)
                    effectiveColor: panel.effectiveAccentColor
                    onCustomRequested: popoverRoot.customColourRequested(
                        accentColorRow.fieldName, accentColorRow.labelText)
                }

                // The border: its switch, and only while the border is
                // drawn, its colour beside it.
                SettingsColorRow {
                    id: borderColorRow
                    tokens: popoverRoot.tokens
                    panel: popoverRoot.panel
                    controlX: popoverRoot.controlColumnX
                    fieldName: "borderColor"
                    labelText: UiStrings.tr("settings.row.borderColor", panel.uiLang)
                    effectiveColor: panel.effectiveBorderColor
                    active: keyTokens.borderShown
                    hasSwitch: true
                    switchLabel: UiStrings.tr("settings.row.panelBorder", panel.uiLang)
                    switchChecked: keyTokens.borderShown
                    switchOverrideName: "panelBorder"
                    onSwitchToggled: panel.setOverride("panelBorder", !keyTokens.borderShown)
                    onCustomRequested: popoverRoot.customColourRequested(
                        borderColorRow.fieldName, borderColorRow.labelText)
                }

                SettingsHint {
                    text: UiStrings.tr("settings.hint.hex", panel.uiLang)
                }
            }

            // The malformed-file notice. While it stands, the rows above
            // dim and their controls refuse writes: the
            // values shown are the last valid runtime state, the bad file
            // is preserved exactly as the external editor wrote it, and
            // fixing the file lets the watched reload clear this line.
            Text {
                width: parent.width
                visible: panel.configurationError !== ""
                    || panel.stateError !== ""
                text: (panel.configurationError
                    ? UiStrings.tr("settings.hint.configError", panel.uiLang,
                        [panel.configurationError])
                    : "")
                    + (panel.configurationError && panel.stateError ? "\n" : "")
                    + (panel.stateError
                    ? UiStrings.tr("settings.hint.stateError", panel.uiLang,
                        [panel.stateError])
                    : "")
                color: tokens.urgent
                font.family: tokens.fontFamily
                font.pixelSize: tokens.fontBodySmall
                wrapMode: Text.Wrap
            }

            PanelSeparator {
                visible: resetAllRow.visible
                foreground: tokens.foreground
            }

            // Reset-all, the card's footer row: a bordered ghost button
            // — the quietest voice on the card, because it is
            // the one destructive action — with its confirmation inline:
            // first click arms the row, and only the urgent Reset commits.
            // Hidden entirely while the sparse file carries no overrides.
            Item {
                id: resetAllRow
                width: parent.width
                height: tokens.space(28)
                visible: Object.keys(panel.userOverrides).length > 0

                Button {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    visible: !popoverRoot.resetAllArmed
                    enabled: panel.configHealthy
                    height: tokens.space(24)
                    verticalPadding: 0
                    bordered: true
                    text: UiStrings.tr("settings.resetAll", panel.uiLang)
                    foreground: tokens.foreground
                    accent: tokens.accent
                    fontFamily: tokens.fontFamily
                    fontSize: tokens.fontBodySmall
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    onClicked: popoverRoot.resetAllArmed = true
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
                            text: UiStrings.tr("settings.resetAllConfirm", panel.uiLang)
                            color: tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                        }
                    }

                    // The shell's Button has no urgent state; the card's
                    // one destructive action reads as the urgent colour,
                    // the close button's own.
                    Rectangle {
                        width: confirmResetLabel.implicitWidth + tokens.space(8) * 2
                        height: tokens.space(24)
                        radius: tokens.cornerRadius
                        color: tokens.urgent

                        Text {
                            id: confirmResetLabel
                            anchors.centerIn: parent
                            text: UiStrings.tr("settings.reset", panel.uiLang)
                            color: tokens.background
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: true
                        }

                        MouseArea {
                            id: confirmResetArea
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            Accessible.role: Accessible.Button
                            Accessible.name: confirmResetLabel.text
                            onClicked: {
                                popoverRoot.resetAllArmed = false
                                panel.clearAllOverrides()
                            }
                        }
                    }

                    Button {
                        height: tokens.space(24)
                        verticalPadding: 0
                        bordered: true
                        text: UiStrings.tr("settings.keep", panel.uiLang)
                        foreground: tokens.foreground
                        accent: tokens.accent
                        fontFamily: tokens.fontFamily
                        fontSize: tokens.fontBodySmall
                        Accessible.role: Accessible.Button
                        Accessible.name: text
                        onClicked: popoverRoot.resetAllArmed = false
                    }
                }
            }
        }
    }
}
