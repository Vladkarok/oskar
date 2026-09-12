import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Config.js" as ConfigFile
import "PickerFit.js" as PickerFit

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
    readonly property var sizePresetScales: ({ "medium": 1.0, "large": 1.2, "x-large": 1.45 })
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
        accent: tokens.accent,
        muted: tokens.muted
    })

    // The colour now in force for each appearance field — override, or the
    // resolved token when none — the one mapping the colour rows (through
    // the popover) and the custom editor read. Function-formed consumers
    // keep the first binding evaluation, in whatever order the engine runs
    // it, from ever handing a row undefined.
    readonly property var effectiveColorForField: ({
        keyBackground: tokens.keyFill,
        panelBackground: tokens.panelBackground,
        textColor: tokens.textColor,
        accentColor: tokens.accent,
        borderColor: tokens.cardBorderSpec && tokens.cardBorderSpec.color
            ? tokens.cardBorderSpec.color : "transparent"
    })

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
    // The popover's typed-hex state — the panel's ONE sanctioned keyboard-
    // focus exception (spec-v1.1 §5). False for the panel's whole life except
    // while a hex field is being typed into: the layer surface then asks the
    // compositor for OnDemand keyboard focus (see the PanelWindow below), and
    // gives it back when the entry ends. The OSK's own hex-entry pad does not
    // need any of this — it edits the field locally — but a physical keyboard
    // typing into the field, and the compositor's key routing while the field
    // is the active entry, still do. One field at a time, panel-owned: the
    // field that holds active focus is the entry. Fields in the settings
    // popover and in the custom colour editor both report to here.
    property bool hexEditing: false
    property string hexEditField: ""

    function beginHexEdit(field) {
        root.hexEditField = field
        root.hexEditing = true
    }

    function endHexEdit() {
        root.hexEditing = false
        root.hexEditField = ""
    }

    // The custom colour editor (spec-v1.1 §5, 2026-09-06 amendment): which
    // field it is open for, empty when closed. Opening it never resizes the
    // panel — the editor overlays the key grid inside the card.
    property string customEditorField: ""
    property string customEditorLabel: ""

    function openCustomEditor(field, label) {
        if (!root.configHealthy) return
        root.customEditorField = field
        root.customEditorLabel = label
    }

    function closeCustomEditor() {
        root.customEditorField = ""
        root.customEditorLabel = ""
    }

    // The focus prime (Omarchy's own KeyboardPanel pattern, Ui/
    // KeyboardPanel.qml): Hyprland focuses an OnDemand layer surface when it
    // MAPS, but not when an already-mapped surface flips None -> OnDemand —
    // which is exactly what beginHexEdit does to this one. A brief Exclusive
    // prime acquires the compositor's keyboard focus; OnDemand then settles
    // in for the rest of the entry, releasing compositor-wide pointer
    // hit-testing while keeping the focus the prime acquired. 75 ms —
    // several commit cycles, imperceptible.
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

    // The hint line's one state table (spec-v1.1 §3, §1, §6). The newest
    // answer to a click wins: a failure names itself here — text plus whether
    // it draws in the accent colour — instead of the mode hint, and hands the
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
    // click answers and the keymap failure: without the service nothing can
    // type, so its state outranks a keymap mismatch (which re-shows on
    // recovery, when it is the thing left standing). All four read the
    // socket client's own states — no poll behind them. Ready is absent on
    // purpose: the notice disappears once the handshake succeeds and the
    // line falls through to the ordinary hint. `action` carries the
    // affordance the chips below draw: "retry" for a service that is not
    // running, "update" for a protocol mismatch (Copy install command plus
    // Retry).
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
        if (!keyboard.inputReady) {
            if (keyboard.serviceIncompatible)
                return {
                    text: "omarchy-osk.service needs updating",
                    accent: true,
                    action: "update"
                }
            if (keyboard.serviceConnected)
                return {
                    text: "Starting omarchy-osk.service\u2026",
                    accent: false
                }
            return {
                text: "omarchy-osk.service is not running",
                accent: true,
                action: "retry"
            }
        }
        if (keyboard.keycapsFailed || keyboard.capsFactsFailed)
            return {
                text: "Keymap unavailable — drawn caps may not match what typing produces",
                accent: true
            }
        return {
            text: root.mode === "docked"
                ? "\u2328 Docked \u00b7 Double-click Shift to lock"
                : "\u2328 Drag to move \u00b7 Double-click Shift to lock",
            accent: false
        }
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
        settingsPopover.visible = false
        settingsPopover.resetAllArmed = false
        root.endHexEdit()
        root.closeCustomEditor()
        // The picker session is the panel's too: with the panel gone there is
        // no band to keep the picker clear of, and no watch should outlive it.
        root.endPickerSession()
        // Locked Shift is genuinely held down at the device, so closing the
        // panel has to let go of it before the keyboard disappears.
        keyboard.releaseModifiers()
    }

    // Reports {"x": n, "y": n} in compositor coordinates, which is the same
    // space Quickshell's screens are laid out in. A failure leaves the panel on
    // whatever output it already had rather than guessing at one.
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
    // only the one window the session identified.
    property string pickerFitConstraint: ""
    // One identified appearance: the configured app, the window classes it
    // may map as, the pinned address once found, and the attempt history
    // that keeps a stubborn placement from looping forever. Null while no
    // picker from the ☺ cap is being watched.
    property var pickerSession: null

    function pickerBand() {
        var s = panel.screen
        if (!s) return null
        if (root.mode === "docked") {
            // The docked strip: the output's full width, cardHeight tall,
            // along the bottom edge.
            return { x: s.x, y: s.y + s.height - root.cardHeight,
                     w: s.width, h: root.cardHeight }
        }
        // Floating: the card is the band, wherever the drag left it.
        return { x: s.x + card.x, y: s.y + card.y, w: card.width, h: card.height }
    }

    // The ☺ cap's launch (Keyboard's emojiProbe) arms one session. A second
    // press while armed restarts the watch — the launcher's own single-
    // instance behaviour decides what maps, and the newest launch owns the
    // session.
    function beginPickerSession(app) {
        if (!panel.screen) return
        root.pickerSession = {
            app: app,
            classes: PickerFit.resolveClasses(app, ""),
            address: "",
            attempts: 0,
            settled: false,
            settleTries: 0,
            pickerMin: null,
            lastObserved: null,
            lastTarget: null,
            pendingResize: false
        }
        root.pickerFitConstraint = ""
        emojiIdentity.app = app
        emojiIdentity.running = false
        emojiIdentity.running = true
        emojiPlaceTimeout.restart()
        root.requestPickerFit()
    }

    function endPickerSession() {
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
        // queues exactly one re-run, consumed when the query exits.
        if (emojiObserve.running) {
            emojiObserve.queued = true
            return
        }
        emojiObserve.queued = false
        emojiObserve.running = true
    }

    function handlePickerObservation(json) {
        var session = root.pickerSession
        var band = root.pickerBand()
        if (!session || !band || !json || !json.monitor) return

        var client = json.client && json.client.address ? json.client : null
        if (!client) {
            // Nothing mapped under the accepted classes: the watch stays
            // armed for the openwindow event until the hard timeout (the
            // shell-overlay case never maps as a client and simply times
            // out). A PINNED address that has gone means the appearance was
            // dismissed — that settles the session.
            if (session.address !== "") root.endPickerSession()
            return
        }

        if (session.address === "") {
            session.address = client.address
            emojiPlaceTimeout.stop()
        } else if (session.address !== client.address) {
            // The appearance recreated itself under the same identity (an
            // app like Emote destroys and re-maps on a second activation):
            // adopt the new window as this session's appearance and reset
            // the attempt history — the old address no longer exists.
            session.address = client.address
            session.attempts = 0
            session.settled = false
            session.pickerMin = null
            session.lastObserved = null
        }

        var rect = {
            x: client.at[0], y: client.at[1],
            w: client.size[0], h: client.size[1]
        }
        if (PickerFit.needsSettling(rect)) {
            // A freshly mapped window can answer 0x0 before its first
            // commit settles. One bounded re-check covers it even if no
            // further compositor event arrives; the plan runs on real
            // geometry only.
            if (!pickerSettleTimer.running && session.settleTries < 5) {
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

        // Anything observed different from last time resets the attempt
        // budget: only consecutive no-change dispatch loops are bounded.
        if (!PickerFit.sameRect(session.lastObserved, rect, 2))
            session.attempts = 0
        session.lastObserved = rect

        var plan = PickerFit.planPlacement({
            output: PickerFit.logicalMonitorBox(json.monitor),
            workArea: PickerFit.workAreaOf(json.monitor),
            band: band,
            picker: rect,
            pickerMin: session.pickerMin
        })

        if (plan.status === "unfit") {
            // Minimum size beats every region: say so, move nothing, keep
            // watching — a picker resize or panel change can still make it
            // fit later, and the hint clears the moment a plan fits.
            root.pickerFitConstraint = session.app
            console.warn("[osk] picker cannot fit clear of the keyboard:", plan.reason)
            return
        }
        if (root.pickerFitConstraint !== "") root.pickerFitConstraint = ""

        if (PickerFit.sameRect(rect, plan.target, 2)) {
            if (!session.settled) {
                session.settled = true
                console.log("[osk] picker placed", plan.region,
                    JSON.stringify(plan.target), "on", json.monitor.name)
            }
            return
        }

        if (session.attempts >= 3) {
            // Three dispatches moved nothing: positioning failed, and an
            // overlapping placement must not pass for success.
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
        // The dispatch's own compositor events re-run the fit and so VERIFY
        // the resulting rectangle; the one-shot timer below is the bounded
        // fallback should no event land. Successful process exit alone is
        // never treated as proof the picker moved.
        pickerVerifyTimer.restart()
    }

    // One-shot: the configured app's desktop-entry StartupWMClass, so the
    // accepted window classes come from the entry's own declaration where
    // one exists. The executable name is only ever the fallback, and the
    // recorded table carries the classes an app is known to surface on
    // other stacks (PickerFit.js: the installed Emote maps as "emote", its
    // GTK application_id com.tomjwatson.Emote is what other versions may
    // report). Merges into the live session; no poll.
    Process {
        id: emojiIdentity
        property string app: ""
        command: ["bash", "-c",
            "app=$1\n"
          + "for base in ${2//:/ } ${3//:/ }; do\n"
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
            "omarchy-osk-emoji-identity", emojiIdentity.app,
            Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"),
            Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var session = root.pickerSession
                var wmClass = text.trim()
                if (!session || session.app !== emojiIdentity.app || wmClass === "") return
                var merged = PickerFit.resolveClasses(session.app, wmClass)
                for (var i = 0; i < merged.length; i++)
                    if (session.classes.indexOf(merged[i]) === -1) session.classes.push(merged[i])
                // A class the first observation could not know about may
                // already be mapped; re-run now that the accepted list grew.
                root.requestPickerFit()
            }
        }
    }

    // ONE monitors+clients query per fit run — the query only GATHERS; the
    // decision is the pure PickerFit policy and the move is a separate
    // dispatch whose outcome the next observation verifies. Exit 0 always
    // carries the JSON (client may be null); 4/5 mean the compositor could
    // not answer yet — the event watch stays armed either way.
    Process {
        id: emojiObserve
        property string monName: ""
        property int centerX: 0
        property int centerY: 0
        property string classes: ""
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
          + "    | select(($want | index($c)) != null or ($want | index($ic)) != null)]\n"
          + "  | sort_by(.focusHistoryID)\n"
          + "  | (.[0]\n"
          + "    | {address: .address, at: .at, size: .size, floating: .floating}) as $client\n"
          + "| {monitor: $mon, client: $client}'\n",
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
            if (exitCode === 0) root.handlePickerObservation(emojiObserve.parsed())
            else if (exitCode !== 4 && exitCode !== 5)
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
          + "  hyprctl eval \"hl.dispatch(hl.dsp.window.float({ window = \\\"address:$addr\\\" }))\" >/dev/null 2>&1 || exit 1\n"
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

    // The single hard timeout bounding the INITIAL watch: a picker that
    // never maps as a client window (the shell-overlay case) ends the
    // session silently. Stopped the moment an address is pinned; from there
    // the session lives on events alone.
    Timer {
        id: emojiPlaceTimeout
        interval: 6000
        repeat: false
        onTriggered: root.endPickerSession()
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

    // The compositor's event stream drives the watch: no polling. Window
    // events are filtered to the session's identity (class for a first
    // appearance, pinned address afterwards) and monitor/config events
    // cover output removal and scale changes.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            var session = root.pickerSession
            if (!session || !event) return
            var fields = String(event.data || "").split(",")
            switch (event.name) {
            case "openwindow":
                if (fields.length >= 3
                    && PickerFit.classMatches(fields[2], "", session.classes))
                    root.requestPickerFit()
                break
            case "closewindow":
                if (fields[0] === session.address) root.endPickerSession()
                break
            case "movewindow":
            case "movewindowv2":
            case "resizewindow":
            case "resizewindowv2":
            case "changefloatingmode":
            case "windowtitle":
                if (fields[0] === session.address) root.requestPickerFit()
                break
            case "configreloaded":
            case "monitoradded":
            case "monitoraddedv2":
            case "monitorremoved":
                root.requestPickerFit()
                break
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

        // The whole point: never take keyboard focus, so the app window
        // you're typing into keeps it, and the helper's keystrokes land
        // there. Clicks on the keys still work fine with keyboardFocus: None
        // — only keyboard input routing is refused at the compositor level.
        //
        // The one sanctioned exception (spec-v1.1 §5, 2026-09-05): while a
        // hex entry in the settings popover is active, the surface asks for
        // keyboard focus — the user explicitly asked to type hex, and a
        // field nobody can type into is furniture. The entry OPENS with a
        // brief Exclusive prime and settles to OnDemand for the rest of the
        // entry (see hexFocusPrimeTimer above — Hyprland does not focus an
        // already-mapped surface that merely flips to OnDemand). It lasts
        // exactly the length of the entry: beginHexEdit/endHexEdit are the
        // only writers of hexEditing, and every exit path (Enter, Escape,
        // outside click, popover close) runs endHexEdit, after which this is
        // a non-focus-taking surface again. No other control, on any other
        // row, ever changes this.
        WlrLayershell.keyboardFocus: root.hexEditing
            ? (root.hexFocusPrimed ? WlrKeyboardFocus.OnDemand
                                   : WlrKeyboardFocus.Exclusive)
            : WlrKeyboardFocus.None
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
                Text {
                    id: hintText
                    anchors {
                        horizontalCenter: parent.horizontalCenter
                        horizontalCenterOffset: serviceActions.visible
                            ? -(serviceActions.width + keyboard.gapPx * 2) / 2 : 0
                        verticalCenter: languageSwitch.verticalCenter
                    }
                    text: hintState.text
                    color: hintState.accent ? tokens.accent : tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    z: 1
                }

                // The lifecycle affordances, drawn beside the state they
                // belong to. Anchored to the hint text, so appearing and
                // leaving moves nothing else: no height change, no docked
                // reservation churn. Retry is the solid chip — the one
                // action that fixes "not running" — and starts the user
                // unit detached; the socket client's existing repair path
                // reconnects from there. Copy is the outlined chip and
                // exists only on a protocol mismatch, where starting cannot
                // help until the helper is reinstalled; it hands the
                // install command to the clipboard and never runs anything. The chip is
                // deliberately terse: text plus chips must fit the bar at the
                Row {
                    id: serviceActions
                    anchors.left: hintText.right
                    anchors.leftMargin: keyboard.gapPx * 2
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
                        onClicked: settingsPopover.visible = !settingsPopover.visible
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
                    // Reads as disabled while the panel has no safe switch
                    // target (see refreshLayoutsFromHypr in Keyboard.qml):
                    // clicking still calls cycleLanguage, which refuses to
                    // guess rather than advance a device nobody typed on.
                    color: !keyboard.typedKeyboard ? Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        : languageArea.containsMouse ? (languageArea.pressed ? tokens.accent : Util.alpha(tokens.foreground, tokens.hoverFillAlpha))
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: langLabel
                        anchors.centerIn: parent
                        text: keyboard.currentLayoutName
                        color: keyboard.typedKeyboard ? tokens.foreground : tokens.muted
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
                // header. It began as the bar's one-glance size reading that
                // opened the popover, and the reading was not worth the
                // chrome — size lives only in the settings popover now, so
                // the header reads gear, language, hint, mode, close. (The
                // popover's per-row reset and §4's no-movement guarantee are
                // unchanged by the removal.)

                // The other mode, one click away. The label names the action
                // rather than the state: docked offers Float, floating
                // offers Dock. The choice is remembered through the config
                // file (spec-v1 §7: modes are switched from the panel and
                // remembered).
                Rectangle {
                    id: modeButton
                    anchors {
                        right: closeButton.left
                        rightMargin: keyboard.gapPx
                        bottom: parent.bottom
                        bottomMargin: keyboard.gapPx
                    }
                    width: modeLabel.implicitWidth + keyboard.gapPx * 3
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: modeArea.pressed ? tokens.accent
                        : modeArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: modeArea.containsMouse ? Util.alpha(tokens.accent, tokens.pressedFillAlpha) : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: modeLabel
                        anchors.centerIn: parent
                        text: root.mode === "docked" ? "Float" : "Dock"
                        color: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true
                    }

                    MouseArea {
                        id: modeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.setMode(root.mode === "docked" ? "floating" : "docked")
                    }
                }

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
                // clear region by the picker session in beginPickerSession;
                // a picker that never becomes a client window (the Omarchy
                // shell's own overlay) simply finds nothing to place.
                onEmojiPickerLaunched: function(app) { root.beginPickerSession(app) }
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


            // ---- settings surface (spec-v1.1 §5; extracted and amended
            // 2026-09-06, ticket 07) ----
            //
            // The popover, the custom colour editor and their dismissal
            // surfaces live in their own files. All four are declared above
            // the keyboard (z 3, 4 and 5 against the grid's default) because
            // the gear they hang from sits in the bar underneath, and
            // anchors may only cross a parent boundary, not a sibling's
            // child — hence the x arithmetic off settingsGear.
            MouseArea {
                id: settingsDismiss
                anchors.fill: parent
                visible: settingsPopover.visible
                z: 3
                // Outside click closes, the same contract the chooser kept.
                // Card-local by construction: the window's input mask is the
                // card (the Region on the PanelWindow below), so a click off
                // the card is never this surface's to see in the first
                // place. A click that lands here while a hex entry is active
                // is also the exit that hands the keyboard back, and while
                // the custom editor is open it drops only that editor's
                // uncommitted draft first.
                onClicked: {
                    if (root.customEditorField !== "") {
                        root.closeCustomEditor()
                        return
                    }
                    settingsPopover.visible = false
                }
            }

            // The compact settings popover (SettingsPopover.qml): theme
            // swatches, hex drafts with Apply, the emoji chooser, reset —
            // reading the store's effective values and issuing changes
            // through the panel API, with no persistence policy of its own.
            SettingsPopover {
                id: settingsPopover
                panel: root
                tokens: tokens
                gearX: settingsGear.x
                barHeight: dragBar.height
                cardWidth: card.width
                cardHeight: card.height
                z: 4
                onCustomColourRequested: function (fieldName, labelText) {
                    root.openCustomEditor(fieldName, labelText)
                }
            }

            // The custom editor's own dismissal mask, between the popover
            // and the editor: with the editor open, an outside click drops
            // only the editor's uncommitted draft — previously applied
            // settings and the popover itself survive.
            MouseArea {
                id: editorDismiss
                anchors.fill: parent
                visible: root.customEditorField !== ""
                z: 4
                onClicked: root.closeCustomEditor()
            }

            // The larger custom colour editor (SettingsColorEditor.qml): a
            // local preview for the selected setting — plane, hue and
            // brightness, synchronized hex with the same local OSK pad —
            // with explicit Apply and Cancel. It overlays the grid and never
            // changes the card's size, so no editor interaction can churn
            // the docked reservation.
            SettingsColorEditor {
                id: customColorEditor
                panel: root
                tokens: tokens
                fieldName: root.customEditorField
                labelText: root.customEditorLabel
                visible: root.customEditorField !== ""
                oldColor: root.customEditorField !== ""
                    ? root.effectiveColorForField[root.customEditorField]
                    : "transparent"
                width: Math.min(card.width - tokens.space(12), tokens.space(320))
                height: Math.min(card.height - dragBar.height - tokens.space(18),
                    tokens.space(420))
                x: Math.max(tokens.space(6), (card.width - width) / 2)
                y: dragBar.height + tokens.space(6)
                z: 5
                onDismissed: root.closeCustomEditor()
            }
        }
    }
}
