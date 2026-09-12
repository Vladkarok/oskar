import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Config.js" as ConfigFile
import "PickerFit.js" as PickerFit
import "PickerSession.js" as PickerSession
import "SettingsPlacement.js" as SettingsPlacement

Item {
    id: root

    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool dependenciesReady: true

    // ---- configuration ----
    //
    // v1.1 gives configuration three non-overlapping roles: complete shipped
    // defaults in Config.js, sparse choices in config.json, and geometry in
    // state.json. Both writable files are watched below; no polling is used.
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
        || ((Quickshell.env("HOME") || "") + "/.config")) + "/omarchy-osk"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
        || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/omarchy-osk"
    readonly property string configPath: configDir + "/config.json"
    readonly property string statePath: stateDir + "/state.json"
    readonly property var maintainedDefaults: ConfigFile.maintainerDefaults()
    property var userOverrides: ({})
    // Reset-all's armed confirm must never outlive the overrides it was
    // armed against: whatever empties the map — the confirm chip, a per-row
    // reset, an external reload — disarms it here, so the widened confirm
    // row can never linger hidden until close.
    onUserOverridesChanged: {
        if (Object.keys(root.userOverrides).length === 0)
            settingsPopover.resetAllArmed = false
    }
    property var geometryState: ConfigFile.stateDefaults()
    property string configurationError: ""
    property string stateError: ""
    // Every control that writes the overrides file stands down while a
    // malformed external edit is standing (spec-v1.1 §5): the popover keeps
    // showing the last valid runtime values and says so, and the bad file is
    // never overwritten (saveOverrides refuses). The watched reload clears
    // the error the moment the file is fixed; nothing is polled.
    readonly property bool configHealthy: root.configurationError === ""

    // Geometry (spec-v1 §7). Docked — the default, because it needs no
    // positioning decision from someone who just installed the plugin —
    // reserves a full-width strip along the bottom edge so windows move up
    // instead of being covered; floating overlays and is dragged around.
    // `center` is geometry state; `size_preset` is a user preference. They
    // intentionally persist to different files even though both affect the
    // floating card.
    property string mode: maintainedDefaults.mode
    // Dock/float moves the band the picker must stay clear of (full-width
    // strip vs floating card), so it is one of the session's re-fit signals.
    onModeChanged: root.requestPickerFit()
    property var floatingCenter: null
    property string sizePreset: maintainedDefaults.sizePreset

    // Size presets (spec-v1 §7): chosen from a direct M/L/XL chooser
    // (spec-v1.1 §4), not a resize handle. `medium` is the geometry the
    // keyboard shipped with and the smallest of the three — the presets only
    // go up, because the hit targets are already sized for touch at `medium`
    // and a smaller preset would trade that away. An unknown name in the
    // config file lands on `medium`, which is what the chips' label
    // fallback in the settings popover already does below.
    readonly property var sizePresetOrder: ["medium", "large", "x-large"]
    readonly property var sizePresetScales: ConfigFile.SIZE_PRESET_SCALES
    readonly property var sizePresetLabels: ({ "medium": "M", "large": "L", "x-large": "XL" })
    readonly property real sizeScale: root.sizePresetScales[root.sizePreset] || 1.0

    // The colour rows' recommended swatches (spec-v1.1 §5, 2026-09-06
    // amendment): up to four theme-derived colours — background, foreground,
    // accent, muted — with maintained fallbacks and duplicates removed,
    // resolved through Config.js. A swatch click writes its resolved colour
    // as an explicit override, so a later theme change never silently
    // rewrites a choice made here.
    readonly property var colorSwatches: ConfigFile.recommendedSwatches({
        background: tokens.background,
        foreground: tokens.foreground,
        accent: tokens.themeAccent,
        muted: tokens.muted
    })

    // The colour now in force for each appearance field — override, or the
    // resolved token when none — the one mapping the colour rows (through
    // the popover) and the custom editor read. Function-formed consumers
    // keep the first binding evaluation, in whatever order the engine runs
    // it, from ever handing a row undefined.
    // Real color properties so settings rows rebind when Custom Apply
    // writes an override. A JS object map does not notify.
    readonly property color effectiveKeyBackground: tokens.keyFill
    readonly property color effectivePanelBackground: tokens.panelBackground
    readonly property color effectiveTextColor: tokens.textColor
    readonly property color effectiveAccentColor: tokens.accent
    readonly property color effectiveBorderColor: tokens.cardBorderSpec
        && tokens.cardBorderSpec.color
        ? tokens.cardBorderSpec.color : "transparent"
    QtObject {
        id: effectiveColors
        readonly property color keyBackground: root.effectiveKeyBackground
        readonly property color panelBackground: root.effectivePanelBackground
        readonly property color textColor: root.effectiveTextColor
        readonly property color accentColor: root.effectiveAccentColor
        readonly property color borderColor: root.effectiveBorderColor
    }
    readonly property alias effectiveColorForField: effectiveColors

    // The emoji picker (spec-v1.1 §1, 2026-09-05 amendment): the app the ☺
    // cap execs, defaulting to Omarchy's own omarchy-menu-emoji and
    // changeable from the popover's Emoji app row. `detectedEmojiPickers` is
    // the PATH probe's answer, gathered once at load like the other
    // dependency checks; the row offers those, the override may still name
    // any app (an external edit), and a configured name missing from PATH is
    // the ☺ click's transient hint.
    property string emojiApp: maintainedDefaults.emojiApp
    property var detectedEmojiPickers: []
    readonly property var emojiPickerCandidates:
        ["omarchy-menu-emoji", "emote", "xmoji", "bmoji"]
    // Colour-field entry — the panel's ONE sanctioned keyboard-focus
    // exception (spec-v1.1 §5). False except while a hex/RGB/HSV field is
    // the active entry: the popover or editor window that holds that field
    // then asks for Exclusive then OnDemand so the main OSK types into it.
    // The keyboard panel itself stays None. One field at a time, panel-owned.
    property bool hexEditing: false
    property string hexEditField: ""

    function beginHexEdit(field) {
        root.hexEditField = field
        root.hexEditing = true
    }

    function colourSurfaceKeyboardFocus(ownsField) {
        if (!root.hexEditing || !ownsField)
            return WlrKeyboardFocus.None
        return root.hexFocusPrimed ? WlrKeyboardFocus.OnDemand
                                   : WlrKeyboardFocus.Exclusive
    }

    function endHexEdit() {
        var released = ConfigFile.hexEditRelease()
        root.hexEditing = released.hexEditing
        root.hexEditField = released.hexEditField
        // Park on a stable non-TextInput in the window that held the field
        // so a later hide cannot recapture §5. Custom/Cancel/leftover call
        // this because their MouseAreas do not steal focus on their own.
        if (released.dropItemFocus) {
            if (root.customEditorField !== "")
                editorFocusSink.forceActiveFocus()
            else
                popoverFocusSink.forceActiveFocus()
        }
    }

    // The custom colour editor (spec-v1.1 §5): which field it is open for,
    // empty when closed. It sits on its own overlay window, never on the grid.
    property string customEditorField: ""
    property string customEditorLabel: ""
    // Snapshot of the effective colour at open — the editor's "old". A live
    // binding would reset HSV from later theme/config changes while leaving
    // the hex draft stale, and Apply would then commit that stale hex.
    property color customEditorOldColor: "transparent"

    function colorForField(field) {
        if (field === "keyBackground") return root.effectiveKeyBackground
        if (field === "panelBackground") return root.effectivePanelBackground
        if (field === "textColor") return root.effectiveTextColor
        if (field === "accentColor") return root.effectiveAccentColor
        if (field === "borderColor") return root.effectiveBorderColor
        return "transparent"
    }

    function openCustomEditor(field, label) {
        if (!root.configHealthy) return
        root.customEditorOldColor = root.colorForField(field)
        root.customEditorField = field
        root.customEditorLabel = label
    }

    function closeCustomEditor() {
        // Always restore OSK routing before clearing the field name: the
        // editor's hide/focus handlers compare hexEditField against
        // fieldName, which is about to become empty.
        root.endHexEdit()
        root.customEditorField = ""
        root.customEditorLabel = ""
    }

    // The focus prime (Omarchy's own KeyboardPanel pattern, Ui/
    // KeyboardPanel.qml): Hyprland focuses an OnDemand layer surface when it
    // MAPS, but not when an already-mapped surface flips None -> OnDemand —
    // which is exactly what beginHexEdit does to the popover or editor
    // window that holds the field. A brief Exclusive prime acquires the
    // compositor's keyboard focus; OnDemand then settles in for the rest of
    // the entry, releasing compositor-wide pointer hit-testing while keeping
    // the focus the prime acquired. 75 ms — several commit cycles,
    // imperceptible.
    property bool hexFocusPrimed: false
    Timer {
        id: hexFocusPrimeTimer
        interval: 75
        onTriggered: if (root.hexEditing) root.hexFocusPrimed = true
    }
    onHexEditingChanged: {
        if (root.hexEditing) {
            root.hexFocusPrimed = false
            hexFocusPrimeTimer.restart()
        } else {
            root.hexFocusPrimed = false
        }
    }

    // The resize anchors (spec-v1.1 §4, decisions §21). Docked is a
    // bottom-anchored full-width strip, so a preset change preserves
    // bottom-centre by construction: the window's height binding follows the
    // keyboard and the compositor moves the top edge, never the bottom (see
    // the PanelWindow below). Floating keeps the card CENTRE: the top-left is
    // rederived from the saved centre by ConfigFile.floatingAnchor, which
    // clamps only enough to keep the complete card on its output. The chips
    // live in the settings popover (spec-v1.1 §5), which stays open through
    // a choice — a settings surface is dismissed, not spent, by using it —
    // so choosing the active preset is simply a no-op: no movement, no
    // config write; a different preset re-derives exactly once, through
    // setOverride's applyEffectiveSettings.
    function chooseSizePreset(preset) {
        if (preset === root.sizePreset) return
        root.sizePreset = preset
        root.setOverride("sizePreset", preset)
    }

    // Key click sound: the freedesktop sound theme's event sound, off by
    // default — the stated use case is watching a film, and the mouse already
    // makes a click.
    property bool sound: maintainedDefaults.sound
    // v1 escape hatch for the independent colour schema (spec-v1 §8); it
    // follows the theme and does nothing else yet, but is persisted so the
    // key exists from the start.
    property bool followTheme: maintainedDefaults.followTheme
    // Absolute path of the PCM copy the click effect plays; empty until
    // resolved or when the theme has no such event.
    property string soundFile: ""
    // A sound setting of ON with an effect that cannot play is never silent
    // about it (the §3 rule for visible caps, applied to the settings
    // popover): a failed theme lookup or a missing QtMultimedia raises this
    // and the sound row says "unavailable" at the switch itself — one
    // mechanism, where the setting lives. Cleared by a successful resolve
    // and irrelevant while the switch is off.
    property bool soundUnavailable: false

    // Every colour, font, radius and spacing the panel draws with comes from
    // here, and from nowhere else (spec-v1 §8). Following the theme is what a
    // plain binding through it already does — the shell reassigns the shared
    // tokens on a theme switch and the keyboard redraws where it stands, with
    // no restart, no keymap compile and no reconnection, because none of that
    // is on this path. `follow_theme: false` is the one thing that needs code.
    // The sparse override map rides in as the facade's top precedence tier
    // (spec-v1.1 §5): the popover writes overrides, the facade resolves
    // override over token over shipped fallback, and no panel property or
    // second reader stands between them.
    Theme {
        id: tokens
        follow: root.followTheme
        overrides: root.userOverrides
    }

    function checkDependencies() {
        dependencyCheck.running = true
    }

    function installDependencies() {
        if (dependencyInstall.running) return
        dependencyInstall.running = true
    }

    // ---- helper lifecycle actions (spec-v1.1 §6) ----
    //
    // Retry runs the one command the spec names, detached like every other
    // process spawn here, and lets the socket client's existing repair path
    // (rebuild when the socket file exists, hello, configure) do the
    // reconnecting — no poll behind the button. Copy hands the install
    // command to the compositor clipboard through Quickshell's own
    // clipboardText; nothing is ever installed, built or elevated by the
    // panel itself.
    readonly property string installCommand: "bash " + (Quickshell.env("HOME") || "")
        + "/.config/omarchy/plugins/io.github.vladkarok.osk/install.sh"

    function retryService() {
        Quickshell.execDetached(["systemctl", "--user", "start", "omarchy-osk.service"])
    }

    function copyInstallCommand() {
        Quickshell.clipboardText = root.installCommand
    }

    // Current-content paste (spec-v1.1 §1, ticket 14). Never writes
    // CLIPBOARD. An active hex draft is the local target and the one path
    // that reads the selection (to insert it); otherwise the helper sends
    // the proven paste chord at whoever already has focus. Empty clipboard
    // hides the chip. The control stays clickable whenever it can deliver —
    // Quickshell's clipboard getter is not a reliable empty check and is
    // not the hex-insert source (it stays empty/stale here).
    readonly property bool pasteEnabled: root.hexEditing || keyboard.inputReady
    // CLIPBOARD observation for the chip: empty / text / other. Refreshed
    // on panel open, on paste click, and by wl-paste --watch — never polled.
    property string clipboardKind: "empty"
    property string clipboardPreview: ""
    property int clipboardSeq: 0
    // Last non-empty focused class: a layer click can briefly clear
    // activeToplevel, and terminals vs GTK pick different CLIPBOARD chords.
    property string lastClientClass: ""

    function focusedClientClass() {
        var top = Hyprland.activeToplevel
        var cls = ""
        if (top && top.lastIpcObject)
            cls = String(top.lastIpcObject["class"] || "")
        if (cls) root.lastClientClass = cls
        return cls || root.lastClientClass
    }

    function pasteCurrentContent() {
        if (!root.pasteEnabled) return
        if (root.hexEditing) {
            // wl-paste reads compositor CLIPBOARD. Quickshell.clipboardText
            // is empty/stale in this stack, so it cannot be the insert path.
            if (hexClipboardRead.running)
                hexClipboardRead.running = false
            hexClipboardRead.running = true
            root.refreshClipboardPreview()
            return
        }
        keyboard.pasteCurrent(root.focusedClientClass())
        root.refreshClipboardPreview()
    }

    function refreshClipboardPreview() {
        root.clipboardSeq += 1
        clipboardTypes.seq = root.clipboardSeq
        if (clipboardTypes.running)
            clipboardTypes.running = false
        clipboardTypes.running = true
    }

    function applyClipboardTypes(text, seq, exitCode) {
        if (seq !== root.clipboardSeq) return
        var kind = ConfigFile.clipboardKind(text, exitCode)
        // Text stays hidden until wl-paste --no-newline returns a
        // non-empty preview; empty/other apply immediately.
        root.clipboardKind = ConfigFile.pasteChipKind(kind, "", false)
        root.clipboardPreview = ""
        if (kind !== "text") return
        clipboardText.seq = seq
        if (clipboardText.running)
            clipboardText.running = false
        clipboardText.running = true
    }

    function applyClipboardText(text, seq, exitOk) {
        if (seq !== root.clipboardSeq) return
        var preview = ConfigFile.pastePreviewText(text)
        root.clipboardKind = ConfigFile.pasteChipKind("text", preview, exitOk)
        root.clipboardPreview = root.clipboardKind === "text" ? preview : ""
    }

    function insertHexClipboard(raw) {
        var text = String(raw || "")
        if (text.length && text.charAt(text.length - 1) === "\n")
            text = text.slice(0, -1)
        if (!root.hexEditing || !text.length) return
        if (root.customEditorField !== "") customColorEditor.insertHexText(text)
        else settingsPopover.insertHexText(text)
    }

    // The hint line's one state table (spec-v1.1 §3, §1, §6). The newest
    // answer to a click wins: a failure names itself here — text plus whether
    // it draws in the accent colour — instead of a clear header, and hands the
    // hint back when it recovers or auto-clears; the keymap failure, if one
    // is also standing, re-shows then. One readonly property rather than a
    // function re-invoked in every binding: the table is evaluated once per
    // state change and the bar's bindings stay dumb mirrors of it, with each
    // future state landing as one more arm here.
    //
    // It lives on the panel root on purpose: QML resolves bare names only
    // against the component's root object, so the same table defined on the
    // drag bar silently blanked every hint binding that used it (the one
    // regression cab882e's "no re-shoot" claim missed; the nested run for
    // this ticket caught it).
    //
    // The helper lifecycle states (spec-v1.1 §6) sit between the transient
    // click answers and a clear header. Kind comes from the session
    // (Keyboard.lifecycleKind): incompatible and stopped outrank a keymap
    // mismatch because without a usable service nothing can type, but a
    // connected mismatch is unavailable — never the starting notice
    // (decisions §23). Ready is absent on purpose: the notice disappears
    // once the handshake succeeds and the line stays empty. `action`
    // carries the affordance the chips below draw:
    // "retry" for a service that is not running, "update" for a protocol
    // mismatch (Copy install command plus Retry).
    readonly property var hintState: {
        if (keyboard.emojiFailed)
            return {
                text: keyboard.emojiAppName + " not found on PATH",
                accent: true
            }
        if (root.pickerFitConstraint !== "")
            return {
                text: root.pickerFitConstraint + " can\u2019t open clear of the keyboard",
                accent: true
            }
        if (keyboard.lifecycleKind === "incompatible")
            return {
                text: "omarchy-osk.service needs updating",
                accent: true,
                action: "update"
            }
        if (keyboard.lifecycleKind === "stopped")
            return {
                text: "omarchy-osk.service is not running",
                accent: true,
                action: "retry"
            }
        if (keyboard.lifecycleKind === "unavailable")
            return {
                text: "Keymap unavailable — drawn caps may not match what typing produces",
                accent: true
            }
        if (keyboard.lifecycleKind === "starting" && root.startingNoticeDue)
            return {
                text: "Starting omarchy-osk.service\u2026",
                accent: false
            }
        return {
            text: "",
            accent: false
        }
    }

    // The starting notice answers a helper the panel is genuinely waiting on,
    // which is a thing that takes a visible moment — a service ordered against
    // graphical-session.target, a socket rebuilt after a drop. It is not the
    // right answer to a state that resolves inside a couple of frames: a
    // reconfigure that briefly closes the typing gate would otherwise paint
    // the notice and take it away again, which reads as a glitch rather than
    // as information. So the state has to hold before it is named. Falling out
    // of it clears the delay immediately — a notice that outlived its state
    // would be worse than a late one.
    // Cleared when the STATE leaves, not when the timer stops. A one-shot
    // Timer sets `running` false immediately after `triggered`, so clearing on
    // `runningChanged` undid the flag in the same turn that set it and the
    // notice could never paint at all — the delay deleted the thing it was
    // meant to delay. Verified under Qt 6: the two handlers run back to back
    // and the flag is true for zero frames.
    readonly property bool helperStarting: keyboard.lifecycleKind === "starting"
    property bool startingNoticeDue: false
    onHelperStartingChanged: if (!helperStarting) startingNoticeDue = false
    Timer {
        interval: 400
        running: root.helperStarting
        onTriggered: root.startingNoticeDue = true
    }

    // Cursor hiding (spec-v1 §9) is owned by CursorPolicy (CursorPolicy.qml
    // + CursorPolicy.js), not by the panel's presentation code: one
    // serialized lifecycle for probe, override and restore, so a close that
    // lands before the probe answers cannot leave a session override behind
    // (review finding R6). The binding drives it whatever writer flips
    // `opened` — the bar toggle, close(), or the shell itself.
    CursorPolicy {
        id: cursorPolicy
        targetOpened: root.opened
    }

    function open(payloadJson) {
        root.opened = true
    }

    function close() {
        root.opened = false
    }

    function toggle() {
        root.opened = !root.opened
    }

    function setMode(newMode) {
        // The same stand-down the popover's controls get from their enabled
        // bindings and the resets get in clearOverride: with a malformed
        // external edit standing, nothing writes — and the in-memory state
        // does not move either, or the bar's mode button would drift the
        // panel from a file it cannot save.
        if (!root.configHealthy) return
        if (root.mode === newMode) return
        root.mode = newMode
        // The docked pin releases here, so the card falls back to whatever x/y
        // it last had; put it where floating actually left it.
        root.applyFloatingPosition()
        root.setOverride("mode", newMode)
    }

    // ---- which output, and where on it (spec-v1 §7) ----
    //
    // Both modes open on the monitor the pointer is on and then stay there
    // until closed or dragged. Deliberately not bound to Hyprland's focused
    // monitor: that would move the panel — and, docked, reflow the windows on
    // two outputs — every time the user alt-tabs. The pointer is asked once,
    // at the moment of opening, and once more when a drag ends.
    //
    // The pointer's position comes from `hyprctl cursorpos`; Wayland gives a
    // client no way to ask where the cursor is, and hyprctl is already a
    // dependency of the layout tracker.
    property var pendingScreenAction: null

    function moveToPointerScreen(afterwards) {
        root.pendingScreenAction = afterwards || null
        // A Process that is already running ignores `running = true`, so stop
        // it first (the same dance as resolveSoundFile).
        cursorProbe.running = false
        cursorProbe.running = true
    }

    function screenAt(x, y) {
        var screens = Quickshell.screens
        for (var i = 0; i < screens.length; i++) {
            var candidate = screens[i]
            if (x >= candidate.x && x < candidate.x + candidate.width
                && y >= candidate.y && y < candidate.y + candidate.height)
                return candidate
        }
        return null
    }

    function clamp(value, low, high) {
        if (high < low) return low
        return Math.max(low, Math.min(high, value))
    }

    // Floating position is stored as the card centre local to whatever output
    // the panel is on — the deterministic anchor of spec-v1.1 §4 — not in
    // compositor coordinates: the panel follows the pointer's monitor at
    // open, so a global position would put it half off a differently-sized
    // second screen. The top-left is rederived and re-clamped on every
    // application, because the output, the preset or the theme may all have
    // changed since the centre was written; an unchanged triple restores the
    // exact same top-left, and a changed one moves the card no further than
    // staying fully on the output demands.
    function applyFloatingPosition() {
        if (root.mode !== "floating") return
        if (!root.floatingCenter) return
        // A held drag owns the placement. The re-derivations below all fire
        // from paths that can land mid-drag — a watched-config reload
        // changing the preset (applyEffectiveSettings), an output or theme
        // change, the card's own settle handlers — and any of them snapping
        // the card out of the hand would fight the pointer. The release
        // records wherever the hand left it (rememberFloatingPosition), and
        // later resizes re-anchor from that.
        if (dragArea.drag.active) return
        if (panel.width <= 0 || panel.height <= 0) return
        var topLeft = ConfigFile.floatingAnchor(root.floatingCenter,
            card.width, card.height, panel.width, panel.height)
        card.x = topLeft.x
        card.y = topLeft.y
    }

    // A press on the bar that moved nothing is still a release, and every save
    // is a blocking atomic write — so only a centre that actually changed is
    // written back. The centre is what gets saved (spec-v1.1 §4); storing the
    // dragged top-left instead was the defect this panel shipped with: a card
    // dragged near an edge restored to a different visible spot whenever the
    // preset or the output had changed between save and restore.
    function rememberFloatingPosition() {
        var center = { x: card.x + card.width / 2, y: card.y + card.height / 2 }
        var previous = root.floatingCenter
        if (previous && previous.x === center.x && previous.y === center.y) return
        root.floatingCenter = center
        root.geometryState = { center: root.floatingCenter }
        root.saveState()
    }

    // A drag can end with the pointer over a different output: the card itself
    // stops at the edge of its own surface (layer-shell gives us one output at
    // a time), but the pointer keeps going. Ending there hands the panel to
    // that output and drops the card under the pointer, which is what "drag it
    // to the other monitor" has to mean here.
    function finishDrag() {
        if (root.mode !== "floating") return
        root.moveToPointerScreen(function (pointer, pointerScreen) {
            if (pointerScreen && pointerScreen !== panel.screen) {
                panel.screen = pointerScreen
                card.x = root.clamp(pointer.x - pointerScreen.x - card.width / 2,
                    0, Math.max(0, pointerScreen.width - card.width))
                card.y = root.clamp(card.y, 0, Math.max(0, pointerScreen.height - card.height))
            }
            root.rememberFloatingPosition()
        })
    }

    function applyEffectiveSettings() {
        // Mode, size, sound and follow-theme are panel properties; the
        // appearance fields resolve reactively in the Theme facade, which
        // holds the overrides as its top precedence tier — no imperative
        // appearance step is wanted here, because a resolved binding is what
        // keeps a following keyboard live across shell theme switches even
        // with some fields pinned.
        var effective = ConfigFile.merge(root.maintainedDefaults, root.userOverrides, null)
        root.mode = effective.mode
        root.sizePreset = effective.sizePreset
        var soundChanged = root.sound !== effective.sound
        root.sound = effective.sound
        root.followTheme = effective.followTheme
        // The emoji picker is a plain preference like the mode: override,
        // else the maintained default (Omarchy's own). The ☺ cap reads it at
        // click time through the keyboard, the popover row mirrors it.
        // Changing picker app ends the running picker session — the session
        // belongs to the appearance of the app it was launched for.
        if (root.emojiApp !== effective.emojiApp) {
            root.emojiApp = effective.emojiApp
            if (root.pickerSession)
                root.settlePickerMachine(
                    PickerSession.panelClosed(root.pickerSession, root.focusedAddress()))
            else
                root.endPickerSession()
        }
        // A follow-theme flip while the panel is on screen is immediate:
        // stopping freezes the tokens at the look they then have, and
        // re-enabling releases that snapshot so a later stop freezes the
        // tokens as they are then — each stop holds its own moment, never a
        // replay of an older look (Theme.release). The `opened` guard keeps
        // any snapshot from being taken at load, before the shell has read
        // the theme's files (Theme.qml owns that reasoning); onOpenedChanged
        // covers the path where the panel opens already following-off.
        if (root.opened) {
            if (root.followTheme) tokens.release()
            else tokens.freeze()
        }
        if (soundChanged && root.sound) root.resolveSoundFile()
        // External mode and preset edits take the same placement path as GUI
        // changes, including clamping a newly enlarged floating card.
        root.applyFloatingPosition()
    }

    function loadOverrides(text) {
        var result = ConfigFile.reloadOverrides(root.userOverrides, text)
        root.configurationError = result.error
        if (result.error) return
        root.userOverrides = result.value
        root.applyEffectiveSettings()
    }

    function loadState(text) {
        var result = ConfigFile.reloadState(root.geometryState, text)
        root.stateError = result.error
        if (result.error) return
        root.geometryState = result.value
        root.floatingCenter = result.value.center
        root.applyFloatingPosition()
    }

    // Missing files are a normal first run (§5): defaults stand, no error.
    // The FileViews are the only place that can tell a missing file from an
    // existing one — `text()` reads empty for both — so the distinction is
    // made here, on loadFailed, and the parse functions are only ever handed
    // text from a file that exists. An existing-but-unreadable file
    // (permissions, not a file) keeps the malformed semantics instead:
    // last valid runtime, inline error, no overwrite.
    function missingOverrides() {
        root.configurationError = ""
        root.userOverrides = {}
        root.applyEffectiveSettings()
    }

    function missingState() {
        root.stateError = ""
        root.geometryState = ConfigFile.stateDefaults()
        root.floatingCenter = null
        root.applyFloatingPosition()
    }

    // The apply-and-save tail every override write shares: publish the next
    // sparse map, let the reactive Theme resolution and the panel's own
    // settings follow from it, persist atomically. One home, so the write
    // path cannot drift between the controls that use it.
    function commitOverrides(next) {
        root.userOverrides = next
        root.applyEffectiveSettings()
        root.saveOverrides()
    }

    function setOverride(name, value) {
        // The health guard the popover's controls carry in their enabled
        // bindings, kept here as well: any caller — the bar's mode button, a
        // preset chip — stands down while a malformed external edit stands,
        // exactly as clearOverride does, instead of drifting the runtime
        // map away from a file every write would refuse to touch.
        if (!root.configHealthy) return
        var next = {}
        for (var key in root.userOverrides) next[key] = root.userOverrides[key]
        next[name] = value
        root.commitOverrides(next)
    }

    // Custom colour Apply: persist the override and put that hex in the
    // settings row. Swatches already write the field; Custom must too.
    function applyColourOverride(name, value) {
        root.setOverride(name, value)
        settingsPopover.adoptAppliedColour(name, value)
    }

    // The sparse override map stays behind the panel API: the popover's
    // views ask whether an override exists, they never inspect the map.
    function hasOverride(name) {
        return ConfigFile.owns(root.userOverrides, name)
    }

    // Per-override reset (spec-v1.1 §5): removing an override drops its key
    // from the sparse map, so the maintained default — or the live theme
    // token, while following — shows through again, and the next atomic
    // write leaves the file sparse. Refused while a malformed external edit
    // stands: the popover's chips are dimmed rather than offering resets
    // that could not persist.
    function clearOverride(name) {
        if (!root.configHealthy) return
        if (!ConfigFile.owns(root.userOverrides, name)) return
        var next = {}
        for (var key in root.userOverrides) {
            if (key !== name) next[key] = root.userOverrides[key]
        }
        root.commitOverrides(next)
    }

    // Reset-all (spec-v1.1 §5) empties the whole override map — every
    // setting, including the appearance fields the popover hosts and unknown
    // keys a future version wrote. The confirmation
    // is the popover's own inline arm/confirm row, not a system dialog; the
    // arm dies with the override map it was armed against
    // (onUserOverridesChanged) and with the popover itself
    // (onOpenedChanged).
    function clearAllOverrides() {
        if (!root.configHealthy) return
        settingsPopover.resetAllArmed = false
        root.commitOverrides({})
    }

    // Never replace malformed external text. Once the user fixes it, the
    // watched FileView reloads it and writes become available again.
    function saveOverrides() {
        if (root.configurationError) return
        configDirMaker.running = true
    }

    function saveState() {
        if (root.stateError) return
        stateDirMaker.running = true
    }

    function resolveSoundFile() {
        // Stop first: a Process that is already running ignores `running =
        // true` and would keep the previous lookup's command (see the same
        // dance in Keyboard.qml for the keycap pipeline). Optimistic until
        // the lookup answers: the row must not say "unavailable" while the
        // resolve is merely in flight.
        root.soundUnavailable = false
        soundResolve.running = false
        soundResolve.running = true
    }

    function playKeyClick() {
        var effect = clickSound.item
        if (effect) effect.play()
    }

    // Hooked to the state rather than to open/close/toggle, because the shell
    // can raise the panel by setting `opened` directly and those hooks would
    // never run.
    onOpenedChanged: {
        if (root.opened) {
            // With `follow_theme: false` the tokens are held at the look of
            // the moment that state began — a re-enable releases the held
            // snapshot, so this freezes fresh values again (Theme.qml owns
            // the why of here-not-at-load). freeze() no-ops while a snapshot
            // is already held, and no-ops entirely while following.
            if (!root.followTheme) tokens.freeze()
            root.refreshClipboardPreview()
            root.moveToPointerScreen(function (pointer, pointerScreen) {
                if (pointerScreen) panel.screen = pointerScreen
                root.applyFloatingPosition()
            })
            return
        }
        // A popover left open should not straddle the close: the next open
        // starts clean, and the reset-all confirmation is the popover's own
        // state, so it dies with it. The hex entry and the custom editor's
        // uncommitted draft die with it too — the focus exception and the
        // draft must never outlive the surface that sanctioned them.
        root.endHexEdit()
        root.closeCustomEditor()
        settingsPopover.visible = false
        settingsPopover.resetAllArmed = false
        // The picker session is the panel's too: with the panel gone there is
        // no band to keep the picker clear of. A managed Emote appearance is
        // dismissed with the panel so it cannot outlive the keyboard.
        if (root.pickerSession)
            root.settlePickerMachine(
                PickerSession.panelClosed(root.pickerSession, root.focusedAddress()))
        else
            root.endPickerSession()
        // Locked Shift is genuinely held down at the device, so closing the
        // panel has to let go of it before the keyboard disappears.
        keyboard.releaseModifiers()
    }

    // Reports {"x": n, "y": n} in compositor coordinates, which is the same
    // space Quickshell's screens are laid out in. A failure leaves the panel on
    // whatever output it already had rather than guessing at one.
    Process {
        id: hexClipboardRead
        command: ["wl-paste", "--no-newline"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.insertHexClipboard(this.text)
        }
    }

    // CLIPBOARD watch (spec-v1.1 §1): event-driven, not a poll. --watch
    // fires on each change; open and paste click still do a one-shot
    // refresh because --watch does not always emit the current value.
    Process {
        id: clipboardWatch
        running: root.opened
        command: ["wl-paste", "--watch", "echo", "."]
        stdout: SplitParser {
            onRead: function () { root.refreshClipboardPreview() }
        }
    }

    Process {
        id: clipboardTypes
        property int seq: 0
        command: ["wl-paste", "--list-types"]
        stdout: StdioCollector {
            id: clipboardTypesOut
            waitForEnd: true
        }
        onExited: function (exitCode) {
            root.applyClipboardTypes(clipboardTypesOut.text, clipboardTypes.seq, exitCode)
        }
    }

    Process {
        id: clipboardText
        property int seq: 0
        command: ["wl-paste", "--no-newline"]
        stdout: StdioCollector {
            id: clipboardTextOut
            waitForEnd: true
        }
        onExited: function (exitCode) {
            root.applyClipboardText(clipboardTextOut.text, clipboardText.seq,
                exitCode === 0)
        }
    }

    Process {
        id: cursorProbe
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var action = root.pendingScreenAction
                root.pendingScreenAction = null
                if (!action) return
                var pointer
                try {
                    pointer = JSON.parse(text)
                } catch (error) {
                    return
                }
                if (!pointer || typeof pointer.x !== "number" || typeof pointer.y !== "number") return
                action(pointer, root.screenAt(pointer.x, pointer.y))
            }
        }
    }

    // The FileViews above load their files synchronously at creation, so the
    // parsed overrides and state are already applied by the time this runs.
    Component.onCompleted: {
        root.checkDependencies()
        emojiPickerDetect.running = true
    }

    // Blocking, atomic writes leave either the old file or the complete new
    // one. FileView's change notification gives external editors an immediate
    // reload path without a timer. blockLoading makes the first load
    // synchronous at creation, so onLoaded/onLoadFailed have both run before
    // Component.onCompleted — the initial state is settled there, and no
    // separate text() read is wanted (a missing file would read as empty and
    // masquerade as a truncated one).
    FileView {
        id: configFile
        path: root.configPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.loadOverrides(text())
        onLoadFailed: function (error) {
            if (error === FileViewError.FileNotFound) root.missingOverrides()
            else root.configurationError = FileViewError.toString(error)
        }
    }

    FileView {
        id: stateFile
        path: root.statePath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.loadState(text())
        onLoadFailed: function (error) {
            if (error === FileViewError.FileNotFound) root.missingState()
            else root.stateError = FileViewError.toString(error)
        }
    }

    Process {
        id: configDirMaker
        command: ["mkdir", "-p", root.configDir]
        onExited: function(exitCode, exitStatus) {
            if (root.configurationError) return
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("[osk] could not create", root.configDir, "- configuration not saved")
                return
            }
            configFile.setText(ConfigFile.serializeOverrides(root.userOverrides))
        }
    }

    Process {
        id: stateDirMaker
        command: ["mkdir", "-p", root.stateDir]
        onExited: function(exitCode, exitStatus) {
            if (root.stateError) return
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("[osk] could not create", root.stateDir, "- state not saved")
                return
            }
            stateFile.setText(ConfigFile.serializeState(root.geometryState))
        }
    }

    // Resolves the freedesktop sound theme's file for the click and transcodes
    // it to PCM, exactly once, when the sound is on at startup — never per
    // keystroke. The theme ships Vorbis, and Qt's SoundEffect plays
    // uncompressed WAV only, so the copy in XDG_RUNTIME_DIR (tmpfs, gone at
    // logout) is what the effect actually plays: still the theme's sound, no
    // asset shipped, no taste to defend. Looked up through
    // XDG_DATA_HOME/XDG_DATA_DIRS like any theme consumer instead of
    // hardcoding /usr/share, with the event id and the search paths passed as
    // arguments so nothing from the environment is spliced into the command.
    // The event is the theme's `bell` — the sound Unix already attaches to
    // keys — chosen from the theme rather than defended as a taste.
    Process {
        id: soundResolve
        property string eventId: "bell"
        command: ["bash", "-c",
            "for base in ${2//:/ } ${3//:/ }; do "
            + "file=$base/sounds/freedesktop/stereo/$1.oga; "
            + "if [ -f \"$file\" ]; then "
            + "out=$4/omarchy-osk-keyclick.wav; "
            + "ffmpeg -nostdin -v error -y -i \"$file\" \"$out\" || exit 3; "
            + "printf '%s' \"$out\"; exit 0; "
            + "fi; "
            + "done; exit 1",
            "omarchy-osk-sound", soundResolve.eventId,
            Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"),
            Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share",
            Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.soundUnavailable = false
                root.soundFile = text.trim()
            }
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 1) {
                root.soundUnavailable = true
                console.warn("[osk] no '" + soundResolve.eventId
                    + "' event found in the freedesktop sound theme; the key click stays silent")
                return
            }
            if (exitCode !== 0 || exitStatus !== 0) {
                root.soundUnavailable = true
                console.warn("[osk] could not decode the '" + soundResolve.eventId
                    + "' event sound; the key click stays silent")
                return
            }
            console.log("[osk] key click sound:", root.soundFile)
        }
    }

    // The click effect lives behind a Loader so a system without
    // qt6-multimedia loses only the sound: a bare `import QtMultimedia` in
    // the panel would refuse to load the whole component instead.
    Loader {
        id: clickSound
        active: root.sound && root.soundFile !== ""
        source: "KeyClickSound.qml"
        onLoaded: item.filePath = root.soundFile
        onStatusChanged: {
            if (status === Loader.Error) {
                root.soundUnavailable = true
                console.warn("[osk] QtMultimedia is not available; the key click sound stays off")
            }
        }
    }

    Process {
        id: dependencyCheck
        // Typing goes through the helper daemon, which has no external
        // commands to check for. The layout tracker still needs hyprctl
        // (devices, getoption), jq (devices JSON), xkbcli (compiling the key
        // caps' symbols), and udevadm (event-driven input hotplug); all come
        // with the packages the install
        // button below pulls in.
        command: ["bash", "-c",
            "command -v hyprctl >/dev/null && command -v jq >/dev/null && command -v xkbcli >/dev/null && command -v udevadm >/dev/null"]
        onExited: function(exitCode, exitStatus) {
            root.dependenciesReady = exitCode === 0 && exitStatus === 0
        }
    }

    Process {
        id: dependencyInstall
        command: ["xdg-terminal-exec", "--app-id=org.omarchy.terminal",
            "--title=Install On-Screen Keyboard dependencies", "omarchy", "pkg",
            "add", "hyprland", "jq"]
        onExited: function(exitCode, exitStatus) {
            root.dependenciesReady = false
            root.checkDependencies()
        }
    }

    // The PATH probe behind the popover's Emoji app row: which of the known
    // pickers this system could actually launch. Gathered once at load, in
    // the same one-shot shape as the dependency check — no poll. The row
    // offers what this finds; the override itself may still name any app (an
    // external edit), and the ☺ click's probe is the authority either way.
    Process {
        id: emojiPickerDetect
        command: ["bash", "-c",
            "for name in \"$@\"; do command -v \"$name\" >/dev/null 2>&1 && printf '%s\\n' \"$name\"; done",
            "omarchy-osk-emoji-detect"].concat(root.emojiPickerCandidates)
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.detectedEmojiPickers = text.split("\n").filter(function (line) {
                    return line.trim() !== ""
                })
            }
        }
    }

    // ---- picker fitting (spec-v1.1 §1; ticket 08) ----
    //
    // A picker opened from the ☺ cap must open in a usable nearby region on
    // this output and STAY clear while panel or picker geometry changes. The
    // owner-settled policy (ticket 08 Comments) is PickerFit.planPlacement:
    // above the keyboard first — shorter, scrollable, if the picker is
    // taller than the space — then a fitting side region; where the app's
    // minimum size prevents every region from fitting, the panel says so
    // (pickerFitConstraint, the header hint) instead of declaring an
    // overlapping placement a success.
    //
    // One logical coordinate system: Quickshell's screens, `hyprctl clients`
    // at/size and the move/resize dispatchers all speak compositor layout
    // units on the inspected stack (scale 2 included — the old divide-by-DPR
    // here was the demonstrated defect; PickerFit.js records the one
    // remaining physical-unit field, monitors -j width/height). No polling:
    // the watch rides the compositor's event stream and the panel's own
    // geometry notifications, with bounded one-shot settle timers, and moves
    // only the one window the session identified. Hyprland 0.56.2 has no
    // client-geometry event, so a picker-initiated resize is noticed on the
    // next panel/output event or the dispatch-verify timer.
    property string pickerFitConstraint: ""
    // One identified appearance: the configured app, the window classes it
    // may map as, the pinned address once found, and the attempt history
    // that keeps a stubborn placement from looping forever. Null while no
    // picker from the ☺ cap is being watched.
    property var pickerSession: null
    property var pickerHandoffPending: null
    // Stamped onto each observe so a result cannot identify a window for
    // a session that started after the query left. beginPickerSession
    // bumps it; a stale exit is dropped.
    property int pickerQueryGen: 0

    function pickerBand(mon) {
        var s = panel.screen
        if (!s) return null
        if (root.mode === "docked") {
            // Hyprland stacks a bottom-anchored Overlay above any existing
            // bottom exclusive zone, so the strip is the top of that stack
            // rather than the output's bottom edge. reserved[3] is logical.
            var output = mon
                ? PickerFit.logicalMonitorBox(mon)
                : { x: s.x, y: s.y, w: s.width, h: s.height }
            var bottom = (mon && mon.reserved && mon.reserved[3]) ? mon.reserved[3] : 0
            return PickerFit.dockedBand(output, root.cardHeight, bottom)
        }
        // Floating: the card is the band, wherever the drag left it.
        return { x: s.x + card.x, y: s.y + card.y, w: card.width, h: card.height }
    }

    // The ☺ cap arms one session before execDetached. Emote is a managed
    // toggle (PickerSession.js): a second press closes the identified
    // window. Unmanaged apps still launch and the newest launch owns the
    // fit watch.
    function focusedClient() {
        var top = Hyprland.activeToplevel
        if (!top || !top.lastIpcObject) return null
        var obj = top.lastIpcObject
        var addr = String(obj.address || "")
        if (!addr) return null
        return { address: addr, className: String(obj["class"] || "") }
    }

    function focusedAddress() {
        var client = root.focusedClient()
        return client ? client.address : ""
    }

    function beginPickerSession(app, machine) {
        if (!panel.screen) return
        var created = machine || PickerSession.create(app, root.focusedClient())
        root.pickerSession = {
            app: app,
            classes: PickerFit.resolveClasses(app, ""),
            address: created.address || "",
            opened: [],
            seen: [],
            probeSettled: false,
            gen: 0,
            attempts: 0,
            cycleKey: "",
            settled: false,
            settleTries: 0,
            pickerMin: null,
            lastTarget: null,
            pendingResize: false,
            phase: created.phase,
            managed: created.managed,
            kind: created.kind || "client",
            target: created.target,
            stayApplied: created.stayApplied,
            cancelMap: created.cancelMap,
            oskPayload: null
        }
        root.pickerQueryGen += 1
        root.pickerSession.gen = root.pickerQueryGen
        root.pickerFitConstraint = ""
        if (root.pickerSession.kind !== "shell") {
            emojiIdentity.app = app
            emojiIdentity.gen = root.pickerSession.gen
            emojiIdentity.running = false
            emojiIdentity.running = true
        }
        emojiPlaceTimeout.restart()
        root.requestPickerFit()
    }

    function handleEmojiCap(app) {
        var session = root.pickerSession
        var current = root.focusedAddress()
        var target = root.focusedClient()
        if (session && session.address && PickerFit.sameAddress(current, session.address))
            target = session.target
        var result = PickerSession.capPressed(session, app, target, current)
        var launched = false
        for (var i = 0; i < result.actions.length; i++) {
            if (result.actions[i].op === "launch"
                || result.actions[i].op === "shellSummon")
                launched = true
        }
        if (launched)
            root.beginPickerSession(app, result.session)
        else
            root.pickerSession = result.session
        root.playPickerActions(result.actions)
        if (PickerSession.rearmCloser(root.pickerSession))
            emojiPlaceTimeout.restart()
    }

    function oskPayloadFromScreen(mon) {
        var s = panel.screen
        if (!s) return null
        var output = mon
            ? PickerFit.logicalMonitorBox(mon)
            : { x: s.x, y: s.y, w: s.width, h: s.height }
        var band = root.pickerBand(mon)
        if (!band) return null
        var workArea = mon
            ? PickerFit.workAreaOf(mon)
            : {
                x: output.x,
                y: output.y,
                w: output.w,
                h: Math.max(0, band.y - output.y)
            }
        return PickerFit.oskPayload(band, output, workArea)
    }

    function playShellPicker(op) {
        var session = root.pickerSession
        var method = "summon"
        var payload = "{}"
        if (op === "shellHide") {
            method = "hide"
        } else if (op === "shellFit") {
            method = "fit"
            payload = session && session.oskPayload
                ? JSON.stringify(session.oskPayload) : ""
            if (!payload || payload === "{}") {
                root.requestPickerFit()
                return
            }
        } else {
            var geom = session && session.oskPayload
                ? session.oskPayload : root.oskPayloadFromScreen()
            if (geom) {
                if (session) session.oskPayload = geom
                payload = JSON.stringify(geom)
            }
        }
        if (shellPickerIpc.running) {
            shellPickerIpc.queued = { method: method, payload: payload }
            return
        }
        shellPickerIpc.queued = null
        shellPickerIpc.method = method
        shellPickerIpc.payload = payload
        shellPickerIpc.running = false
        shellPickerIpc.running = true
    }

    function playPickerActions(actions) {
        if (!actions || !actions.length) return
        var windowActions = []
        for (var i = 0; i < actions.length; i++) {
            var op = actions[i].op
            if (op === "shellSummon" || op === "shellHide" || op === "shellFit")
                root.playShellPicker(op)
            else
                windowActions.push(actions[i])
        }
        if (!windowActions.length) return
        var plan = PickerSession.queueHandoff({
            running: pickerHandoff.running,
            closeWin: pickerHandoff.closeWin,
            pending: root.pickerHandoffPending
        }, windowActions)
        for (var i = 0; i < plan.launches.length; i++)
            Quickshell.execDetached([plan.launches[i].app])
        if (!plan.start) {
            if (plan.pending) root.pickerHandoffPending = plan.pending
            return
        }
        var handoff = plan.handoff
        if (!handoff) return
        root.pickerHandoffPending = null
        pickerHandoff.addr = handoff.addr
        pickerHandoff.stay = handoff.stay
        pickerHandoff.closeWin = handoff.closeWin
        pickerHandoff.focusAddr = handoff.focusAddr
        pickerHandoff.running = false
        pickerHandoff.running = true
    }

    function settlePickerMachine(result) {
        if (!result) return
        root.playPickerActions(result.actions)
        if (!result.session || result.session.phase === "closed")
            root.endPickerSession()
        else if (result.session.phase === "open")
            emojiPlaceTimeout.stop()
        else if (PickerSession.rearmCloser(result.session))
            emojiPlaceTimeout.restart()
    }

    function endPickerSession() {
        root.pickerHandoffPending = null
        shellPickerIpc.queued = null
        if (!root.pickerSession) return
        root.pickerSession = null
        root.pickerFitConstraint = ""
        emojiPlaceTimeout.stop()
        pickerFitDebounce.stop()
        pickerSettleTimer.stop()
        pickerVerifyTimer.stop()
    }

    // Every recompute path funnels here. The one-shot debounce coalesces
    // event storms (a drag fires dozens of moves) into one observation when
    // the geometry stops moving — bounded settling, not polling.
    function requestPickerFit() {
        if (!root.pickerSession) return
        pickerFitDebounce.restart()
    }

    function runPickerFit() {
        var session = root.pickerSession
        var s = panel.screen
        var band = root.pickerBand()
        if (!session || !s || !band) return
        emojiObserve.monName = s.name || ""
        emojiObserve.centerX = Math.round(band.x + band.w / 2)
        emojiObserve.centerY = Math.round(band.y + band.h / 2)
        emojiObserve.classes = session.classes.join(",")
        // An event landing while a query is in flight is not dropped: it
        // queues exactly one re-run, consumed when the query exits. Do not
        // stamp gen until this process actually starts, or a stale exit
        // would inherit the new session's generation.
        if (emojiObserve.running) {
            emojiObserve.queued = true
            return
        }
        emojiObserve.queued = false
        emojiObserve.gen = session.gen
        emojiObserve.running = true
    }

    function handlePickerObservation(json) {
        var session = root.pickerSession
        if (!session || !json || !json.monitor) return
        var band = root.pickerBand(json.monitor)
        if (!band) return

        if (session.kind === "shell") {
            var payload = root.oskPayloadFromScreen(json.monitor)
            if (payload) session.oskPayload = payload
            var natural = { x: 0, y: 0, w: 400, h: 500 }
            var plan = PickerFit.overlayCardPlan(payload, natural, session.pickerMin)
            if (!plan || plan.status === "unfit") {
                root.pickerFitConstraint = session.app
                if (plan)
                    console.warn("[osk] overlay cannot fit clear of the keyboard:",
                        plan.reason)
            } else if (root.pickerFitConstraint !== "") {
                root.pickerFitConstraint = ""
            }
            if (session.phase === "open")
                root.playPickerActions(PickerSession.fitActions(session))
            return
        }

        var client = PickerFit.pickClient(json.clients, session.address, session.opened)
        if (!client) {
            // Nothing mapped under the accepted classes: the watch stays
            // armed for the openwindow event until the hard timeout. A
            // PINNED address that has gone is a close of the appearance
            // (selection, Escape, or our closewindow).
            if (session.address !== "")
                root.settlePickerMachine(
                    PickerSession.closed(session, session.address, root.focusedAddress()))
            return
        }

        if (session.phase === "closing")
            return

        if (session.address === "") {
            var mapped = PickerSession.mapped(session, client.address)
            root.settlePickerMachine(mapped)
            if (session.phase !== "open") return
            emojiPlaceTimeout.stop()
        } else if (!PickerFit.sameAddress(session.address, client.address)) {
            var adopted = PickerSession.mapped(session, client.address)
            root.playPickerActions(adopted.actions)
            if (session.phase !== "open") return
            session.attempts = 0
            session.settled = false
            session.pickerMin = null
            session.lastTarget = null
            session.pendingResize = false
            session.settleTries = 0
        }

        var rect = {
            x: client.at[0], y: client.at[1],
            w: client.size[0], h: client.size[1]
        }
        if (PickerFit.needsSettling(rect)) {
            // A freshly mapped window can answer 0x0 before its first
            // commit settles. One bounded re-check covers it even if no
            // further compositor event arrives; the plan runs on real
            // geometry only. After five zero observations the hard
            // timeout has already been stopped, so end rather than stall.
            if (session.settleTries >= 5) {
                console.warn("[osk] picker geometry never settled")
                root.settlePickerMachine(
                    PickerSession.closed(session, session.address, root.focusedAddress()))
                return
            }
            if (!pickerSettleTimer.running) {
                session.settleTries += 1
                pickerSettleTimer.restart()
            }
            return
        }
        session.settleTries = 0

        // A requested shrink that did not happen records the picker's real
        // minimum: the next plan stops offering the shorter above-region
        // and the side regions are measured against it.
        if (session.pendingResize) {
            session.pendingResize = false
            if (session.lastTarget && rect.h > session.lastTarget.h + 2)
                session.pickerMin = { w: rect.w, h: rect.h }
        }

        var plan = PickerFit.planPlacement({
            output: PickerFit.logicalMonitorBox(json.monitor),
            workArea: PickerFit.workAreaOf(json.monitor),
            band: band,
            picker: rect,
            pickerMin: session.pickerMin
        })

        if (plan.status === "unfit") {
            // Minimum size beats every region: say so, move nothing, keep
            // watching — a panel or output change can still make it
            // fit later, and the hint clears the moment a plan fits.
            root.pickerFitConstraint = session.app
            console.warn("[osk] picker cannot fit clear of the keyboard:", plan.reason)
            return
        }
        if (root.pickerFitConstraint !== "") root.pickerFitConstraint = ""

        // A new band or work area (panel drag, dock/float, preset, output)
        // starts a fresh convergence cycle. Size-chasing — a stubborn
        // client whose observed size changes the plan target after each
        // dispatch — keeps burning the same cycle's cap.
        var cycleKey = PickerFit.placementCycleKey(band, PickerFit.workAreaOf(json.monitor))
        session.attempts = PickerFit.nextAttempts(session.attempts, session.cycleKey, cycleKey)
        session.cycleKey = cycleKey

        if (PickerFit.sameRect(rect, plan.target, 2)) {
            if (!session.settled) {
                session.settled = true
                console.log("[osk] picker placed", plan.region,
                    JSON.stringify(plan.target), "on", json.monitor.name)
            }
            return
        }

        if (session.attempts >= 3) {
            // Three dispatches in this band/work-area cycle moved nothing:
            // positioning failed, and an overlapping placement must not
            // pass for success.
            root.pickerFitConstraint = session.app
            console.warn("[osk] picker did not move to",
                JSON.stringify(plan.target), "after", session.attempts, "attempts")
            return
        }

        session.attempts += 1
        session.lastTarget = plan.target
        session.pendingResize = plan.resized
        pickerDispatch.addr = client.address
        pickerDispatch.needFloat = !client.floating
        pickerDispatch.tx = Math.round(plan.target.x)
        pickerDispatch.ty = Math.round(plan.target.y)
        pickerDispatch.rw = plan.resized ? Math.round(plan.target.w) : 0
        pickerDispatch.rh = plan.resized ? Math.round(plan.target.h) : 0
        pickerDispatch.running = false
        pickerDispatch.running = true
        // Our own move/resize dispatches emit no socket events on Hyprland
        // 0.56.2, so the one-shot timer re-observes the resulting rectangle.
        // Successful process exit alone is never treated as proof the
        // picker moved.
        pickerVerifyTimer.restart()
    }

    // One-shot: the configured app's desktop-entry StartupWMClass, so the
    // accepted window classes come from the entry's own declaration where
    // one exists. The executable name is only ever the fallback after this
    // probe exits (success or failure); until then opened stays empty so a
    // fallback-class map cannot steal the pin. The recorded table carries
    // the classes an app is known to surface on other stacks (PickerFit.js:
    // the installed Emote maps as "emote", its GTK application_id
    // com.tomjwatson.Emote is what other versions may report). Applies to
    // the live session whose generation the probe printed, so a stale prior
    // run cannot widen a newer session. No poll.
    Process {
        id: emojiIdentity
        property string app: ""
        property int gen: 0
        command: ["bash", "-c",
            "printf '%s\\n' \"$1\"\n"
          + "app=$2\n"
          + "for base in ${3//:/ } ${4//:/ }; do\n"
          + "  for f in \"$base\"/applications/*.desktop; do\n"
          + "    [ -f \"$f\" ] || continue\n"
          + "    cls=$(awk -F= -v app=\"$app\" '\n"
          + "      /^\\[Desktop Entry\\]$/ { inentry = 1; next }\n"
          + "      /^\\[/ { inentry = 0 }\n"
          + "      inentry && $1 == \"Exec\" { n = split($2, a, \" \");"
          + " sub(/.*\\//, \"\", a[1]); exec = (a[1] == app) }\n"
          + "      inentry && $1 == \"StartupWMClass\" { wm = $2 }\n"
          + "      END { if (exec) print wm }' \"$f\")\n"
          + "    [ -n \"$cls\" ] && { printf '%s' \"$cls\"; exit 0; }\n"
          + "  done\n"
          + "done\n"
          + "exit 1\n",
            "omarchy-osk-emoji-identity", String(emojiIdentity.gen), emojiIdentity.app,
            Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"),
            Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var session = root.pickerSession
                var lines = text.split("\n")
                var probeGen = parseInt(lines[0], 10)
                var wmClass = lines.slice(1).join("\n").trim()
                if (!session || session.gen !== probeGen) return
                session.probeSettled = true
                var merged = PickerFit.resolveClasses(session.app, wmClass, true)
                session.classes = merged
                session.opened = PickerFit.bindLaunch(
                    session.opened, session.seen, merged, true, session.app)
                if (session.cancelMap && session.opened.length)
                    root.settlePickerMachine(
                        PickerSession.mapped(session, session.opened[0]))
                else
                    // A class the first observation could not know about may
                    // already be mapped; re-run now that the accepted list grew.
                    root.requestPickerFit()
            }
        }
    }

    // ONE monitors+clients query per fit run — the query only GATHERS; the
    // decision is the pure PickerFit policy and the move is a separate
    // dispatch whose outcome the next observation verifies. Exit 0 always
    // carries the JSON (clients may be empty); 4/5 mean the compositor could
    // not answer yet — the event watch stays armed either way. Pin
    // preference lives in pickClient, not in the jq.
    Process {
        id: emojiObserve
        property string monName: ""
        property int centerX: 0
        property int centerY: 0
        property string classes: ""
        property int gen: 0
        property bool queued: false
        property string result: ""
        command: ["bash", "-c",
            "classes=$1; monName=$2; cx=$3; cy=$4\n"
          + "mons=$(hyprctl monitors -j 2>/dev/null) || exit 4\n"
          + "mon=$(printf '%s' \"$mons\" | jq -c --arg name \"$monName\" \\\n"
          + "    --argjson cx \"$cx\" --argjson cy \"$cy\" '\n"
          + "  (map(select(.name == $name))[0])\n"
          + "  // (map(select((.disabled != true) and (.x <= $cx)\n"
          + "                and ($cx < .x + .width / .scale)\n"
          + "                and (.y <= $cy) and ($cy < .y + .height / .scale)))[0])\n"
          + "  // null')\n"
          + "[[ -z \"$mon\" || \"$mon\" == \"null\" ]] && exit 5\n"
          + "hyprctl clients -j 2>/dev/null | jq -c --arg classes \"$classes\" \\\n"
          + "    --argjson mon \"$mon\" '\n"
          + "  ($classes | split(\",\")) as $want\n"
          + "  | [.[]\n"
          + "    | select(.mapped)\n"
          + "    | ((.class // \"\") | ascii_downcase) as $c\n"
          + "    | ((.initialClass // \"\") | ascii_downcase) as $ic\n"
          + "    | select(($want | index($c)) != null or ($want | index($ic)) != null)\n"
          + "    | {address: .address, at: .at, size: .size, floating: .floating,\n"
          + "       focusHistoryID: .focusHistoryID}]\n"
          + "  | {monitor: $mon, clients: .}'\n",
            "omarchy-osk-emoji-observe",
            emojiObserve.classes, emojiObserve.monName,
            String(emojiObserve.centerX), String(emojiObserve.centerY)]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: emojiObserve.result = text
        }
        onExited: function(exitCode) {
            var again = emojiObserve.queued
            emojiObserve.queued = false
            var session = root.pickerSession
            if (exitCode === 0) {
                if (session && session.gen === emojiObserve.gen)
                    root.handlePickerObservation(emojiObserve.parsed())
            } else if (exitCode !== 4 && exitCode !== 5)
                console.warn("[osk] picker observation failed with exit", exitCode)
            emojiObserve.result = ""
            if (again && root.pickerSession) root.runPickerFit()
        }
        function parsed() {
            try {
                return JSON.parse(emojiObserve.result)
            } catch (error) {
                return null
            }
        }
    }

    // The placement dispatch: float the identified window if it mapped
    // tiled (a picker tiled into the layout cannot be positioned), resize
    // first when the plan shrinks it (shorter/scrollable), then move.
    // Runtime dispatches of the one window the session owns — never a
    // config write, never another window. The Lua dispatcher form is what
    // the running compositor accepts (the pre-0.56 CLI dispatcher is gone
    // under the Lua parser, the same quirk the cursor-hide probe records
    // for `hyprctl keyword`).
    Process {
        id: pickerDispatch
        property string addr: ""
        property bool needFloat: false
        property int tx: 0
        property int ty: 0
        property int rw: 0
        property int rh: 0
        command: ["bash", "-c",
            "addr=$1; tx=$2; ty=$3; rw=$4; rh=$5; flt=$6\n"
          + "if [[ $flt == 1 ]]; then\n"
          + "  hyprctl eval \"hl.dispatch(hl.dsp.window.float({ window = \\\"address:$addr\\\", action = \\\"set\\\" }))\" >/dev/null 2>&1 || exit 1\n"
          + "fi\n"
          + "if (( rw > 0 && rh > 0 )); then\n"
          + "  hyprctl eval \"hl.dispatch(hl.dsp.window.resize({ window = \\\"address:$addr\\\", x = $rw, y = $rh, relative = false }))\" >/dev/null 2>&1 || exit 2\n"
          + "fi\n"
          + "hyprctl eval \"hl.dispatch(hl.dsp.window.move({ window = \\\"address:$addr\\\", x = $tx, y = $ty, relative = false }))\" >/dev/null 2>&1 || exit 3\n"
          + "exit 0",
            "omarchy-osk-emoji-dispatch",
            pickerDispatch.addr,
            String(pickerDispatch.tx), String(pickerDispatch.ty),
            String(pickerDispatch.rw), String(pickerDispatch.rh),
            pickerDispatch.needFloat ? "1" : "0"]
        onExited: function(exitCode) {
            if (exitCode !== 0)
                console.warn("[osk] picker dispatch failed with exit", exitCode)
        }
    }

    // Runtime policy for the identified appearance only: stay_focused on
    // that address, closewindow of that address, restore the recorded
    // target. Never a class-wide rule, never pkill.
    Process {
        id: pickerHandoff
        property string addr: ""
        property string stay: ""
        property bool closeWin: false
        property string focusAddr: ""
        command: ["bash", "-c",
            "addr=$1; stay=$2; close=$3; focus=$4\n"
          + "stay_rc=0; close_rc=0; focus_rc=0\n"
          + "if [[ -n $stay ]]; then\n"
          + "  hyprctl eval \"hl.dispatch(hl.dsp.window.set_prop({ window = \\\"address:$addr\\\", prop = \\\"stay_focused\\\", value = \\\"$stay\\\" }))\" >/dev/null 2>&1 || stay_rc=1\n"
          + "fi\n"
          + "if [[ $close == 1 ]]; then\n"
          + "  hyprctl eval \"hl.dispatch(hl.dsp.window.close({ window = \\\"address:$addr\\\" }))\" >/dev/null 2>&1 || close_rc=1\n"
          + "fi\n"
          + "if [[ -n $focus ]]; then\n"
          + "  hyprctl eval \"hl.dispatch(hl.dsp.focus({ window = \\\"address:$focus\\\" }))\" >/dev/null 2>&1 || focus_rc=1\n"
          + "fi\n"
          + "if (( close_rc != 0 )); then exit 2; fi\n"
          + "if (( stay_rc != 0 )); then exit 1; fi\n"
          + "if (( focus_rc != 0 )); then exit 3; fi\n"
          + "exit 0",
            "omarchy-osk-picker-handoff",
            pickerHandoff.addr, pickerHandoff.stay,
            pickerHandoff.closeWin ? "1" : "0", pickerHandoff.focusAddr]
        onExited: function(exitCode) {
            if (exitCode !== 0)
                console.warn("[osk] picker handoff failed with exit", exitCode)
            var session = root.pickerSession
            var pending = root.pickerHandoffPending
            root.pickerHandoffPending = null
            if (session && session.phase === "closing" && exitCode !== 0) {
                root.settlePickerMachine(
                    PickerSession.failed(session, root.focusedAddress()))
                return
            }
            if (pending && (pending.stay || pending.closeWin || pending.focusAddr))
                root.playPickerActions(PickerSession.handoffActions(pending))
        }
    }

    // Shell overlay open/hide/fit. Summon is not a blind toggle: if the
    // overlay is already open (standalone Super+Period), hide it. Ordinary
    // `omarchy-menu-emoji` without an OSK payload is unchanged.
    Process {
        id: shellPickerIpc
        property string method: "summon"
        property string payload: "{}"
        property var queued: null
        property string result: ""
        command: shellPickerIpc.method === "hide"
            ? ["omarchy-shell", "shell", "hide", "omarchy.emojis"]
            : shellPickerIpc.method === "fit"
                ? ["omarchy-shell", "shell", "call", "omarchy.emojis", "oskFit",
                    shellPickerIpc.payload]
                : ["bash", "-c",
                    "payload=$1\n"
                  + "state=$(omarchy-shell shell isOpen omarchy.emojis 2>/dev/null || echo closed)\n"
                  + "if [[ $state == open ]]; then\n"
                  + "  omarchy-shell shell hide omarchy.emojis\n"
                  + "  printf dismissed\n"
                  + "  exit 0\n"
                  + "fi\n"
                  + "omarchy-shell shell summon omarchy.emojis \"$payload\" || exit 2\n"
                  + "printf summoned\n",
                    "omarchy-osk-shell-summon", shellPickerIpc.payload]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: shellPickerIpc.result = text
        }
        onExited: function(exitCode) {
            var queued = shellPickerIpc.queued
            shellPickerIpc.queued = null
            var session = root.pickerSession
            var out = String(shellPickerIpc.result || "").trim()
            shellPickerIpc.result = ""
            if (shellPickerIpc.method === "summon" && session) {
                if (out.indexOf("dismissed") === 0)
                    root.settlePickerMachine(
                        PickerSession.overlayClosed(session, root.focusedAddress()))
                else if (exitCode === 0)
                    root.settlePickerMachine(PickerSession.overlayOpened(session))
                else
                    root.settlePickerMachine(
                        PickerSession.failed(session, root.focusedAddress()))
            } else if (shellPickerIpc.method === "hide" && session) {
                if (exitCode !== 0 && session.phase === "closing")
                    root.settlePickerMachine(
                        PickerSession.failed(session, root.focusedAddress()))
                else if (exitCode === 0)
                    root.settlePickerMachine(
                        PickerSession.overlayClosed(session, root.focusedAddress()))
            }
            if (queued) {
                shellPickerIpc.method = queued.method
                shellPickerIpc.payload = queued.payload
                shellPickerIpc.running = false
                shellPickerIpc.running = true
            }
        }
    }

    // The single hard timeout bounding the INITIAL watch and a cancelled
    // or slow close. Stopped the moment an address is pinned open; re-armed
    // while closing only once that address is known, so mashing ☺ cannot
    // postpone a pinless closer. A shell overlay is opened by IPC, not a
    // client map; overlayOpened stops this timer.
    Timer {
        id: emojiPlaceTimeout
        interval: 6000
        repeat: false
        onTriggered: {
            if (!root.pickerSession) return
            var late = (root.pickerSession.opened && root.pickerSession.opened.length)
                ? root.pickerSession.opened[0] : ""
            root.settlePickerMachine(
                PickerSession.timeout(root.pickerSession, root.focusedAddress(), late))
        }
    }

    // Bounded one-shots: the debounce coalesces geometry-change storms, the
    // settle re-check covers zero/unstable initial geometry, and the verify
    // re-observation checks a dispatch's resulting rectangle when no
    // compositor event lands. None repeats.
    Timer {
        id: pickerFitDebounce
        interval: 150
        repeat: false
        onTriggered: root.runPickerFit()
    }
    Timer {
        id: pickerSettleTimer
        interval: 300
        repeat: false
        onTriggered: root.runPickerFit()
    }
    Timer {
        id: pickerVerifyTimer
        interval: 350
        repeat: false
        onTriggered: root.requestPickerFit()
    }

    // The compositor's event stream drives the watch: no polling. Every
    // openwindow is remembered; launch identity is bound once after the
    // class probe settles, never recomputed from later maps. closewindow
    // and title/float events filter on the pinned address. Monitor/config
    // events cover output removal and scale changes. Addresses are
    // compared through PickerFit.sameAddress: the socket omits the 0x
    // prefix that clients -j includes. eventAction drops movewindow(v2)
    // (workspace move) and the absent resizewindow(v2).
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            var session = root.pickerSession
            if (!session || !event) return
            var fields = String(event.data || "").split(",")
            var action = PickerFit.eventAction(event.name)
            if (action === "open") {
                session.seen = PickerFit.rememberOpenwindow(session.seen, fields[0], fields[2] || "")
                var wasEmpty = !session.opened || session.opened.length === 0
                session.opened = PickerFit.bindLaunch(
                    session.opened, session.seen, session.classes,
                    session.probeSettled, session.app)
                if (wasEmpty && session.opened.length) {
                    if (session.cancelMap)
                        root.settlePickerMachine(
                            PickerSession.mapped(session, session.opened[0]))
                    else
                        root.requestPickerFit()
                }
                return
            }
            if (action === "close") {
                var rebound = PickerFit.rebindAfterClose(
                    session.opened, session.seen, fields[0],
                    session.classes, session.probeSettled, session.app)
                session.seen = rebound.seen
                session.opened = rebound.opened
                if (PickerFit.sameAddress(fields[0], session.address)) {
                    root.settlePickerMachine(
                        PickerSession.closed(session, fields[0], root.focusedAddress()))
                    return
                }
                if (!session.address && session.opened.length)
                    root.requestPickerFit()
                return
            }
            if (action === "refit") {
                if (PickerFit.sameAddress(fields[0], session.address))
                    root.requestPickerFit()
                return
            }
            if (action === "output")
                root.requestPickerFit()
            if (session.kind === "shell" && String(event.data || "") === "omarchy-emojis") {
                if (action === "layerOpen")
                    root.settlePickerMachine(PickerSession.overlayOpened(session))
                else if (action === "layerClose")
                    root.settlePickerMachine(
                        PickerSession.overlayClosed(session, root.focusedAddress()))
            }
        }
    }

    // The height the docked strip needs. In docked mode it is also the
    // window's height and therefore the space the compositor reserves for it;
    // in floating mode the window is anchored to all four edges and the
    // compositor sizes it, so the property is ignored there.
    readonly property real cardHeight: keyboard.implicitHeight + keyboard.gapPx * 2 + dragBar.height
        + (dependencyNotice.visible ? dependencyNotice.height + keyboard.gapPx : 0)
        + tokens.popupPadding / 2

    PanelWindow {
        id: panel
        visible: root.opened
        // Docked releases the top edge so the window is exactly the strip at
        // the bottom and its height (and with it the reserved space) follows
        // the keyboard; floating keeps the full-screen transparent overlay
        // the card is dragged around in.
        anchors {
            top: root.mode !== "docked"
            bottom: true
            left: true
            right: true
        }
        implicitHeight: root.cardHeight
        color: "transparent"
        mask: Region {
            item: card
        }

        // The surface has no size until it is mapped, and it changes size again
        // when the panel moves to an output of a different shape — both of
        // which are when a remembered floating position has to be re-applied
        // and re-clamped. The picker session re-fits on the same signals: a
        // panel resize (preset, output shape) is a geometry change it must
        // answer.
        onWidthChanged: {
            root.applyFloatingPosition()
            root.requestPickerFit()
        }
        onHeightChanged: {
            root.applyFloatingPosition()
            root.requestPickerFit()
        }
        // An output change (the drag-to-monitor handoff in finishDrag, or
        // the output itself going away) moves the band and the work area
        // the picker is fitted against.
        onScreenChanged: root.requestPickerFit()

        // Never take keyboard focus: the app being typed into keeps it, and
        // the helper's keystrokes land there. Colour-field entry is the one
        // exception, and it lives on the settings overlay, not here.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "io.github.vladkarok.osk"
        WlrLayershell.layer: WlrLayer.Overlay
        // Docked reserves its height along the bottom edge — windows move up
        // rather than being covered, and closing the panel hands the space
        // back (a hidden layer surface reserves nothing). Fullscreen windows
        // ignore layer-shell exclusive zones, so a fullscreen film is
        // overlaid instead; that is the accepted behaviour, not a bug.
        // Floating reserves nothing, exactly as before.
        //
        // The reservation is exact by construction, never transiently wrong
        // (spec-v1.1 §4): ExclusionMode.Auto derives the zone from this
        // window's own geometry, the bottom anchor keeps the window's bottom
        // edge fixed while `implicitHeight` rebinds, and the layer-shell
        // surface commits the new size and its zone together — so at every
        // commit the reserved space equals the visible strip, and a preset
        // change moves the top edge only. Non-fullscreen tiled windows can
        // therefore never sit under the visible panel; whether a client
        // keeps its internal bottom scroll on resize is its own policy
        // (decisions §21).
        exclusionMode: root.mode === "docked" ? ExclusionMode.Auto : ExclusionMode.Ignore

        // Mirrors the reference `.keyboard-container`: solid panel
        // background, subtle border, and padding equal to the key gap.
        // Corner rounding follows Omarchy's shared style token — except when
        // docked, where the strip is flush against the bottom edge of the
        // output and two rounded corners would cut visible notches out of a
        // full-width bar; docked is flat.
        // No title bar — the reference has none; its ✕ lives in the
        // key grid itself.
        BorderSurface {
            id: card
            width: root.mode === "docked" ? panel.width
                : Math.min(panel.width - tokens.popupPadding, keyboard.implicitWidth + keyboard.gapPx * 2) + tokens.popupPadding
            height: root.cardHeight
            x: (panel.width - width) / 2
            y: panel.height - height - tokens.spacingLg
            radius: root.mode === "docked" ? 0 : tokens.panelRadius
            color: tokens.panelBackground
            borderSpec: tokens.cardBorderSpec

            // Docked pins the card into the strip it fills. Re-asserted here
            // rather than bound inline, because dragging in floating mode
            // writes x/y directly and destroys whatever binding was there —
            // a plain inline binding would leave the docked strip stranded
            // wherever it was last dragged.
            Binding { target: card; property: "x"; value: 0; when: root.mode === "docked" }
            Binding { target: card; property: "y"; value: 0; when: root.mode === "docked" }

            // A preset or theme change resizes the floating card through a
            // chain of bindings (scale, gaps, grid layout) that settles only
            // after the chooser's synchronous re-derivation has run, so the
            // anchored top-left has to be rederived against the SETTLED size
            // — clamping to a half-laid-out width left the card a few pixels
            // off its output edge. Idempotent for an unchanged centre, and a
            // no-op while a drag is held: whatever resizes the card
            // mid-drag — an external config reload, not just the chooser —
            // must not steal the placement from the hand (the guard in
            // applyFloatingPosition). The picker session re-fits on the
            // same changes (drag, dock/float, preset): any movement of the
            // band is a geometry change it answers.
            onXChanged: root.requestPickerFit()
            onYChanged: root.requestPickerFit()
            onWidthChanged: {
                root.applyFloatingPosition()
                root.requestPickerFit()
            }
            onHeightChanged: {
                root.applyFloatingPosition()
                root.requestPickerFit()
            }

            Item {
                id: dragBar
                width: parent.width
                height: tokens.space(30) + keyboard.gapPx * 3

                MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    // Docked is a fixed full-width strip; dragging it off the
                    // bottom edge would fight what the mode means. Floating
                    // is dragged by its bar as before.
                    cursorShape: root.mode === "docked" ? Qt.ArrowCursor : Qt.SizeAllCursor
                    drag.target: root.mode === "docked" ? null : card
                    drag.axis: Drag.XAndYAxis
                    drag.minimumX: 0
                    drag.maximumX: panel.width - card.width
                    drag.minimumY: 0
                    drag.maximumY: panel.height - card.height
                    // Where the drag lands is state worth keeping (spec-v1 §7),
                    // and a drag the compositor takes away mid-gesture still
                    // left the card somewhere — same reasoning as the cancel
                    // path on the key caps. No key can be held by this
                    // MouseArea: it covers the bar, which has no caps in it.
                    onReleased: root.finishDrag()
                    onCanceled: root.finishDrag()
                }

                // The panel's one status line. A swap, not an addition: the
                // line cannot change the card's height, so no failure state
                // ever churns the docked reservation that tickets 08 and 20
                // own. Text and colour both mirror hintState on the panel
                // root above. When the chips stand beside it, the text
                // shifts left by half the whole notice's width — chips plus
                // the margin to the text — so the notice as a group sits
                // centred.
                // Current-content paste sits on the card (pasteButton below)
                // so its z can outrank the settings/editor dismiss layers.
                // Hint and service chips still anchor to it.

                Text {
                    id: hintText
                    anchors {
                        left: languageSwitch.right
                        leftMargin: keyboard.gapPx * 2
                        right: serviceActions.visible ? serviceActions.left
                            : pasteButton.visible ? pasteButton.left : closeButton.left
                        rightMargin: keyboard.gapPx * 2
                        verticalCenter: languageSwitch.verticalCenter
                    }
                    visible: hintState.text !== ""
                    text: hintState.text
                    color: hintState.accent ? tokens.accent : tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignRight
                    z: 1
                }

                // The lifecycle affordances, drawn beside the state they
                // belong to. Anchored to the paste control so appearing and
                // leaving moves the hint, not the reserved centre place: no
                // height change, no docked reservation churn. Retry is the
                // solid chip — the one action that fixes "not running" —
                // and starts the user unit detached; the socket client's
                // existing repair path reconnects from there. Copy is the
                // outlined chip and exists only on a protocol mismatch,
                // where starting cannot help until the helper is
                // reinstalled; it hands the install command to the
                // clipboard and never runs anything. The chip is
                // deliberately terse: text plus chips must fit the bar at the
                Row {
                    id: serviceActions
                    anchors.right: pasteButton.visible ? pasteButton.left : closeButton.left
                    anchors.rightMargin: keyboard.gapPx * 2
                    anchors.verticalCenter: hintText.verticalCenter
                    spacing: keyboard.gapPx
                    visible: hintState.action !== undefined
                    z: 2

                    Rectangle {
                        width: copyLabel.implicitWidth + keyboard.gapPx * 3
                        height: tokens.space(28)
                        radius: tokens.cornerRadius
                        visible: hintState.action === "update"
                        color: copyArea.pressed ? Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: tokens.normalBorderWidth

                        Text {
                            id: copyLabel
                            anchors.centerIn: parent
                            text: "Copy"
                            color: tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: true
                        }

                        MouseArea {
                            id: copyArea
                            anchors.fill: parent
                            onClicked: root.copyInstallCommand()
                        }
                    }

                    Rectangle {
                        width: retryLabel.implicitWidth + keyboard.gapPx * 3
                        height: tokens.space(28)
                        radius: tokens.cornerRadius
                        visible: hintState.action !== undefined
                        color: retryArea.pressed ? tokens.accent : tokens.foreground

                        Text {
                            id: retryLabel
                            anchors.centerIn: parent
                            text: "Retry"
                            color: tokens.background
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: true
                        }

                        MouseArea {
                            id: retryArea
                            anchors.fill: parent
                            onClicked: root.retryService()
                        }
                    }
                }

                // The settings gear (spec-v1.1 §5). Leftmost on purpose: the
                // popover it opens is anchored at its own top-left, so the
                // compact panel of controls drops under the gear and over
                // the grid without ever reaching past the card's right edge.
                // While the popover is open the card-local dismiss area
                // (settingsDismiss below) covers the bar, so a second click
                // on the gear lands there and closes the popover — the same
                // everywhere-outside contract the old chooser kept.
                Rectangle {
                    id: settingsGear
                    anchors {
                        left: parent.left
                        leftMargin: keyboard.gapPx * 2
                        bottom: parent.bottom
                        bottomMargin: keyboard.gapPx
                    }
                    width: tokens.space(30)
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: gearArea.pressed ? tokens.accent
                        : settingsPopover.visible ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : gearArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(
                        settingsPopover.visible || gearArea.containsMouse
                            ? tokens.accent : tokens.foreground,
                        tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        anchors.centerIn: parent
                        text: "\u2699"
                        color: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true
                    }

                    MouseArea {
                        id: gearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            if (settingsPopover.visible || root.customEditorField !== "") {
                                root.closeCustomEditor()
                                settingsPopover.visible = false
                            } else {
                                settingsPopover.visible = true
                            }
                        }
                    }
                }

                Rectangle {
                    id: languageSwitch
                    anchors {
                        left: settingsGear.right
                        leftMargin: keyboard.gapPx
                        bottom: parent.bottom
                        bottomMargin: keyboard.gapPx
                    }
                    width: langLabel.implicitWidth + keyboard.gapPx * 3
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    // Reads as disabled while the panel has no safe device to
                    // switch (see refreshLayoutsFromHypr in Keyboard.qml).
                    // Keyed on the SAME thing that gates the click — the
                    // filtered switch set — because greying on a different
                    // fact made the cap lie: it drew disabled while a click
                    // still moved every device on the seat.
                    color: keyboard.switchKeyboards.length === 0 ? Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        : languageArea.containsMouse ? (languageArea.pressed ? tokens.accent : Util.alpha(tokens.foreground, tokens.hoverFillAlpha))
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: langLabel
                        anchors.centerIn: parent
                        text: keyboard.currentLayoutName
                        // Same fact as the fill above: the label must not read
                        // live while the fill reads disabled, or the other way.
                        color: keyboard.switchKeyboards.length > 0 ? tokens.foreground : tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true
                    }

                    MouseArea {
                        id: languageArea
                        anchors.fill: parent
                        onClicked: keyboard.cycleLanguage()
                    }
                }

                // The owner's 2026-09-05 call, agreed: no size button in the
                // header. Dock/Float followed it out on 2026-09-08: mode
                // lives only in Settings, so the header reads gear,
                // language, hint, paste, close.
                // (The popover's per-row reset and §4's no-movement guarantee
                // are unchanged by the removal.)

                Rectangle {
                    id: closeButton
                    anchors {
                        right: parent.right
                        rightMargin: keyboard.gapPx * 2
                        bottom: parent.bottom
                        bottomMargin: keyboard.gapPx
                    }
                    width: tokens.space(30)
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: closeArea.pressed ? tokens.urgent
                        : closeArea.containsMouse ? Util.alpha(tokens.urgent, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: closeArea.containsMouse ? Util.alpha(tokens.urgent, tokens.pressedFillAlpha) : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: closeLabel
                        anchors.centerIn: parent
                        text: "\u2715"
                        color: closeArea.containsMouse ? tokens.urgent : tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.close()
                    }
                }
            }

            Keyboard {
                id: keyboard
                theme: tokens
                uiScale: root.sizeScale
                // The app the ☺ cap execs (spec-v1.1 §1): the panel resolves
                // override over default; the keyboard probes PATH at click
                // time and raises the transient hint when it is absent.
                emojiAppName: root.emojiApp
                // A standalone picker launched from the ☺ cap is fitted to a
                // clear region by the picker session in beginPickerSession.
                // Omarchy's shell overlay is summoned with an opt-in OSK
                // payload and fitted through PickerFit.planPlacement on its
                // inner card — not by moving a client.
                onEmojiCapActivated: function(app) { root.handleEmojiCap(app) }
                // Everything the card spends on its own padding is width the
                // grid cannot have, so a large preset on a narrow output
                // shrinks to fit rather than running off the card.
                availableWidth: panel.width - tokens.popupPadding - keyboard.gapPx * 2
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top
                    topMargin: dragBar.height + keyboard.gapPx
                }
                onCloseRequested: root.close()
                // The click follows the press, wherever the press came from in
                // the grid — letters, arrows, modifiers, caps. UI actions
                // (close, language, emoji) are not keystrokes and stay quiet.
                onKeyPressed: root.playKeyClick()
            }

            Rectangle {
                id: dependencyNotice
                visible: !root.dependenciesReady
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: keyboard.bottom
                    topMargin: keyboard.gapPx
                }
                width: keyboard.rowWidth
                height: tokens.space(36)
                radius: tokens.cornerRadius
                color: tokens.popupsBackground
                border.color: tokens.accent
                border.width: tokens.normalBorderWidth

                Text {
                    anchors {
                        left: parent.left
                        leftMargin: tokens.spacingMd
                        verticalCenter: parent.verticalCenter
                    }
                    text: dependencyInstall.running
                        ? "Installing keyboard dependencies..."
                        : "Keyboard dependencies are missing"
                    color: tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                Rectangle {
                    anchors {
                        right: parent.right
                        rightMargin: tokens.spacingSm
                        verticalCenter: parent.verticalCenter
                    }
                    width: installLabel.implicitWidth + tokens.spacingLg
                    height: tokens.space(28)
                    radius: tokens.cornerRadius
                    color: installArea.pressed ? tokens.accent : tokens.foreground

                    Text {
                        id: installLabel
                        anchors.centerIn: parent
                        text: dependencyInstall.running ? "Working..." : "Install"
                        color: tokens.background
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: installArea
                        anchors.fill: parent
                        enabled: !dependencyInstall.running
                        onClicked: root.installDependencies()
                    }
                }
            }


            // Current-content paste (spec-v1.1 §1): the reserved top-centre
            // header place. Empty CLIPBOARD hides the chip. Text shows a
            // single-line preview elided to the chip width; non-text keeps
            // the clipboard glyph. Click pastes CLIPBOARD without writing
            // it. Settings live on a separate overlay with a hole over this
            // card, so the chip does not fight a dismiss mask. Hex insert
            // reads CLIPBOARD via wl-paste, not Quickshell.clipboardText.
            Rectangle {
                id: pasteButton
                anchors {
                    horizontalCenter: dragBar.horizontalCenter
                    bottom: dragBar.bottom
                    bottomMargin: keyboard.gapPx
                }
                visible: root.clipboardKind !== "empty"
                width: root.clipboardKind === "text"
                    ? Math.min(Math.max(tokens.space(30),
                        pasteLabel.implicitWidth + tokens.space(16)),
                        tokens.space(240))
                    : tokens.space(30)
                height: tokens.space(30)
                radius: tokens.cornerRadius
                color: !root.pasteEnabled ? Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    : pasteArea.pressed ? tokens.accent
                    : pasteArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth
                z: 6
                opacity: root.pasteEnabled ? 1 : 0.55

                Text {
                    id: pasteLabel
                    visible: root.clipboardKind === "text"
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - tokens.space(12))
                    text: root.clipboardPreview
                    color: pasteArea.containsMouse && root.pasteEnabled
                        ? tokens.accent : tokens.foreground
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                }

                // Drawn clipboard, not a font glyph: the header's other
                // icons are unicode, but a clipboard is not reliably in
                // the theme font and must not blank.
                Item {
                    id: pasteGlyph
                    visible: root.clipboardKind === "other"
                    anchors.centerIn: parent
                    width: tokens.space(14)
                    height: tokens.space(16)

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height * 0.16
                        width: parent.width * 0.72
                        height: parent.height * 0.78
                        radius: Math.max(1, tokens.space(2))
                        color: "transparent"
                        border.color: pasteArea.containsMouse && root.pasteEnabled
                            ? tokens.accent : tokens.foreground
                        border.width: tokens.normalBorderWidth
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 0
                        width: parent.width * 0.46
                        height: parent.height * 0.28
                        radius: Math.max(1, tokens.space(1))
                        color: pasteArea.containsMouse && root.pasteEnabled
                            ? tokens.accent : tokens.foreground
                    }
                }

                MouseArea {
                    id: pasteArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.pasteEnabled
                    Accessible.role: Accessible.Button
                    Accessible.name: "Paste"
                    onClicked: root.pasteCurrentContent()
                }
            }
        }
    }

    // One settings overlay (spec-v1.1 §5). Separate PanelWindows for the
    // popover/editor failed to remap after the first hide (gear opens
    // once, then needs a shell restart) and leftover clicks ate the card.
    // This window stays mapped while the keyboard is open; the mask is
    // empty until settings open, then leftover ∪ the card so Custom on
    // the band still receives clicks without a bounding-box over keys.
    PanelWindow {
        id: settingsLayer
        visible: root.opened
        screen: panel.screen
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "io.github.vladkarok.osk.settings"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.hexEditing
            ? (root.hexFocusPrimed ? WlrKeyboardFocus.OnDemand
                                   : WlrKeyboardFocus.Exclusive)
            : WlrKeyboardFocus.None

        readonly property bool settingsOpen: settingsPopover.visible
            || root.customEditorField !== ""
        readonly property var overlayBox: ({
            x: 0, y: 0, w: settingsLayer.width, h: settingsLayer.height
        })
        readonly property var bandBox: SettingsPlacement.overlayBand(
            root.mode, overlayBox,
            { x: card.x, y: card.y, w: card.width, h: card.height })
        readonly property var leftoverBox: SettingsPlacement.overlayInputRect(
            overlayBox, bandBox)
        readonly property var popoverPlace: SettingsPlacement.centreInLeftover(
            overlayBox, bandBox,
            { w: settingsPopover.width, h: settingsPopover.height })
        readonly property var editorPlace: SettingsPlacement.centreInLeftover(
            overlayBox, bandBox,
            { w: customColorEditor.width, h: customColorEditor.height })

        mask: Region {
            x: settingsLayer.settingsOpen ? settingsLayer.leftoverBox.x : 0
            y: settingsLayer.settingsOpen ? settingsLayer.leftoverBox.y : 0
            width: settingsLayer.settingsOpen ? settingsLayer.leftoverBox.w : 0
            height: settingsLayer.settingsOpen ? settingsLayer.leftoverBox.h : 0
            Region {
                x: settingsPopover.x
                y: settingsPopover.y
                width: settingsPopover.visible ? settingsPopover.width : 0
                height: settingsPopover.visible ? settingsPopover.height : 0
                intersection: Intersection.Combine
            }
            Region {
                x: customColorEditor.x
                y: customColorEditor.y
                width: customColorEditor.visible ? customColorEditor.width : 0
                height: customColorEditor.visible ? customColorEditor.height : 0
                intersection: Intersection.Combine
            }
        }

        MouseArea {
            x: settingsLayer.leftoverBox.x
            y: settingsLayer.leftoverBox.y
            width: settingsLayer.settingsOpen ? settingsLayer.leftoverBox.w : 0
            height: settingsLayer.settingsOpen ? settingsLayer.leftoverBox.h : 0
            enabled: settingsLayer.settingsOpen
            z: 0
            onClicked: function (mouse) {
                if (settingsPopover.visible
                    && mouse.x + x >= settingsPopover.x
                    && mouse.x + x <= settingsPopover.x + settingsPopover.width
                    && mouse.y + y >= settingsPopover.y
                    && mouse.y + y <= settingsPopover.y + settingsPopover.height)
                    return
                if (customColorEditor.visible
                    && mouse.x + x >= customColorEditor.x
                    && mouse.x + x <= customColorEditor.x + customColorEditor.width
                    && mouse.y + y >= customColorEditor.y
                    && mouse.y + y <= customColorEditor.y + customColorEditor.height)
                    return
                root.endHexEdit()
                if (root.customEditorField !== "") {
                    root.closeCustomEditor()
                    return
                }
                settingsPopover.visible = false
            }
        }

        Item {
            id: popoverFocusSink
            width: 0
            height: 0
        }

        Item {
            id: editorFocusSink
            width: 0
            height: 0
        }

        SettingsPopover {
            id: settingsPopover
            panel: root
            tokens: tokens
            hostWidth: settingsLayer.leftoverBox.w
            hostHeight: settingsLayer.leftoverBox.h
            x: settingsLayer.popoverPlace.x
            y: settingsLayer.popoverPlace.y
            z: 1
            onCustomColourRequested: function (fieldName, labelText) {
                root.openCustomEditor(fieldName, labelText)
            }
        }

        SettingsColorEditor {
            id: customColorEditor
            panel: root
            tokens: tokens
            fieldName: root.customEditorField
            labelText: root.customEditorLabel
            visible: root.customEditorField !== ""
            oldColor: root.customEditorOldColor
            hostWidth: settingsLayer.leftoverBox.w
            hostHeight: settingsLayer.leftoverBox.h
            x: settingsLayer.editorPlace.x
            y: settingsLayer.editorPlace.y
            z: 2
            onDismissed: root.closeCustomEditor()
        }
    }
}
