import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "ClipboardPaste.js" as ClipboardPaste
import "PasteFlow.js" as PasteFlow
import "Config.js" as ConfigFile
import "EmojiPage.js" as EmojiGrid
import "InputProfile.js" as InputProfile
import "LanguageControl.js" as LanguageControl
import "SettingsPlacement.js" as SettingsPlacement
import "UiStrings.js" as UiStrings

Item {
    id: root

    property var hostShell: null
    property var panelManifest: null
    property bool opened: false  // Omarchy shell-IPC: isPluginOpen reads it
    // The surface maps only once the summon has chosen its output. The
    // pointer's output arrives from an asynchronous probe, and a window
    // mapped on `opened` alone draws one to three frames on whatever
    // output it had last before it moves — the second-monitor flash.
    // Reset on every close, so the next summon starts unmapped too; the
    // fallback timer below keeps a failed probe from hiding the panel.
    property bool placed: false
    property bool depsOk: true

    // ---- configuration ----
    //
    // Configuration has three non-overlapping roles: complete shipped
    // defaults in Config.js, sparse choices in config.json, and geometry in
    // state.json. Both writable files are watched below; no polling is used.
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
        || ((Quickshell.env("HOME") || "") + "/.config")) + "/oskar"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
        || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/oskar"
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
            settingsLayerHost.disarmResetAll()
    }
    property var geometryState: ConfigFile.stateDefaults()
    property string configurationError: ""
    property string stateError: ""
    // The per-path save-failure notice state (the list, its history and
    // the mark/landed transitions) lives in PrivateSaves below; the panel
    // keeps only the hint line's own derivation.
    readonly property bool saveFailedNotice: saves.saveFailedPaths.length > 0
    // Every control that writes the overrides file stands down while a
    // malformed external edit is standing: the popover keeps showing the
    // last valid runtime values and says so, and the bad file is never
    // overwritten (saveOverrides refuses). The watched reload clears the
    // error the moment the file is fixed; nothing is polled.
    readonly property bool configHealthy: root.configurationError === ""

    // Geometry. Docked — the default, because it needs no positioning
    // decision from someone who just installed the plugin — reserves a
    // full-width strip along the bottom edge so windows move up instead of
    // being covered; floating overlays and is dragged around. `center` is
    // geometry state; `size_preset` is a user preference. They
    // intentionally persist to different files even though both affect the
    // floating card.
    property string mode: maintainedDefaults.mode
    property var floatingCenter: null
    property string sizePreset: maintainedDefaults.sizePreset

    // Size presets: chosen from a direct M/L/XL chooser, not a resize
    // handle. `medium` is the geometry the
    // keyboard shipped with and the smallest of the three — the presets only
    // go up, because the hit targets are already sized for touch at `medium`
    // and a smaller preset would trade that away. An unknown name in the
    // config file lands on `medium`, which is what the chips' label
    // fallback in the settings popover already does below.
    readonly property var sizePresetOrder: ["medium", "large", "x-large"]
    readonly property var sizePresetScales: ConfigFile.SIZE_PRESET_SCALES
    readonly property var sizePresetLabels: ({ "medium": "M", "large": "L", "x-large": "XL" })
    readonly property real sizeScale: root.sizePresetScales[root.sizePreset] || 1.0

    // The colour rows' recommended swatches: up to four theme-derived
    // colours — background, foreground,
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

    property bool emojiCloseAfterPick: maintainedDefaults.emojiCloseAfterPick
    property string emojiPageSize: maintainedDefaults.emojiPageSize
    // The emoji page's free drag: off by default — off IS today's page,
    // computed leftover-centre placement and no affordance. Override, else
    // the maintained default, the same plain preference shape as the
    // picking pair above.
    property bool emojiDrag: maintainedDefaults.emojiDrag
    // The Super cap's mark: the word by default, a chosen mark otherwise.
    // Override, else the maintained default — the same plain preference
    // shape as the mode and the emoji app.
    property string superMark: maintainedDefaults.superMark
    // Dwell-to-type: off by default, the delay bounded by Dwell.js's
    // window and validated to the same bounds at the file. Override, else
    // the maintained default — the same plain preference shape as the mode
    // and the Super mark.
    property bool dwellEnabled: maintainedDefaults.dwellEnabled
    property int dwellDelayMs: maintainedDefaults.dwellDelayMs
    // The UI's language: "auto" follows the active layout, en/ru/uk/it pin
    // it, offered when the seat carries the layout. `uiLang` is the
    // resolved two-letter answer every tr() call site reads — override
    // over layout, English for anything we do not ship, the
    // searchPlaceholder rule generalised.
    property string uiLanguage: maintainedDefaults.uiLanguage
    // The seat's installed layout list, exposed for the popover's row
    // (the offered languages mirror it).
    readonly property var seatLayoutCodes: keyboard.layoutCodes
    readonly property string uiLang: UiStrings.languageFor(
        keyboard.activeLayoutCode, root.uiLanguage, keyboard.layoutCodes)
    // What the LANGUAGE row shows selected: the override when it is
    // representable on this seat, else Auto (a stale hand-edited value
    // or a shrunk layout list leaves it inert, not lying).
    readonly property string uiLanguageDisplay: {
        var offered = UiStrings.languageChoices(keyboard.layoutCodes)
        return offered.indexOf(root.uiLanguage) !== -1
            ? root.uiLanguage : "auto"
    }
    // The input profile: which pointer world the panel answers as. The
    // setting is auto/mouse/touch; the OBSERVATION is monotonic PER SUMMON
    // — the first synthesized (touch/pen) mouse event any panel surface
    // sees flips touchObserved, and a HIDDEN panel forgets it — a touch on
    // one monitor must not park release-typing on another for the whole
    // session. Within a summon it never decays — a touchscreen laptop's stray
    // mouse click must not flap the profile back — and with dwell ENABLED
    // auto never flips at all (the a11y guard; the explicit setting is the
    // deliberate switch). The resolution and everything it switches is
    // InputProfile.js's pure table (tests/input-profile.qml); this is the
    // one fact only the live panel can hold.
    property string inputProfile: maintainedDefaults.inputProfile
    property bool touchObserved: false
    readonly property string effectiveInputProfile: InputProfile.resolve(
        root.inputProfile, root.touchObserved, root.dwellEnabled)
    readonly property var inputAfford: InputProfile.affordances(
        root.effectiveInputProfile)

    // Chrome hit targets, invisible growth only (no visual redesign): the
    // arithmetic is InputProfile.chromeHitGrowth's — the
    // per-side need toward the profile's floor (0 in mouse, so the chips
    // are byte-today there), capped by the room each control truly owns.
    // The header's standing chips are 30px tall with cellGap*2 of bar
    // above them and cellGap below (below THAT the keyboard sibling
    // outranks them in z, so growing past the bar is dead area); the
    // failure-path service chips are 28px on the same centre line.
    readonly property var chromeHitGrow30: InputProfile.chromeHitGrowth(
        tokens.space(30), keyboard.cellGap,
        keyboard.cellGap * 2, keyboard.cellGap,
        inputAfford.minChromeTargetPx)
    readonly property var chromeHitGrow28: InputProfile.chromeHitGrowth(
        tokens.space(28), keyboard.cellGap,
        keyboard.cellGap * 2 + 1, keyboard.cellGap + 1,
        inputAfford.minChromeTargetPx)

    /// The one writer of the observation. Every MouseArea that handles a
    /// press reports its event's `source` — synthesized means a finger (or
    /// a pen: a hover-less pointer gets the touch affordances too), and
    /// one sighting is the whole lesson. Explicit profiles read the fact
    /// nowhere; auto reads it everywhere.
    function observePointerSource(source) {
        if (touchObserved) return
        if (!InputProfile.isTouchSource(source)) return
        touchObserved = true
        console.log("[oskar] input profile: touch events observed "
            + "(auto resolves to touch until the panel hides)")
    }
    // Colour-field entry and the armed emoji search are the panel's only
    // TWO sanctioned keyboard-focus exceptions, both on the settings
    // overlay, never at once. False
    // except while a hex/RGB/HSV field is the active entry: the popover
    // or editor window that holds that field then asks for Exclusive
    // then OnDemand so the main OSK types into it.
    // The keyboard panel itself stays None. One exception at a time,
    // panel-owned; opening a colour field disarms the search.
    property bool hexEditing: false
    property string hexEditField: ""

    function beginHexEdit(field) {
        // Hex wins the keyboard: an armed emoji search would both eat the
        // caps' input in the query and hold the layer focus
        // this entry needs. Disarm first — the keyboardFocus binding then
        // hands the surface to the hex prime untouched.
        if (emojiPage.searchArmed) emojiPage.searchArmed = false
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
        // so a later hide cannot recapture keyboard focus. Custom/Cancel/
        // leftover call this because their MouseAreas do not steal focus
        // on their own.
        if (released.dropItemFocus) {
            if (root.customEditorField !== "")
                editorFocusSink.forceActiveFocus()
            else
                popoverFocusSink.forceActiveFocus()
        }
    }

    // The custom colour editor: which field it is open for, empty when
    // closed. It sits on its own overlay window, never on the grid.
    property string customEditorField: ""
    property string customEditorLabel: ""
    // Snapshot of the effective colour at open — the editor's "old". A live
    // binding would reset HSV from later theme/config changes while leaving
    // the hex draft stale, and Apply would then commit that stale hex.
    property color customEditorOldColor: "transparent"

    // The panel's own emoji page: the ☺ cap toggles it, the settings layer
    // hosts it at leftover centre, and it never covers the keys — its
    // search types from those very keys. Panel-local state; nothing
    // persists.
    property bool emojiOpen: false
    // The page's search is the keys' target only while armed — one flag
    // drives the caps' routing, the paste chip's target rule, the field's
    // visible state, and whether the settings overlay holds keyboard focus
    // and its key scope routes physical typing, so what the user sees is
    // what decides.
    readonly property bool emojiSearchActive: root.emojiOpen
        && emojiPage.searchArmed
    readonly property var emojiUsage: geometryState.emojiUsage || []
    readonly property string emojiSkinTone: geometryState.emojiSkinTone || ""
    // The emoji page's remembered centre: persisted UI state beside the
    // floating card's centre, on the same
    // write path. Kept, never erased — turning the setting off returns
    // to computed placement without forgetting where the hand left the
    // page, so flipping it back on restores the remembered spot.
    readonly property var emojiCenter: geometryState.emojiCenter || null
    // The remembered layout group: persisted UI state (not an override),
    // the restart fallback LayoutDevices reads when no live device
    // evidence exists.
    readonly property int rememberedLayoutGroup: typeof geometryState.layoutGroup === "number"
        && geometryState.layoutGroup >= 0 ? Math.floor(geometryState.layoutGroup) : 0
    readonly property string rememberedLayoutDevice:
        typeof geometryState.layoutDevice === "string"
            ? geometryState.layoutDevice : ""

    function toggleEmojiPage() {
        var next = !root.emojiOpen
        if (next) {
            // One surface at a time in the leftover centre: the page
            // replaces the settings card, it does not stack on it.
            settingsLayerHost.closePopover()
            root.closeCustomEditor()
        }
        root.emojiOpen = next
    }

    // A focus change while the page stands disarms the search — the
    // client the owner clicked becomes the keys' target until the search
    // field is clicked again. Hyprland announces focus changes as the
    // `activewindow` raw event (the same stream Keyboard's layout tracker
    // reads; there is no activeToplevel property-change signal to connect
    // to).
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!event || !event.name) return
            var eventName = String(event.name)
            if (eventName === "activewindow") {
                // The class half of the compositor's own focus stream:
                // `activewindow>>CLASS,TITLE`, and an empty one (focus
                // moved to a layer surface) must not erase
                // the memory — activeToplevel is already null there, and
                // the memory is exactly what carries the pick's target
                // through an armed search.
                var focusClass = String(event.data || "").split(",")[0]
                if (focusClass) root.lastClientClass = focusClass
            }
            if (eventName !== "activewindow" || !root.emojiOpen) return
            // Deferred out of the event dispatch: running a state change
            // inside a bound-signal frame on this path can crash the shell
            // with a SIGSEGV, and there is no reason for it to run inside
            // one.
            Qt.callLater(function () {
                if (root.emojiOpen && emojiPage.searchArmed) {
                    emojiPage.searchArmed = false
                    console.log("[oskar] emoji search disarmed: focus moved to",
                        root.focusedClientClass() || "an unnamed client")
                }
            })
        }
    }

    // A delivered pick: the keys go back to the chat the emoji landed in
    // — disarmed, and the standing query retires so the next field click
    // starts a fresh search instead of appending to the old one.
    function emojiPickSettled() {
        emojiPage.searchArmed = false
        emojiPage.query = ""
    }

    // One applied search input, whatever hand named it: the OSK caps
    // arrive as Keyboard.searchInput, physical typing as the page's
    // physicalSearchInput — both carry the same action vocabulary, so both
    // run this rule. Escape disarms once and closes only on the next
    // press; every other action is the pure seam's query update.
    function applyEmojiSearchInput(action, text) {
        if (action === "escape") {
            // Esc is the natural "leave the search" gesture the platform
            // cannot give a click: the first press hands the keys back to
            // the focused chat and releases the layer's hold with it, the
            // second closes the page as before.
            if (emojiPage.searchArmed) {
                emojiPage.searchArmed = false
                emojiPage.query = ""
                console.log("[oskar] emoji search disarmed by Esc")
                return
            }
            root.emojiOpen = false
            return
        }
        emojiPage.applySearchKey(action, text)
    }

    // Every geometryState write goes through here: one place that knows
    // the full field set, so a new field cannot be silently dropped by a
    // future writer (a missed field here desyncs keyboards across
    // restarts).
    function mergedGeometryState(overrides) {
        var next = {
            center: root.geometryState.center,
            emojiCenter: root.geometryState.emojiCenter || null,
            emojiUsage: root.emojiUsage,
            emojiSkinTone: root.emojiSkinTone,
            layoutGroup: root.rememberedLayoutGroup,
            layoutDevice: root.rememberedLayoutDevice
        }
        for (var key in overrides)
            if (Object.prototype.hasOwnProperty.call(overrides, key))
                next[key] = overrides[key]
        return next
    }

    function recordEmojiSuccess(emoji) {
        root.geometryState = root.mergedGeometryState({
            emojiUsage: EmojiGrid.usageAfterSuccess(root.emojiUsage, emoji)
        })
        root.saveState()
    }

    function chooseEmojiSkinTone(tone) {
        if (ConfigFile.EMOJI_SKIN_TONES.indexOf(tone) < 0
            || tone === root.emojiSkinTone) return
        root.geometryState = root.mergedGeometryState({ emojiSkinTone: tone })
        root.saveState()
    }

    // The helper acknowledged a configure: its world, group included, now
    // matches the panel's. Persisted as the restart fallback — a majority
    // of sleeping keyboards must not outvote it after a shell restart.
    // The seat named a (safe) keyboard as its last typist: persist the
    // identity — a shell restart re-picks `main` by enumeration order, and
    // the named tier reading the LIVE device is worth more than any
    // remembered group.
    function recordLayoutDevice(name) {
        var next = String(name || "")
        if (next === "" || next === root.rememberedLayoutDevice) return
        root.geometryState = root.mergedGeometryState({ layoutDevice: next })
        root.saveState()
    }

    function recordLayoutGroup(group) {
        var next = (typeof group === "number" && group >= 0)
            ? Math.floor(group) : 0
        if (next === root.rememberedLayoutGroup) return
        root.geometryState = root.mergedGeometryState({ layoutGroup: next })
        root.saveState()
    }

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

    // The focus prime: the same machinery, keyed on the armed emoji search
    // instead of hex editing. Arming (a field click, or the page opening
    // armed) may happen with the pointer parked on the keyboard band — a
    // surface whose interactivity is None — so OnDemand alone would wait
    // for a hover that may never come; the 75 ms Exclusive prime acquires
    // focus deterministically at commit, and OnDemand settles in for the
    // rest of the arm. The settle is the clean world this needs:
    // Hyprland's refocusLastWindow skips OnDemand layer surfaces, so a
    // click into any client takes keyboard focus back, the activewindow
    // watcher disarms, and the binding below returns the surface to None —
    // which the compositor answers by refocusing the last window (the
    // colour-field release's proven path).
    property bool emojiFocusPrimed: false
    Timer {
        id: emojiFocusPrimeTimer
        interval: 75
        onTriggered: if (root.emojiSearchActive) root.emojiFocusPrimed = true
    }
    onEmojiSearchActiveChanged: {
        if (root.emojiSearchActive) {
            root.emojiFocusPrimed = false
            emojiFocusPrimeTimer.restart()
        } else {
            root.emojiFocusPrimed = false
        }
    }

    // The resize anchors. Docked is a bottom-anchored full-width strip, so
    // a preset change preserves bottom-centre by construction: the
    // window's height binding follows the keyboard and the compositor
    // moves the top edge, never the bottom (see the PanelWindow below).
    // Floating keeps the card CENTRE: the top-left is rederived from the
    // saved centre by ConfigFile.floatingAnchor, which clamps only enough
    // to keep the complete card on its output. The chips live in the
    // settings popover, which stays open through a choice — a settings
    // surface is dismissed, not spent, by using it —
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
    // Escape hatch for the independent colour schema; it follows the
    // theme and does nothing else yet, but is persisted so the key exists
    // from the start.
    property bool followTheme: maintainedDefaults.followTheme
    // Absolute path of the PCM copy the click effect plays; empty until
    // resolved or when the theme has no such event.
    property string soundFile: ""
    // A sound setting of ON with an effect that cannot play is never silent
    // about it: a failed theme lookup or a missing QtMultimedia raises this
    // and the sound row says "unavailable" at the switch itself — one
    // mechanism, where the setting lives. Cleared by a successful resolve
    // and irrelevant while the switch is off.
    property bool soundUnavailable: false

    // Every colour, font, radius and spacing the panel draws with comes from
    // here, and from nowhere else. Following the theme is what a
    // plain binding through it already does — the shell reassigns the shared
    // tokens on a theme switch and the keyboard redraws where it stands, with
    // no restart, no keymap compile and no reconnection, because none of that
    // is on this path. `follow_theme: false` is the one thing that needs code.
    // The sparse override map rides in as the facade's top precedence tier:
    // the popover writes overrides, the facade resolves
    // override over token over shipped fallback, and no panel property or
    // second reader stands between them.
    Theme {
        id: tokens
        follow: root.followTheme
        overrides: root.userOverrides
    }

    function probeDependencies() {
        depProbe.running = true
        lifecycleProbe.running = true
    }

    function setupDependencies() {
        if (depSetup.running) return
        depSetup.running = true
    }

    // ---- helper lifecycle actions ----
    //
    // Retry runs the one command the spec names, detached like every other
    // process spawn here, and lets the socket client's existing repair path
    // (rebuild when the socket file exists, hello, configure) do the
    // reconnecting — no poll behind the button. Copy hands the install
    // command to the compositor clipboard through Quickshell's own
    // clipboardText; nothing is ever installed, built or elevated by the
    // panel itself.
    //
    // The copied command is the lifecycle command: one
    // `oskar setup` converges registration, plugin enable and the
    // unit — and exists both for the package (/usr/bin) and after any
    // source install.sh run (~/.local/bin). Only a never-installed source
    // checkout lacks it, and exactly there the checkout's own install.sh
    // is the honest command; the probe picks once at startup.
    property bool lifecycleCommandAvailable: false
    readonly property string installCommand: root.lifecycleCommandAvailable
        ? "oskar setup"
        : "bash " + (Quickshell.env("HOME") || "")
            + "/.config/omarchy/plugins/io.github.vladkarok.oskar/install.sh"

    function retryService() {
        Quickshell.execDetached(["systemctl", "--user", "start", "oskar.service"])
    }

    function copyInstallCommand() {
        Quickshell.clipboardText = root.installCommand
    }

    // Current-content paste. Never writes
    // CLIPBOARD. A panel-local input (colour field, emoji search) takes
    // the paste itself; otherwise the helper sends the proven paste chord
    // at whoever already has focus — unconditionally: a dead clipboard
    // owner pasting nothing is the Wayland behaviour, and the chip does
    // not compound it with its own refusal. Empty clipboard hides the
    // chip. The control stays
    // clickable whenever it can deliver — Quickshell's clipboard getter
    // is not a reliable empty check and is not the hex-insert source (it
    // stays empty/stale here).
    readonly property bool pasteEnabled: root.hexEditing || root.emojiOpen
        || keyboard.inputReady
    // CLIPBOARD observation for the chip: empty / text / other. Refreshed
    // on panel open, on paste click, and by wl-paste --watch — never polled.
    property string clipboardKind: "empty"
    property string clipboardPreview: ""
    property int clipboardSeq: 0
    property bool clipboardContentGone: false
    property var clipboardReadState: ClipboardPaste.readInitial()
    // Last non-empty focused class: a layer click can briefly clear
    // activeToplevel, and terminals vs GTK pick different CLIPBOARD chords.
    // Refreshed from the compositor's own `activewindow` event stream:
    // while a panel overlay holds the keyboard (the armed
    // emoji search), activeToplevel is null and this memory is the only
    // witness of the chat the keys — and an emoji pick — must return to.
    // Fed by the event, it is the compositor's focus history, not a
    // snapshot of whenever a caller last asked; the class half of the
    // event's data is the toplevel's class, exactly what the routing
    // table keys on.
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
        // While an emoji pick owns the clipboard, a chip click must not
        // paste mid-transaction — the paste chord is fire-and-forget and
        // would reopen the paste gate for a second paste behind it.
        // Refuse; the queue drains in milliseconds. A refusal must be
        // VISIBLE: a chip that draws enabled and clicks dead is the
        // silence class.
        if (emojiDelivery.emojiTxnState.phase !== "idle") {
            console.warn("[oskar] paste chip refused: an emoji pick owns"
                + " the clipboard")
            root.flashRefused(UiStrings.tr("hint.pasteBusy", root.uiLang))
            return
        }
        // R2: one target determination before any delivery choice. A
        // panel-local input — the colour field, or the emoji page whose
        // search every key is typing into while it is open — takes the
        // paste itself; only a panel with no local input delivers the
        // chord to the focused client behind it.
        var target = currentPasteTarget()
        if (target !== "external-client") {
            root.startLocalClipboardRead(target)
            root.refreshClipboardPreview()
            return
        }
        // The callback is the paste flow's own refusal channel
        // (PasteFlow.begin refuses one-at-a-time, the paced dispatch can
        // refuse on an empty plan): a refusal must flash on the hint
        // line rather than pass silently.
        keyboard.pasteCurrent(root.focusedClientClass(), function (ok) {
            if (!ok) {
                root.flashRefused(UiStrings.tr("hint.pasteBusy", root.uiLang))
            }
        })
    }

    // The panel-local read (colour field, emoji search) — bounded and
    // target-guarded the way the probe is (R2): the same wl-paste that
    // blocks on a dead owner serves this read, so a watchdog force-kills
    // it, and an answer arriving for a target that closed or was replaced
    // inserts nothing.
    // The paste/read target carries FIELD identity: "colour field" alone
    // would let a delayed paste started for key background land in text
    // colour when focus moved mid-read — the arrival guard refuses
    // exactly that.
    function currentPasteTarget() {
        // The RULE lives in ClipboardPaste.js with its suite; the panel
        // supplies only the live facts.
        return ClipboardPaste.pasteTargetFor(root.emojiSearchActive,
            root.hexEditing, root.hexEditField,
            root.customEditorField !== "")
    }

    // A click that waited out the local read's kill window (the external
    // audit's finding 9): the retired exit re-drives it with the very
    // target the click captured.
    property string localReadQueuedTarget: ""

    function startLocalClipboardRead(target) {
        // A kill from the previous read's watchdog may still be in flight:
        // its late output is refused by sequence, but the Process object
        // is not reusable until that exit lands (the probe's own rule).
        if (localClipboardRead.retiring) {
            root.localReadQueuedTarget = target
            return
        }
        var started = ClipboardPaste.readStart(root.clipboardReadState, target)
        root.clipboardReadState = started.state
        if (started.action !== "read") return
        localClipboardRead.seq = started.state.seq
        localClipboardReadWatchdog.restart()
        restartProcessGroup(localClipboardRead)
    }

    function finishLocalClipboardRead(seq, raw) {
        // The target is re-derived at arrival by the same determination
        // the click made; readExited refuses a mismatch for us.
        var result = ClipboardPaste.readExited(root.clipboardReadState, seq,
            currentPasteTarget())
        root.clipboardReadState = result.state
        if (result.action !== "insert") return
        localClipboardReadWatchdog.stop()
        insertLocalClipboardText(raw)
    }

    function markClipboardContentGone() {
        // Retire any one-shot preview answer that was already in flight: it
        // describes the dead owner's old selection and must not resurrect
        // the chip after the failed pre-flight.
        root.clipboardSeq += 1
        root.clipboardKind = "empty"
        root.clipboardPreview = ""
        root.clipboardContentGone = true
        clipboardGoneTimer.restart()
    }

    // Set when a refresh had to wait a retiring probe out: the retired
    // exit re-drives it, so a burst of clipboard changes never leaves the
    // chip stale-hidden.
    property bool clipboardRefreshQueued: false

    function refreshClipboardPreview() {
        // The probe's own rule (the local read has had it since its
        // audit): a kill is in flight — the Process object is not
        // reusable until that exit lands, and retagging its seq now
        // would let the DEAD run's exit apply stale clipboard bytes
        // under the new sequence. Queue; the retired exit re-drives.
        if (clipboardTypes.retiring) {
            root.clipboardRefreshQueued = true
            return
        }
        if (clipboardTypes.running) {
            // Kill ONLY (the external audit's finding 6): re-arming
            // inline raced the killed child's exit — the restart could be
            // consumed as the retired one and the new-sequence probe
            // never ran. The retired exit re-drives through the queue.
            clipboardTypes.retiring = true
            root.clipboardRefreshQueued = true
            killProcessGroup(clipboardTypes)
            return
        }
        root.clipboardSeq += 1
        clipboardTypes.seq = root.clipboardSeq
        clipboardTypes.running = true
    }

    function applyClipboardTypes(text, seq, exitCode) {
        if (seq !== root.clipboardSeq) return
        var kind = ConfigFile.clipboardKind(text, exitCode)
        if (kind !== "empty") {
            root.clipboardContentGone = false
            clipboardGoneTimer.stop()
        }
        // Text stays hidden until wl-paste --no-newline returns a
        // non-empty preview; empty/other apply immediately.
        root.clipboardKind = ConfigFile.pasteChipKind(kind, "", false)
        root.clipboardPreview = ""
        if (kind !== "text") return
        if (clipboardText.retiring) {
            root.clipboardRefreshQueued = true
            return
        }
        if (clipboardText.running) {
            // Kill only — the retired exit re-drives (finding 6).
            clipboardText.retiring = true
            root.clipboardRefreshQueued = true
            killProcessGroup(clipboardText)
            return
        }
        clipboardText.seq = seq
        clipboardText.running = true
    }

    function applyClipboardText(text, seq, exitOk) {
        if (seq !== root.clipboardSeq) return
        var preview = ConfigFile.pastePreviewText(text)
        root.clipboardKind = ConfigFile.pasteChipKind("text", preview, exitOk)
        root.clipboardPreview = root.clipboardKind === "text" ? preview : ""
    }

    // The local read's insert. Routing reads the live surfaces: the read's
    // target was verified against the same determination at arrival, so
    // reaching here means the target it served is the one now open. wl-paste
    // reads compositor CLIPBOARD — Quickshell.clipboardText is empty/stale
    // in this stack and cannot be the insert path.
    function insertLocalClipboardText(raw) {
        var text = String(raw || "")
        if (text.length && text.charAt(text.length - 1) === "\n")
            text = text.slice(0, -1)
        if (!text.length) return
        if (root.hexEditing) {
            if (root.customEditorField !== "") settingsLayerHost.editorInsertHexText(text)
            else settingsLayerHost.popoverInsertHexText(text)
            return
        }
        emojiPage.pasteIntoSearch(text)
    }

    // The hint line's one state table. The newest
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
    // drag bar would silently blank every hint binding that used it.
    //
    // The helper lifecycle states sit between the transient
    // click answers and a clear header. Kind comes from the session
    // (Keyboard.lifecycleKind): incompatible and stopped outrank a keymap
    // mismatch because without a usable service nothing can type, but a
    // connected mismatch is unavailable — never the starting notice.
    // Ready is absent on purpose: the notice disappears
    // once the handshake succeeds and the line stays empty. `action`
    // carries the affordance the chips below draw:
    // "retry" for a service that is not running, "update" for a protocol
    // mismatch (Copy install command plus Retry).
    readonly property var hintState: {
        // The transients OVERLAY the base and carry its action through:
        // a refusal flash or a clipboard notice must not mask the
        // Retry/Update chips — the affordance the user was reaching for
        // would otherwise vanish mid-click and return. The text
        // flashes; the chip stays.
        var base = hintBaseState()
        // The queue-cap flash's flag lives in the delivery component
        // (the structural split's step four); the hint table is still
        // its one reader.
        if (emojiDelivery.emojiPickRefused)
            return { text: UiStrings.tr("hint.pickRefused", root.uiLang),
                accent: true, action: base.action }
        if (root.refusedHint !== "")
            // The general transient channel (flashRefused): the newest
            // refusal or one-shot notice, already translated by its
            // caller.
            return { text: root.refusedHint, accent: true, action: base.action }
        if (root.clipboardContentGone)
            return {
                text: UiStrings.tr("hint.clipboardGone", root.uiLang),
                accent: true,
                action: base.action
            }
        return base
    }

    // Everything the transients above may momentarily cover: the
    // lifecycle states, the standing save-failure notice, or nothing.
    function hintBaseState() {
        if (keyboard.lifecycleKind === "incompatible")
            return {
                text: UiStrings.tr("hint.needsUpdate", root.uiLang),
                accent: true,
                action: "update"
            }
        if (keyboard.lifecycleKind === "missing")
            return {
                text: UiStrings.tr("hint.notInstalled", root.uiLang),
                accent: true,
                action: "install"
            }
        if (keyboard.lifecycleKind === "stopped")
            return {
                text: UiStrings.tr("hint.notRunning", root.uiLang),
                accent: true,
                action: "retry"
            }
        if (keyboard.lifecycleKind === "unavailable")
            return {
                text: UiStrings.tr("hint.keymapUnavailable", root.uiLang),
                accent: true
            }
        if (root.saveFailedNotice)
            // A save that cannot land must not lie: the controls already show the new value, the
            // disk does not have it, and on the next shell start the
            // setting is gone. The notice stands until a save lands —
            // the sound row's "unavailable" precedent: a setting that
            // cannot take effect is never silent.
            return {
                text: UiStrings.tr("hint.saveFailed", root.uiLang),
                accent: true
            }
        if (keyboard.lifecycleKind === "starting" && root.startingNoticeDue)
            return {
                text: UiStrings.tr("hint.starting", root.uiLang),
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

    // Cursor hiding is owned by CursorPolicy (CursorPolicy.qml
    // + CursorPolicy.js), not by the panel's presentation code: one
    // serialized lifecycle for probe, override and restore, so a close that
    // lands before the probe answers cannot leave a session override
    // behind. The binding drives it whatever writer flips
    // `opened` — the bar toggle, close(), or the shell itself.
    CursorPolicy {
        id: cursorPolicy
        targetOpened: root.opened
    }

    function open(payloadJson) {  // Omarchy shell-IPC: summon calls this
        root.opened = true  // and isPluginOpen reads it back
    }

    // Local workaround for a Hyprland limitation (measured at scale 2):
    // the docked panel's exclusive zone registers (reserved = the strip's
    // height) and NEW tiled windows respect it, but Hyprland does not
    // relayout the windows that were tiled while the panel was closed —
    // their bottoms stay behind the strip until something else forces a
    // layout. One config keyword write forces it. The value is read, set
    // one above, and restored on the next tick: at a gap setting of 0
    // the visible cost is a one-frame one-pixel gap.
    //
    // Review-hardened: a nudge arriving while the chain is busy is skipped
    // (a second read in the +1 window would capture the nudged value and
    // strand it for the session), and a read that does not parse aborts
    // the whole chain — a failed probe must not write anything, or it
    // would clobber a nonzero user setting with 0.
    property bool relayoutBusy: false
    // A nudge that arrived mid-chain is QUEUED, not dropped (the
    // cold-audit's finding: a rapid open-close-open left the zone-add
    // nudge skipped and tiled windows under the strip until the next
    // toggle): the chain re-runs from its own restore exit.
    property bool relayoutPending: false
    Timer {
        id: relayoutKickoff
        interval: 150
        repeat: false
        onTriggered: relayoutProbe.running = true
    }
    Process {
        id: relayoutProbe
        property int value: 0
        command: ["hyprctl", "getoption", "-j", "general:gaps_out"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    relayoutProbe.value = JSON.parse(this.text).int || 0
                } catch (error) {
                    root.relayoutBusy = false
                    console.warn("[oskar] cannot read gaps_out; no relayout nudge")
                    return
                }
                // A fresh cycle: this write is the +1 nudge, the next is
                // the restore (flag armed in relayoutSet.onExited).
                relayoutSet.restoring = false
                relayoutSet.command = ["hyprctl", "keyword", "general:gaps_out",
                    String(relayoutProbe.value + 1)]
                relayoutSet.running = true
            }
        }
    }
    Process {
        id: relayoutSet
        property bool restoring: false
        command: []
        onExited: {
            if (!restoring) {
                restoring = true
                relayoutRestore.restart()
            } else {
                root.relayoutBusy = false
                if (root.relayoutPending) {
                    root.relayoutPending = false
                    nudgeHyprlandRelayout()
                }
            }
        }
    }
    Timer {
        id: relayoutRestore
        interval: 60
        repeat: false
        onTriggered: () => {
            relayoutSet.command = ["hyprctl", "keyword", "general:gaps_out",
                String(relayoutProbe.value)]
            relayoutSet.running = true
        }
    }

    // The map itself, once the output is chosen (or given up on): the
    // relayout nudge follows the map, because the exclusive zone it
    // reflows the tiled windows against registers only with a mapped
    // surface — nudging before the map reflows against nothing.
    function showPlaced() {
        placementFallback.stop()
        if (!root.opened || root.placed) return
        root.placed = true
        root.nudgeHyprlandRelayout()
    }
    // A probe that never answers (hyprctl missing, a parse failure) must
    // not leave the panel summoned and unmapped: after this window the
    // panel shows on whatever output it already had, as it always did.
    Timer {
        id: placementFallback
        interval: 300
        repeat: false
        onTriggered: root.showPlaced()
    }

    function nudgeHyprlandRelayout() {
        if (root.mode !== "docked") return
        if (root.relayoutBusy) {
            root.relayoutPending = true
            return
        }
        root.relayoutBusy = true
        relayoutKickoff.restart()
    }

    function close() {  // Omarchy shell-IPC: hide calls this
        root.opened = false  // the shell's toggle pairs the two
    }

    function flip() {
        root.opened = !root.opened  // local toggle (bar hotkey pairs via shell)
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

    // The Super cap's mark. setMode's shape: the health guard so
    // a malformed external edit stands down every writer, and a no-op when
    // the choice already stands — no movement, no config write.
    function setSuperMark(mark) {
        if (!root.configHealthy) return
        if (root.superMark === mark) return
        root.setOverride("superMark", mark)
    }

    // ---- which output, and where on it ----
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
    // the panel is on, not in
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
    // written back. The centre is what gets saved: storing the
    // dragged top-left instead would restore a card dragged near an edge
    // to a different visible spot whenever the
    // preset or the output changed between save and restore.
    function rememberFloatingPosition() {
        var center = { x: card.x + card.width / 2, y: card.y + card.height / 2 }
        var previous = root.floatingCenter
        if (previous && previous.x === center.x && previous.y === center.y) return
        root.floatingCenter = center
        root.geometryState = root.mergedGeometryState(
            { center: root.floatingCenter })
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

    // ---- the emoji page's placement (the emoji-drag ticket) ----
    //
    // The page's x/y are applied here, never bound: a strip drag writes
    // them directly and would destroy any binding (the card's own
    // lesson), so every placement path re-derives from the same rule —
    // with the drag on and a remembered centre, the top-left comes from
    // that CENTRE clamped into the CURRENT overlay (SettingsPlacement's
    // deterministic anchor, the floating card's rule in this window's
    // vocabulary); anything else — the setting off, no centre yet, a
    // degenerate restore — is exactly today's computed leftover centre.
    // A held page-drag owns the placement, exactly as applyFloating
    // Position stands down for a held card drag.
    function applyEmojiPosition() {
        if (!root.emojiOpen) return
        if (emojiPage.dragActive) return
        var size = { w: emojiPage.width, h: emojiPage.height }
        var place = null
        if (root.emojiDrag && root.emojiCenter)
            place = SettingsPlacement.centreRestore(root.emojiCenter, size,
                settingsLayerHost.overlayBox)
        if (!place) place = settingsLayerHost.emojiPlace
        emojiPage.x = place.x
        emojiPage.y = place.y
    }

    // Where a free page-drag lands is remembered as the page's CENTRE —
    // the card's own rule: a centre restores honestly against a changed
    // page size or output, a remembered top-left near an edge did not.
    // The write path is every geometry field's (mergedGeometryState,
    // then one atomic save), and a press that moved nothing writes
    // nothing. No cross-output hand-off here: the page rides the
    // settings layer, one output at a time, and the release keeps
    // whatever the clamp left in this one.
    function rememberEmojiPosition() {
        // Re-clamp BEFORE saving: the drag
        // axis bounds apply on pointer moves, so a geometry change that
        // lands while the pointer stands still mid-drag can leave the
        // page overhanging — release would then remember an off-visible
        // centre and leave the page parked there until the next open.
        // The write-back heals this release and the saved centre alike.
        // Null-guarded: a degenerate or absent bounds
        // skips the clamp and still saves — the next open re-clamps
        // through centreRestore against whatever the visible area is
        // by then.
        var topLeft = SettingsPlacement.clampedTopLeft(
            { x: emojiPage.x, y: emojiPage.y },
            { w: emojiPage.width, h: emojiPage.height },
            emojiPage.dragBounds || { x: 0, y: 0,
                w: settingsLayer.width, h: settingsLayer.height })
        if (topLeft && (topLeft.x !== emojiPage.x
                || topLeft.y !== emojiPage.y)) {
            emojiPage.x = topLeft.x
            emojiPage.y = topLeft.y
        }
        var center = {
            x: emojiPage.x + emojiPage.width / 2,
            y: emojiPage.y + emojiPage.height / 2
        }
        var previous = root.emojiCenter
        if (previous && previous.x === center.x && previous.y === center.y) return
        root.geometryState = root.mergedGeometryState(
            { emojiCenter: center })
        root.saveState()
    }

    // Placement is applied on open (a fresh open re-anchors from the
    // remembered centre, clamped into whatever the current visible area
    // is — a monitor change or a different leftover must not strand it)
    // and re-derived on every change that would otherwise leave stale
    // x/y: the card's own moves, the layer's resizes and the
    // page's size changes.
    onEmojiOpenChanged: {
        if (root.emojiOpen) root.applyEmojiPosition()
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
        root.superMark = effective.superMark
        var soundChanged = root.sound !== effective.sound
        root.sound = effective.sound
        root.followTheme = effective.followTheme
        root.emojiCloseAfterPick = effective.emojiCloseAfterPick
        root.emojiPageSize = effective.emojiPageSize
        root.emojiDrag = effective.emojiDrag
        root.dwellEnabled = effective.dwellEnabled
        root.dwellDelayMs = effective.dwellDelayMs
        root.uiLanguage = effective.uiLanguage
        root.inputProfile = effective.inputProfile
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
        // The emoji page's placement re-derives with the settings that
        // can move it: a page-size edit while the page stands, a drag
        // setting flipped by an external edit.
        root.applyEmojiPosition()
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

    // Missing files are a normal first run: defaults stand, no error.
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
        settingsLayerHost.adoptAppliedColour(name, value)
    }

    // The sparse override map stays behind the panel API: the popover's
    // views ask whether an override exists, they never inspect the map.
    function hasOverride(name) {
        return ConfigFile.owns(root.userOverrides, name)
    }

    // Per-override reset: removing an override drops its key
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

    // Reset-all empties the whole override map — every
    // setting, including the appearance fields the popover hosts and unknown
    // keys a future version wrote. The confirmation
    // is the popover's own inline arm/confirm row, not a system dialog; the
    // arm dies with the override map it was armed against
    // (onUserOverridesChanged) and with the popover itself
    // (onOpenedChanged).
    function clearAllOverrides() {
        if (!root.configHealthy) return
        settingsLayerHost.disarmResetAll()
        root.commitOverrides({})
    }

    // Never replace malformed external text. Once the user fixes it, the
    // watched FileView reloads it and writes become available again.
    function saveOverrides() {
        if (root.configurationError) return
        saves.makeConfigDir()
    }

    function saveState() {
        if (root.stateError) return
        saves.makeStateDir()
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
            root.placed = false
            placementFallback.restart()
            root.moveToPointerScreen(function (pointer, pointerScreen) {
                if (pointerScreen) panel.screen = pointerScreen
                root.applyFloatingPosition()
                root.showPlaced()
            })
            return
        }
        root.placed = false
        placementFallback.stop()
        // A popover left open should not straddle the close: the next open
        // starts clean, and the reset-all confirmation is the popover's own
        // state, so it dies with it. The hex entry and the custom editor's
        // uncommitted draft die with it too — the focus exception and the
        // draft must never outlive the surface that sanctioned them.
        root.endHexEdit()
        root.closeCustomEditor()
        settingsLayerHost.closePopover()
        settingsLayerHost.disarmResetAll()
        root.emojiOpen = false
        languageMenu.close()
        // The relayout nudge is needed in both directions: the zone leaving
        // is as lazy as the zone arriving.
        root.nudgeHyprlandRelayout()
        // Locked Shift is genuinely held down at the device, so closing the
        // panel has to let go of it before the keyboard disappears.
        keyboard.releaseModifiers()
        // The touch observation is per-SUMMON, not per-process: a hidden
        // panel is a session
        // boundary, since the panel is summoned dozens of times a day, and a touch on one monitor must
        // not park release-typing on another for the whole session.
        touchObserved = false
    }

    // The R2 pipelines run as `setsid bash -c "wl-paste | head -c N"`, so
    // the direct child is a session and process-group LEADER and
    // cancellation must kill the whole group: killing only the shell
    // leaves wl-paste and head orphaned with
    // stdout still open, one stalled reader accumulating per attempt.
    function killProcessGroup(proc) {
        var pid = Number(proc.processId)
        if (pid > 0)
            Quickshell.execDetached(["kill", "-9", "--", "-" + String(pid)])
        else
            proc.signal(9)
    }

    function restartProcessGroup(proc) {
        if (proc.running) {
            killProcessGroup(proc)
            proc.running = false
        }
        proc.running = true
    }

    // Panel-local clipboard read (colour field, emoji search — R2). The
    // same force-kill contract as the probe below, by process group. The
    // collector carries the bytes; a late streamFinished from a timed-out
    // read is refused by the settled state machine before anything is
    // inserted, and a stream that never ends is the watchdog's to close.
    Process {
        id: localClipboardRead
        property int seq: 0
        property bool didStart: false
        property bool retiring: false
        // head caps the stream (the security audit): a malicious clipboard
        // owner cannot balloon the shell's memory through the collector —
        // SIGPIPE closes wl-paste past the bound.
        command: ["setsid", "bash", "-c", "wl-paste --no-newline | head -c 65536"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.finishLocalClipboardRead(
                localClipboardRead.seq, this.text)
        }
        onStarted: didStart = true
        onExited: {
            localClipboardRead.didStart = false
            localClipboardRead.retiring = false
            if (root.localReadQueuedTarget !== "") {
                var queued = root.localReadQueuedTarget
                root.localReadQueuedTarget = ""
                startLocalClipboardRead(queued)
            }
        }
    }

    Timer {
        id: localClipboardReadWatchdog
        interval: 500
        repeat: false
        onTriggered: () => {
            var result = ClipboardPaste.readTimedOut(root.clipboardReadState,
                localClipboardRead.seq,
                currentPasteTarget())
            root.clipboardReadState = result.state
            if (result.action === "ignore") return
            if (result.action === "gone") root.markClipboardContentGone()
            // Retire before stopping: the collector's late streamFinished
            // is then refused by the settled state, and while that physical
            // exit is pending another click cannot retag the Process with a
            // newer sequence (the probe watchdog's own rule).
            localClipboardRead.retiring = localClipboardRead.didStart
            if (localClipboardRead.didStart && result.kill)
                root.killProcessGroup(localClipboardRead)
            else
                localClipboardRead.running = false
        }
    }

    // CLIPBOARD watch: event-driven, not a poll. --watch
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
        property bool retiring: false
        command: ["setsid", "bash", "-c", "wl-paste --list-types | head -c 4096"]
        stdout: StdioCollector {
            id: clipboardTypesOut
            waitForEnd: true
        }
        onExited: function (exitCode) {
            // A retired exit is the KILLED run's: its bytes describe a
            // clipboard the seq has already moved past, and applying
            // them would show a stale clipboard value.
            var wasRetired = clipboardTypes.retiring
            clipboardTypes.retiring = false
            if (wasRetired) {
                // The refresh that waited this kill out runs now, with a
                // fresh sequence and a reusable Process.
                if (root.clipboardRefreshQueued) {
                    root.clipboardRefreshQueued = false
                    refreshClipboardPreview()
                }
                return
            }
            root.applyClipboardTypes(clipboardTypesOut.text, clipboardTypes.seq, exitCode)
        }
    }

    Process {
        id: clipboardText
        property int seq: 0
        property bool retiring: false
        // head caps the stream (the security audit): a malicious clipboard
        // owner cannot balloon the shell's memory through the collector —
        // SIGPIPE closes wl-paste past the bound.
        command: ["setsid", "bash", "-c", "wl-paste --no-newline | head -c 65536"]
        stdout: StdioCollector {
            id: clipboardTextOut
            waitForEnd: true
        }
        onExited: function (exitCode) {
            var wasRetired = clipboardText.retiring
            clipboardText.retiring = false
            if (wasRetired) {
                if (root.clipboardRefreshQueued) {
                    root.clipboardRefreshQueued = false
                    refreshClipboardPreview()
                }
                return
            }
            root.applyClipboardText(clipboardTextOut.text, clipboardText.seq,
                exitCode === 0)
        }
    }

    Timer {
        id: clipboardGoneTimer
        interval: 4000
        repeat: false
        onTriggered: root.clipboardContentGone = false
    }

    // Emoji delivery goes through the clipboard, the one channel: the
    // transaction's processes, timers and verdict arms live in
    // EmojiDelivery.qml — the pure
    // machine stays ClipboardPaste.txn*. The panel keeps what a pick is
    // ABOUT: the dispatch facts below (the class derivation at the
    // click), the refusal flashing (flashRefused, the machinery the
    // verdict arms call back through), the usage recording and the
    // delivered pick's settle and close (onPickSettled) — while the
    // txn's own state stays readable under its own name for the paste
    // chip's gate (pasteCurrentContent above) and the hint line's
    // queue-cap flash (hintState above).
    EmojiDelivery {
        id: emojiDelivery

        // The txn's translated refusals name their language here.
        uiLang: root.uiLang
        // The one visible-refusal channel, handed down: the verdict
        // arms flash exactly where the panel's own refusals flash.
        flashRefused: (text, ms) => root.flashRefused(text, ms)
        // The retiring discipline's kill — the panel's own helper.
        killProcessGroup: (proc) => root.killProcessGroup(proc)
        // The pacing/flow facts, from the keyboard's frozen surface.
        pastePacing: keyboard.pastePacing
        pasteFlow: keyboard.pasteFlow
        // The txn's chord goes through keyboard.pasteCurrent with its
        // completed callback — the chordSeq discipline rides in
        // the delivery's own closure.
        pasteChordStart: (wmClass, done) => keyboard.pasteCurrent(wmClass, done)

        // The delivered pick's verdict: usage, the search settle and
        // the close-after-pick read, in the monolith's order — the
        // three panel-side effects the completed arm ran inline.
        onPickSettled: function (emoji) {
            root.recordEmojiSuccess(emoji)
            // The keys go back to the chat the emoji
            // landed in.
            root.emojiPickSettled()
            if (root.emojiCloseAfterPick) root.emojiOpen = false
        }
    }

    // One transient channel for refused clicks and one-shot notices: a
    // refused click must be VISIBLE, in both modes — the paste chip
    // refused under a transaction, the language chip refused under a
    // standing overlay, the share scheduler's give-up, a failed pick.
    // A newer flash replaces a standing one; the duration is the
    // caller's (refusals read fast, informational notices get their
    // beat).
    property string refusedHint: ""
    Timer {
        id: refusedHintTimer
        interval: 1500
        repeat: false
        onTriggered: root.refusedHint = ""
    }
    function flashRefused(text, ms) {
        root.refusedHint = text
        refusedHintTimer.interval = ms > 0 ? ms : 1500
        refusedHintTimer.restart()
    }

    // The share scheduler's give-up, made visible: journal-only would be
    // silence, and the symptom — layouts
    // flipping on focus change — is one of the most visible
    // misbehaviours the panel has. Informational, so it gets a longer
    // beat than a refusal.
    Connections {
        target: keyboard
        function onKeymapShareGivenUp() {
            root.flashRefused(UiStrings.tr("hint.shareFailed", root.uiLang),
                4000)
        }
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
        root.probeDependencies()
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

    // The private saves' machinery — the 700/600 dir makers, the one
    // umask-077 temp+rename writer with its queue and retry, and the
    // per-path failure notices — in PrivateSaves.qml (the structural
    // split's step three). The paths and the maps are bound IN live so
    // the dir makers' exits serialize the newest, exactly as the
    // monolith did; the stand-off guards ride with them (a malformed
    // external edit stops the write inside the component at the same
    // guard line, while the panel's own save entries keep their copy
    // above).
    PrivateSaves {
        id: saves

        configDir: root.configDir
        configPath: root.configPath
        stateDir: root.stateDir
        statePath: root.statePath
        configError: root.configurationError
        stateError: root.stateError
        // Bound live: a dir maker's exit serializes whatever the panel
        // holds at that moment — the monolith's own timing.
        userOverrides: root.userOverrides
        geometryState: root.geometryState
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
            // The env expansions ride through a bash array split on
            // ':' with quoting intact (the audit: the old word-split
            // glob-expanded the values); no XDG_RUNTIME_DIR means no
            // session — the sound is skipped rather than guessed into
            // a world-writable /tmp.
            "[[ -n \"$4\" ]] || exit 1; "
            // Split on ':' with read -ra: a ':'→' '
            // substitution + word splitting would break any XDG entry
            // that itself contains a space.
            + "bases=(); IFS=':' read -ra _dirs <<< \"$2:$3\"; "
            + "for _d in \"${_dirs[@]}\"; do [[ -n \"$_d\" ]] && bases+=(\"$_d\"); done; "
            + "for base in \"${bases[@]}\"; do "
            + "file=$base/sounds/freedesktop/stereo/$1.oga; "
            + "if [ -f \"$file\" ]; then "
            + "out=$4/oskar-keyclick.wav; "
            + "ffmpeg -nostdin -v error -y -i \"$file\" \"$out\" || exit 3; "
            + "printf '%s' \"$out\"; exit 0; "
            + "fi; "
            + "done; exit 1",
            "oskar-sound", soundResolve.eventId,
            Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"),
            Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share",
            Quickshell.env("XDG_RUNTIME_DIR") || ""]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.soundUnavailable = false
                root.soundFile = text.trim()
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 1) {
                root.soundUnavailable = true
                console.warn("[oskar] no '" + soundResolve.eventId
                    + "' event found in the freedesktop sound theme; the key click stays silent")
                return
            }
            if (exitCode !== 0 || exitStatus !== 0) {
                root.soundUnavailable = true
                console.warn("[oskar] could not decode the '" + soundResolve.eventId
                    + "' event sound; the key click stays silent")
                return
            }
            console.log("[oskar] key click sound:", root.soundFile)
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
                console.warn("[oskar] QtMultimedia is not available; the key click sound stays off")
            }
        }
    }

    Process {
        id: depProbe
        // Typing goes through the helper daemon, which has no external
        // commands to check for. The layout tracker still needs hyprctl
        // (devices, getoption), jq (devices JSON), xkbcli (compiling the key
        // caps' symbols), and udevadm (event-driven input hotplug); all come
        // with the packages the install
        // button below pulls in.
        command: ["bash", "-c",
            "command -v hyprctl >/dev/null && command -v jq >/dev/null && command -v xkbcli >/dev/null && command -v udevadm >/dev/null"]
        onExited: (exitCode, exitStatus) => {
            root.depsOk = exitCode === 0 && exitStatus === 0
        }
    }

    Process {
        id: unitProbe
        // Whether the helper's user unit exists at all. Asked each time the
        // helper reads as stopped — an install can land mid-session — and
        // cleared by any connection, which answers for itself.
        command: ["bash", "-c",
            "[ \"$(systemctl --user show oskar.service -p LoadState --value)\" = not-found ]"]
        onExited: (exitCode, exitStatus) => {
            keyboard.serviceMissing = exitCode === 0 && exitStatus === 0
            root.unitKnownInstalled = !keyboard.serviceMissing
        }
    }
    // Once the unit is known to exist, a stopped helper needs no more
    // probes until the next connection; only a missing unit keeps asking.
    property bool unitKnownInstalled: false
    // Asks at once and then every few seconds while the helper is not
    // there — a panel that boots stopped never sees the kind change, and
    // an install that lands mid-session must flip the hint back.
    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: keyboard.lifecycleKind === "stopped"
            || keyboard.lifecycleKind === "missing"
        onTriggered: {
            if (unitProbe.running) return
            if (keyboard.lifecycleKind === "stopped" && root.unitKnownInstalled) return
            unitProbe.running = true
        }
    }
    Connections {
        target: keyboard
        function onServiceConnectedChanged() {
            if (keyboard.serviceConnected) {
                keyboard.serviceMissing = false
                root.unitKnownInstalled = false
            }
        }
    }

    Process {
        id: lifecycleProbe
        // One startup check for the installed lifecycle command (ticket
        // 32): present as /usr/bin/oskar from the package and as
        // ~/.local/bin/oskar after any source install.sh. Reruns are
        // pointless — installation paths do not appear mid-session.
        command: ["bash", "-c",
            "test -x /usr/bin/oskar || test -x \"$HOME/.local/bin/oskar\""]
        onExited: (exitCode, exitStatus) => {
            root.lifecycleCommandAvailable = exitCode === 0 && exitStatus === 0
        }
    }

    Process {
        id: depSetup
        // The app-id is omitted: xdg-terminal-exec resolves the
        // preferred terminal on its own and the title is enough context.
        command: ["xdg-terminal-exec",
            "--title=Fetch OSKar components",
            "omarchy", "pkg", "add", "hyprland", "jq"]
        onExited: (exitCode, exitStatus) => {
            root.depsOk = false
            root.probeDependencies()
        }
    }



    // The height the docked strip needs. In docked mode it is also the
    // window's height and therefore the space the compositor reserves for it;
    // in floating mode the window is anchored to all four edges and the
    // compositor sizes it, so the property is ignored there.
    readonly property real cardHeight: keyboard.implicitHeight + keyboard.cellGap * 2 + dragBar.height
        + (depBanner.visible ? depBanner.height + keyboard.cellGap : 0)
        + tokens.popupPadding / 2

    PanelWindow {
        id: panel
        // The shell contract's one surface flag, gated on the summon's
        // output choice (`placed`) so the first frame is on the right one.
        visible: root.opened && root.placed
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
        color: "#00000000"
        mask: Region {
            item: card
        }

        // The surface has no size until it is mapped, and it changes size again
        // when the panel moves to an output of a different shape — both of
        // which are when a remembered floating position has to be re-applied
        // and re-clamped.
        onWidthChanged: root.applyFloatingPosition()
        onHeightChanged: root.applyFloatingPosition()

        // Never take keyboard focus: the app being typed into keeps it, and
        // the helper's keystrokes land there. Colour-field entry and the
        // armed emoji search are the exceptions, and both live on the
        // settings overlay, not here.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "io.github.vladkarok.oskar"
        WlrLayershell.layer: WlrLayer.Overlay
        // Docked reserves its height along the bottom edge — windows move up
        // rather than being covered, and closing the panel hands the space
        // back (a hidden layer surface reserves nothing). Fullscreen windows
        // ignore layer-shell exclusive zones, so a fullscreen film is
        // overlaid instead; that is the accepted behaviour, not a bug.
        // Floating reserves nothing, exactly as before.
        //
        // The reservation is exact by construction, never transiently wrong:
        // ExclusionMode.Auto derives the zone from this
        // window's own geometry, the bottom anchor keeps the window's bottom
        // edge fixed while `implicitHeight` rebinds, and the layer-shell
        // surface commits the new size and its zone together — so at every
        // commit the reserved space equals the visible strip, and a preset
        // change moves the top edge only. Non-fullscreen tiled windows can
        // therefore never sit under the visible panel; whether a client
        // keeps its internal bottom scroll on resize is its own policy.
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
                : Math.min(panel.width - tokens.popupPadding, keyboard.implicitWidth + keyboard.cellGap * 2) + tokens.popupPadding
            height: root.cardHeight
            x: Math.round((panel.width - width) / 2)
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
            // applyFloatingPosition).
            onXChanged: { root.applyFloatingPosition(); root.applyEmojiPosition() }
            onYChanged: { root.applyFloatingPosition(); root.applyEmojiPosition() }
            onWidthChanged: { root.applyFloatingPosition(); root.applyEmojiPosition() }
            onHeightChanged: { root.applyFloatingPosition(); root.applyEmojiPosition() }

            Item {
                id: dragBar
                width: parent.width
                height: tokens.space(30) + keyboard.cellGap * 3

                // The drag handle: a thin
                // 3px line along the floating bar's top edge, rounded,
                // quiet ink — and ALIVE: while the bar is dragged the line
                // brightens and shortens from both ends. The window-title
                // grammar everyone already reads ("a bar = carry me"),
                // docked hides it with the drag itself. The three-state
                // drawing lives in DragLine.qml — the emoji page's strip
                // wears the same component — and this bar passes its own
                // cellGap proportions in: parity by construction, and the
                // bar's own behaviour is unchanged.
                DragLine {
                    visible: root.mode === "floating"
                    tokens: tokens
                    grabbed: dragArea.pressed
                    carried: dragArea.drag.active
                    hovered: dragArea.containsMouse
                    edgeGap: keyboard.cellGap
                    shortenBy: tokens.space(6)
                    thickness: keyboard.cellGap * 0.35
                    liftBy: Math.round(keyboard.cellGap * 0.25)
                }

                MouseArea {
                    id: dragArea
                    anchors { fill: parent }
                    hoverEnabled: true
                    // Docked is a fixed full-width strip; dragging it off the
                    // bottom edge would fight what the mode means. Floating
                    // is dragged by its bar as before.
                    cursorShape: root.mode === "docked" ? Qt.ArrowCursor : Qt.SizeAllCursor
                    drag.target: root.mode === "docked" ? null : card
                    drag {
                        axis: Drag.XAndYAxis
                        minimumX: 0
                        maximumX: panel.width - card.width
                        minimumY: 0
                        maximumY: panel.height - card.height
                    }
                    // Where the drag lands is state worth keeping,
                    // and a drag the compositor takes away mid-gesture still
                    // leaves the card somewhere — same reasoning as the cancel
                    // path on the key caps. No key can be held by this
                    // MouseArea: it covers the bar, which has no caps in it.
                    onReleased: root.finishDrag()
                    onCanceled: root.finishDrag()
                }

                // The panel's one status line. A swap, not an addition: the
                // line cannot change the card's height, so no failure state
                // ever churns the docked reservation. Text and colour both
                // mirror hintState on the panel
                // root above. When the chips stand beside it, the text
                // shifts left by half the whole notice's width — chips plus
                // the margin to the text — so the notice as a group sits
                // centred.
                // Current-content paste sits on the card (pasteButton below)
                // so its z can outrank the settings/editor dismiss layers.
                // The notice group's RIGHT boundary is noticeEdge below —
                // never an anchor to pasteButton itself, which lives one
                // hierarchy up and cannot be anchored to legally: a
                // cross-hierarchy anchor there emits a QML warning on every
                // re-evaluation.

                // The notice group's right boundary, placed by a plain x
                // binding at the left edge of the rightmost chip that is
                // visible — the paste chip when it stands, else the MODE
                // chip, left of dismiss —
                // minus the gap. pasteButton.x is in CARD coordinates (its
                // parent), so dragBar.x converts it into this space;
                // modeChip is a sibling and needs no conversion. An Item
                // placed by x, not an anchor line: the hint and the chips
                // anchor to THIS sibling unconditionally, no visibility
                // flip can retarget them, and moving the boundary
                // re-evaluates only this binding.
                Item {
                    id: noticeEdge
                    width: 0
                    height: 0
                    x: (pasteButton.visible ? pasteButton.x - dragBar.x
                        : modeChip.x) - keyboard.cellGap * 2
                }

                Text {
                    id: hintText
                    anchors {
                        left: langCtl.right
                        leftMargin: keyboard.cellGap * 2
                        right: noticeEdge.left
                        // The chips' width plus their gap when they stand;
                        // JS margins, never an anchor retarget.
                        rightMargin: serviceActions.visible
                            ? serviceActions.width + keyboard.cellGap * 2 : 0
                        verticalCenter: langCtl.verticalCenter
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
                // belong to. Anchored to the notice boundary so appearing
                // and leaving moves the hint, not the reserved centre
                // place: no height change, no docked reservation churn.
                // Retry is the solid chip — the one action that fixes
                // "not running" — and starts the user unit detached; the
                // socket client's existing repair path reconnects from
                // there. Copy is the outlined chip and exists only on a
                // protocol mismatch, where starting cannot help until the
                // helper is reinstalled; it hands the install command to
                // the clipboard and never runs anything. The chip is
                // deliberately terse: text plus chips must fit the bar at
                Row {
                    id: serviceActions
                    anchors.right: noticeEdge.left
                    anchors.verticalCenter: hintText.verticalCenter
                    spacing: keyboard.cellGap
                    visible: hintState.action !== undefined
                    z: 2

                    Rectangle {
                        width: copyLabel.implicitWidth + keyboard.cellGap * 3
                        height: tokens.space(28)
                        radius: tokens.cornerRadius
                        visible: hintState.action === "update"
                            || hintState.action === "install"
                        color: copyArea.pressed ? Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                        border.width: tokens.normalBorderWidth

                        Text {
                            id: copyLabel
                            anchors { centerIn: parent }
                            text: UiStrings.tr("action.copy", root.uiLang)
                            color: tokens.foreground
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: true  // hint  // heading  // emphasized cap  // section label
                        }

                        MouseArea {
                            id: copyArea
                            anchors { fill: parent }
                            // The 28px failure-path chips grow
                            // like the standing chrome (zero in mouse).
                            anchors.leftMargin: -root.chromeHitGrow28.left
                            anchors.rightMargin: -root.chromeHitGrow28.right
                            anchors.topMargin: -root.chromeHitGrow28.up
                            anchors.bottomMargin: -root.chromeHitGrow28.down
                            onClicked: function (mouse) {
                                root.observePointerSource(mouse.source)
                                root.copyInstallCommand()
                            }
                        }
                    }

                    Rectangle {
                        width: retryLabel.implicitWidth + keyboard.cellGap * 3
                        height: tokens.space(28)
                        radius: tokens.cornerRadius
                        // Nothing to start while no unit is installed.
                        visible: hintState.action !== undefined
                            && hintState.action !== "install"
                        color: retryArea.pressed ? tokens.accent : tokens.foreground

                        Text {
                            id: retryLabel
                            anchors { centerIn: parent }
                            text: UiStrings.tr("action.retry", root.uiLang)
                            color: tokens.background
                            font.family: tokens.fontFamily
                            font.pixelSize: tokens.fontBodySmall
                            font.bold: true  // emphasized cap
                        }

                        MouseArea {
                            id: retryArea
                            anchors { fill: parent }
                            // Growth + observation, copyArea's
                            // own rule.
                            anchors.leftMargin: -root.chromeHitGrow28.left
                            anchors.rightMargin: -root.chromeHitGrow28.right
                            anchors.topMargin: -root.chromeHitGrow28.up
                            anchors.bottomMargin: -root.chromeHitGrow28.down
                            onClicked: function (mouse) {
                                root.observePointerSource(mouse.source)
                                root.retryService()
                            }
                        }
                    }
                }

                // The settings gear. Leftmost on purpose: the
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
                        leftMargin: keyboard.cellGap * 2
                        bottom: parent.bottom
                        bottomMargin: keyboard.cellGap
                    }
                    width: tokens.space(30)
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: gearArea.pressed ? tokens.accent
                        : settingsLayerHost.popoverVisible ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : gearArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(
                        settingsLayerHost.popoverVisible || gearArea.containsMouse
                            ? tokens.accent : tokens.foreground,
                        tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        anchors { centerIn: parent }
                        text: "\u2699"
                        color: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true  // heading
                    }

                    MouseArea {
                        id: gearArea
                        anchors { fill: parent }
                        // The touch target grows invisibly in
                        // the touch profile (negative margins; the drawn
                        // chip never moves), and the press reports its
                        // source so auto can learn touch. In mouse the
                        // growth is exactly zero — byte-today.
                        anchors.leftMargin: -root.chromeHitGrow30.left
                        anchors.rightMargin: -root.chromeHitGrow30.right
                        anchors.topMargin: -root.chromeHitGrow30.up
                        anchors.bottomMargin: -root.chromeHitGrow30.down
                        hoverEnabled: true
                        // The touch answer for glyph-only chrome: a
                        // touch-and-hold names
                        // the glyph the hover otherwise would, and the release
                        // still acts — help-then-action, one gesture, the
                        // click never suppressed.
                        // The hold flag is UNCONDITIONAL and the action
                        // rides release-or-click deduped: on Qt 6.11.2 clicked is
                        // suppressed after an accepted pressAndHold —
                        // so a hold's release must act itself, inside
                        // the cap; and the flag may not depend on the
                        // profile, or a long MOUSE press would lose the
                        // click to the same suppression.
                        property bool touchHeld: false
                        function act(mouse) {
                            root.observePointerSource(mouse.source)
                            // The page and the card are mutually exclusive
                            // leftover-centre surfaces (toggleEmojiPage's
                            // rule); the gear restores the card.
                            root.emojiOpen = false
                            languageMenu.close()
                            if (settingsLayerHost.popoverVisible || root.customEditorField !== "") {
                                root.closeCustomEditor()
                                settingsLayerHost.closePopover()
                            } else {
                                settingsLayerHost.openPopover()
                            }
                        }
                        onPressAndHold: touchHeld = true
                        onReleased: function (mouse) {
                            if (touchHeld
                                    && mouse.x >= 0 && mouse.x <= width
                                    && mouse.y >= 0 && mouse.y <= height)
                                act(mouse)
                            touchHeld = false
                        }
                        onCanceled: touchHeld = false
                        Accessible.role: Accessible.Button
                        Accessible.name: UiStrings.tr("tooltip.settings", root.uiLang)
                        onClicked: function (mouse) { act(mouse) }
                    }
                    HoverTooltip {
                        text: UiStrings.tr("tooltip.settings", root.uiLang)
                        // Hover names the glyph in MOUSE only — in touch
                        // the answer is the hold above: a possibly-synthesized
                        // hover never shows one.
                        hovered: gearArea.containsMouse
                            && root.inputAfford.tooltipHoverShows
                        held: gearArea.touchHeld
                    }
                }

                Rectangle {
                    id: langCtl
                    // The control's shape follows the installed layout count:
                    // one layout hides it — an inert chip is
                    // noise and a false affordance; two toggle directly, the
                    // shape this bar always had; three or more open the
                    // chooser. Grey keeps its old meaning: hidden is
                    // "nothing to switch", not "nobody safe to move".
                    property string shape: LanguageControl.controlState(
                        keyboard.layoutCodes.length,
                        keyboard.switchKeyboards.length)
                    visible: shape !== "hidden"
                    anchors {
                        left: settingsGear.right
                        leftMargin: shape === "hidden" ? 0 : keyboard.cellGap
                        bottom: parent.bottom
                        bottomMargin: keyboard.cellGap
                    }
                    // Collapsed to nothing when hidden, not just invisible:
                    // the hint text anchors to this rectangle's RIGHT edge,
                    // and anchors ignore `visible` — a kept width would
                    // leave a phantom gap and elide the hint that much
                    // sooner on a one-layout seat.
                    width: shape === "hidden"
                        ? 0 : langName.implicitWidth + keyboard.cellGap * 3
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    // Reads as disabled while the panel has no safe device to
                    // switch (see pullLayoutsFromCompositor in Keyboard.qml).
                    // Keyed on the SAME thing that gates the click — the
                    // filtered switch set — because greying on a different
                    // fact made the cap lie: it drew disabled while a click
                    // still moved every device on the seat.
                    color: keyboard.switchKeyboards.length === 0 ? Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                        : langHit.containsMouse ? (langHit.pressed ? tokens.accent : Util.alpha(tokens.foreground, tokens.hoverFillAlpha))
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: langName
                        anchors { centerIn: parent }
                        text: keyboard.activeLayoutName
                        // Same fact as the fill above: the label must not read
                        // live while the fill reads disabled, or the other way.
                        color: keyboard.switchKeyboards.length > 0 ? tokens.foreground : tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true  // hint
                    }

                    MouseArea {
                        id: langHit
                        anchors { fill: parent }
                        // Invisible touch-target growth (zero
                        // in mouse) and the press's source reported to the
                        // auto profile.
                        anchors.leftMargin: -root.chromeHitGrow30.left
                        anchors.rightMargin: -root.chromeHitGrow30.right
                        anchors.topMargin: -root.chromeHitGrow30.up
                        anchors.bottomMargin: -root.chromeHitGrow30.down
                        onClicked: function (mouse) {
                            root.observePointerSource(mouse.source)
                            if (langCtl.shape !== "menu") {
                                keyboard.stepLayout()
                                return
                            }
                            // The settings overlay owns the card's attention
                            // while it stands (the same fact its dismiss
                            // layer keys on): the chooser waits rather than
                            // dropping a menu under another overlay. But a
                            // chip that draws enabled and clicks dead is
                            // the silence class — the wait is SAID, on the hint
                            // line.
                            if (settingsLayerHost.popoverVisible
                                || root.customEditorField !== ""
                                || root.emojiOpen) {
                                root.flashRefused(UiStrings.tr(
                                    "hint.langMenuBlocked", root.uiLang))
                                return
                            }
                            languageMenu.open()
                        }
                    }
                }

                // No size button in the header. The chip shows the
                // CURRENT mode (the language chip's idiom — a label that
                // states where you are, not a mystery icon), one click
                // toggles through the same setMode the Settings row uses
                // (health guard and floating-position restore included),
                // and the Settings row stays for discoverability.
                Rectangle {
                    id: modeChip
                    anchors {
                        right: dismissBtn.left
                        rightMargin: keyboard.cellGap
                        bottom: parent.bottom
                        bottomMargin: keyboard.cellGap
                    }
                    width: modeChipLabel.implicitWidth + keyboard.cellGap * 3
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: modeChipHit.pressed ? tokens.accent
                        : modeChipHit.containsMouse
                            ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth

                    Text {
                        id: modeChipLabel
                        anchors { centerIn: parent }
                        text: UiStrings.tr(root.mode === "docked"
                            ? "settings.mode.docked" : "settings.mode.floating",
                            root.uiLang)
                        color: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true  // hint
                    }

                    MouseArea {
                        id: modeChipHit
                        anchors { fill: parent }
                        // Invisible touch-target growth (zero
                        // in mouse) and the press's source reported.
                        anchors.leftMargin: -root.chromeHitGrow30.left
                        anchors.rightMargin: -root.chromeHitGrow30.right
                        anchors.topMargin: -root.chromeHitGrow30.up
                        anchors.bottomMargin: -root.chromeHitGrow30.down
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        Accessible.role: Accessible.Button
                        Accessible.name: UiStrings.tr("mode.chip.tooltip", root.uiLang)
                        onClicked: function (mouse) {
                            root.observePointerSource(mouse.source)
                            root.setMode(
                                root.mode === "docked" ? "floating" : "docked")
                        }
                    }
                    // The seam's pinned per-control decision for TEXT
                    // chrome: the tooltip is hidden on touch — its label
                    // already states the mode, and the hide is ENFORCED by
                    // the tooltipHoverShows gate below: a
                    // synthesized hover may follow a finger, so hiding must
                    // not rely on the absence of a real hover. No hold arm: the hold
                    // vocabulary belongs to input, not chrome help.
                    HoverTooltip {
                        text: UiStrings.tr("mode.chip.tooltip", root.uiLang)
                        // Text chrome: hidden under touch, enforced by the
                        // table's own tooltipTextChrome rule, not assumed.
                        hovered: modeChipHit.containsMouse
                            && root.inputAfford.tooltipHoverShows
                    }
                }

                Rectangle {
                    id: dismissBtn
                    anchors {
                        right: parent.right
                        rightMargin: keyboard.cellGap * 2
                        bottom: parent.bottom
                        bottomMargin: keyboard.cellGap
                    }
                    width: tokens.space(30)
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: dismissHit.pressed ? tokens.urgent
                        : dismissHit.containsMouse ? Util.alpha(tokens.urgent, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: dismissHit.containsMouse ? Util.alpha(tokens.urgent, tokens.pressedFillAlpha) : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: dismissGlyph
                        anchors { centerIn: parent }
                        text: "\u00d7"
                        color: dismissHit.containsMouse ? tokens.urgent : tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: dismissHit
                        anchors { fill: parent }
                        // Growth + observation + the glyph
                        // chrome's touch-and-hold tooltip, the gear's own
                        // rule.
                        anchors.leftMargin: -root.chromeHitGrow30.left
                        anchors.rightMargin: -root.chromeHitGrow30.right
                        anchors.topMargin: -root.chromeHitGrow30.up
                        anchors.bottomMargin: -root.chromeHitGrow30.down
                        hoverEnabled: true
                        // The gear site's dedupe rule: the hold flag
                        // unconditional, the action on release-inside or
                        // click (Qt suppresses clicked after an accepted
                        // hold).
                        property bool touchHeld: false
                        function act(mouse) {
                            root.observePointerSource(mouse.source)
                            root.close()  // dismiss
                        }
                        onPressAndHold: touchHeld = true
                        onReleased: function (mouse) {
                            if (touchHeld
                                    && mouse.x >= 0 && mouse.x <= width
                                    && mouse.y >= 0 && mouse.y <= height)
                                act(mouse)
                            touchHeld = false
                        }
                        onCanceled: touchHeld = false
                        Accessible.role: Accessible.Button
                        Accessible.name: UiStrings.tr("tooltip.closeKeyboard", root.uiLang)
                        onClicked: function (mouse) { act(mouse) }
                    }
                    HoverTooltip {
                        text: UiStrings.tr("tooltip.closeKeyboard", root.uiLang)
                        hovered: dismissHit.containsMouse
                            && root.inputAfford.tooltipHoverShows
                        held: dismissHit.touchHeld
                    }
                }
            }

            Keyboard {
                id: keyboard
                theme: tokens
                uiScale: root.sizeScale
                // What the Super cap draws: the panel resolves
                // override over default; the keyboard picks the arm with the
                // pure choice in KeyboardLayout.js, so an unknown value and
                // an absent Omarchy font both land on the word, never a
                // blank cap.
                superMark: root.superMark
                // Dwell-to-type: the caps' rest-to-type
                // behaviour and its delay, resolved override over default
                // above and handed down as one voice — the keyboard owns
                // the machine, the panel owns the setting.
                dwellEnabled: root.dwellEnabled
                dwellDelayMs: root.dwellDelayMs
                // The input profile: the panel resolves the
                // setting over the observation (InputProfile.resolve) and
                // hands the EFFECTIVE profile down — the keyboard owns the
                // typing semantics, the panel owns the fact. The caps'
                // presses report their source back so a touch anywhere on
                // the grid teaches auto, the same fact the header chips
                // observe.
                effectiveInputProfile: root.effectiveInputProfile
                onPointerSourceObserved: function (source) {
                    root.observePointerSource(source)
                }
                // The persisted group feeds LayoutDevices' restart
                // fallback; every acknowledged configure refreshes it.
                rememberedLayoutGroup: root.rememberedLayoutGroup
                rememberedLayoutDevice: root.rememberedLayoutDevice
                onGroupConfirmed: function (group) {
                    root.recordLayoutGroup(group)
                }
                onLayoutDeviceNamed: function (name) {
                    root.recordLayoutDevice(name)
                }
                // The ☺ cap toggles the panel's own emoji page: open on
                // press, dismiss on a second press. The keyboard stays
                // mapped and clickable underneath — that is the point.
                onEmojiCapActivated: root.toggleEmojiPage()
                // While the page stands AND the search is armed the
                // keys feed it and reach nothing else — a focus
                // change disarms, a click on the field re-arms. The binding
                // (not an assignment) is what ends the interception on every
                // close route — the page dies with emojiOpen by whatever
                // hand closed it. The Esc cap closes the page like the ☺ cap
                // does; every other intercepted key only moves the query.
                searchMode: root.emojiSearchActive
                onSearchInput: function (action, text) {
                    root.applyEmojiSearchInput(action, text)
                }
                // Everything the card spends on its own padding is width the
                // grid cannot have, so a large preset on a narrow output
                // shrinks to fit rather than running off the card.
                availableWidth: panel.width - tokens.popupPadding - keyboard.cellGap * 2
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top
                    topMargin: dragBar.height + keyboard.cellGap
                }
                onDismissalAsked: root.close()
                // The click follows the press, wherever the press came from in
                // the grid — letters, arrows, modifiers, caps. UI actions
                // (close, language, emoji) are not keystrokes and stay quiet.
                onKeyPressed: root.playKeyClick()
            }

            Rectangle {
                id: depBanner
                visible: !root.depsOk
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: keyboard.bottom; bottomMargin: 0  // strip begins here
                    topMargin: keyboard.cellGap
                }
                width: keyboard.gridWidthUnits
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
                    text: UiStrings.tr(depSetup.running
                        ? "banner.deps.fetching" : "banner.deps.missing",
                        root.uiLang)
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
                    width: setupText.implicitWidth + tokens.spacingLg
                    height: tokens.space(28)
                    radius: tokens.cornerRadius
                    color: setupHit.pressed ? tokens.accent : tokens.foreground

                    Text {
                        id: setupText
                        anchors { centerIn: parent }
                        text: UiStrings.tr(depSetup.running
                            ? "banner.deps.busy" : "banner.deps.setup",
                            root.uiLang)
                        color: tokens.background
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: setupHit
                        anchors { fill: parent }
                        enabled: !depSetup.running
                        onClicked: root.setupDependencies()
                    }
                }
            }


            // Current-content paste: the reserved top-centre
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
                    bottomMargin: keyboard.cellGap
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
                    anchors { centerIn: parent }
                    width: Math.min(implicitWidth, parent.width - tokens.space(12))
                    text: root.clipboardPreview
                    // PlainText, always (the security audit): AutoText
                    // renders rich clipboard content — a text/plain
                    // payload with a remote <img> made the preview issue
                    // a network request. A preview displays data; it
                    // never interprets it.
                    textFormat: Text.PlainText
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
                    anchors { centerIn: parent }
                    width: tokens.space(14)
                    height: tokens.space(16)

                    Rectangle {
                        anchors { horizontalCenter: parent.horizontalCenter }
                        y: parent.height * 0.16
                        width: parent.width * 0.72
                        height: parent.height * 0.78
                        radius: Math.max(1, tokens.space(2))
                        color: "#00000000"
                        border.color: pasteArea.containsMouse && root.pasteEnabled
                            ? tokens.accent : tokens.foreground
                        border.width: tokens.normalBorderWidth
                    }
                    Rectangle {
                        anchors { horizontalCenter: parent.horizontalCenter }
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
                    anchors { fill: parent }
                    // Growth (zero in mouse) + observation +
                    // the glyph chrome's touch-and-hold tooltip.
                    anchors.leftMargin: -root.chromeHitGrow30.left
                    anchors.rightMargin: -root.chromeHitGrow30.right
                    anchors.topMargin: -root.chromeHitGrow30.up
                    anchors.bottomMargin: -root.chromeHitGrow30.down
                    hoverEnabled: true
                    enabled: root.pasteEnabled
                    property bool touchHeld: false
                    // The gear site's dedupe rule (Qt suppresses
                    // clicked after an accepted hold): flag unconditional,
                    // release-inside acts.
                    onPressAndHold: touchHeld = true
                    onReleased: function (mouse) {
                        if (touchHeld
                                && mouse.x >= 0 && mouse.x <= width
                                && mouse.y >= 0 && mouse.y <= height) {
                            root.observePointerSource(mouse.source)
                            root.pasteCurrentContent()
                        }
                        touchHeld = false
                    }
                    onCanceled: touchHeld = false
                    Accessible.role: Accessible.Button
                    Accessible.name: UiStrings.tr("access.paste", root.uiLang)
                    onClicked: function (mouse) {
                        root.observePointerSource(mouse.source)
                        root.pasteCurrentContent()
                    }
                }
                HoverTooltip {
                    text: UiStrings.tr("tooltip.paste", root.uiLang)
                    hovered: pasteArea.containsMouse
                        && root.inputAfford.tooltipHoverShows
                    held: pasteArea.touchHeld
                }
            }

            // The >=3-layout chooser, card-local like the paste
            // chip so its z outranks keys and bar. The catch area underneath
            // eats the everywhere-outside click — the same contract the
            // settings popover keeps with its own layer.
            MouseArea {
                anchors { fill: parent }
                enabled: languageMenu.opened
                z: 39
                onClicked: languageMenu.close()
            }

            Rectangle {
                id: languageMenu
                property bool opened: false
                property var entries: []
                property real anchorX: 0
                function open() {
                    // Rebuilt from live state every time: a configure that
                    // ran while it stood closed must not leave a stale list,
                    // and the active flag is the group at open time.
                    entries = LanguageControl.menuEntries(
                        keyboard.layoutCodes, keyboard.layoutTitles,
                        keyboard.groupCursor)
                    anchorX = langCtl.mapToItem(card, 0, 0).x
                    opened = true
                }
                function close() { opened = false }

                visible: opened && root.opened
                z: 40
                x: Math.max(keyboard.cellGap,
                    Math.min(anchorX, parent.width - width - keyboard.cellGap))
                // Drops INTO the card over the grid, under the bar — the
                // settings popover's own pattern. Anything placed above the
                // chip is outside the card, and the panel window's input
                // mask is the card rect: docked, a menu up there renders
                // off-surface and vanishes; floating, it renders but sits
                // outside the mask, so its rows cannot even be clicked.
                y: dragBar.height + keyboard.cellGap
                width: menuList.childrenRect.width + keyboard.cellGap * 4
                height: menuList.childrenRect.height + keyboard.cellGap * 2
                radius: tokens.cornerRadius
                color: tokens.popupsBackground
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Column {
                    id: menuList
                    x: keyboard.cellGap * 2
                    y: keyboard.cellGap
                    spacing: keyboard.cellGap / 2

                    Repeater {
                        model: languageMenu.entries
                        Rectangle {
                            property var entry: modelData
                            // Live, not the flag baked at open(): the group
                            // can move while the menu stands — a physical
                            // switch, a shell widget — and both the armed
                            // row and the click guard must follow the seat,
                            // not the moment the menu opened.
                            property bool current: entry.group
                                === keyboard.groupCursor
                            width: menuRowLabel.implicitWidth + keyboard.cellGap * 2
                            height: tokens.space(30)
                            radius: tokens.cornerRadius
                            // The current group reads as armed: accent fill,
                            // knocked-out text — the locked-modifier idiom.
                            color: current ? tokens.accent
                                : menuRowHit.containsMouse
                                    ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                                    : "transparent"
                            MouseArea {
                                id: menuRowHit
                                anchors { fill: parent }
                                hoverEnabled: true
                                Accessible.role: Accessible.Button
                                Accessible.name: current
                                    ? UiStrings.tr("access.currentLayout",
                                        root.uiLang, [entry.title])
                                    : UiStrings.tr("access.switchTo",
                                        root.uiLang, [entry.title])
                                onClicked: {
                                    languageMenu.close()
                                    if (!current)
                                        keyboard.switchToGroup(entry.group)
                                }
                            }
                            Text {
                                id: menuRowLabel
                                anchors {
                                    verticalCenter: parent.verticalCenter
                                    left: parent.left
                                    leftMargin: keyboard.cellGap
                                }
                                text: entry.title
                                color: current ? tokens.background
                                    : tokens.foreground
                                font.family: tokens.fontFamily
                                font.pixelSize: tokens.fontBodySmall
                                font.bold: current
                            }
                        }
                    }
                }
            }
        }
    }

    // One settings overlay: separate PanelWindows for the popover/editor
    // fail to remap after the first hide (gear opens once, then needs a
    // shell restart), so this window stays mapped while the keyboard is
    // open; the mask is
    // empty until settings open, then leftover ∪ the card so Custom on
    // the band still receives clicks without a bounding-box over keys.
    PanelWindow {
        id: settingsLayer
        visible: root.opened && root.placed  // overlay window rides the same gate
        screen: panel.screen
        color: "#00000000"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "io.github.vladkarok.oskar.settings"
        WlrLayershell.layer: WlrLayer.Overlay
        // Two sanctioned exceptions, never at once: a colour field being
        // typed and the armed emoji search.
        // Each primes Exclusive for 75 ms to acquire the compositor's
        // focus, then settles OnDemand; every other state — disarmed
        // search, closed page, unedited colours — is None, so every
        // disarm path (the activewindow watcher, a delivered pick, the
        // Esc caps, physical Escape, page close) restores the
        // never-takes-focus contract by binding, not by bookkeeping.
        // Hex editing wins the tie: opening it disarms the search.
        WlrLayershell.keyboardFocus: root.hexEditing
            ? (root.hexFocusPrimed ? WlrKeyboardFocus.OnDemand
                                   : WlrKeyboardFocus.Exclusive)
            : root.emojiSearchActive
                ? (root.emojiFocusPrimed ? WlrKeyboardFocus.OnDemand
                                         : WlrKeyboardFocus.Exclusive)
                : WlrKeyboardFocus.None

        // A resize of the overlay (a screen change) is one of the facts
        // the emoji page's placement re-derives from — the remembered
        // centre clamps into whatever the current visible area is.
        onWidthChanged: root.applyEmojiPosition()
        onHeightChanged: root.applyEmojiPosition()

        // The settings content itself — the leftover geometry engine,
        // the input mask, the everywhere-outside dismiss area, the
        // settings popover and the custom colour editor — lives in
        // SettingsLayer.qml. This
        // window keeps what only a window can hold: the surface flags,
        // the focus contract above, and the mask binding below, fed
        // from the component. The emoji page and the two focus sinks
        // stay direct children here: the page is not a settings
        // surface (it keeps z: 1 over the host's z: 0 base, exactly as
        // it stood over the dismiss area), and the sinks are
        // endHexEdit's parking spots.
        mask: settingsLayerHost.inputMask

        SettingsLayer {
            id: settingsLayerHost
            anchors.fill: parent
            z: 0
            panel: root
            tokens: tokens
            card: card
            emojiPage: emojiPage
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

        // The panel's own emoji page, hosted by the
        // same leftover-centre mechanism as the card and the editor. The
        // keyboard underneath stays live — the page rides the overlay
        // window, never the key grid.
        EmojiPage {
            id: emojiPage
            tokens: tokens
            pageSize: root.emojiPageSize
            usageRecords: root.emojiUsage
            skinTone: root.emojiSkinTone
            layoutCode: keyboard.activeLayoutCode
            tooltipHoverShows: root.inputAfford.tooltipHoverShows === true
            uiLang: root.uiLang
            hostWidth: settingsLayerHost.leftoverBox.w
            hostHeight: settingsLayerHost.leftoverBox.h
            // Placement is the panel's (applyEmojiPosition) — x/y are
            // written, never bound, because a strip drag would destroy
            // any binding (the card's own lesson). The drag's clamp is
            // the LAYER, not the leftover: free placement may cover the
            // keyboard band.
            dragEnabled: root.emojiDrag
            // x/y included: the placement
            // module's validBox refuses a bounds without them, and the
            // MouseArea clamp reads only w/h — both consumers fed from
            // the one shape.
            dragBounds: ({ x: 0, y: 0,
                w: settingsLayer.width, h: settingsLayer.height })
            onDragSettled: root.rememberEmojiPosition()
            onWidthChanged: root.applyEmojiPosition()
            onHeightChanged: root.applyEmojiPosition()
            z: 1
            visible: root.emojiOpen
            // The page's presses join the input-profile
            // observation, the caps' and the header chips' own rule.
            onPointerSourceObserved: function (source) {
                root.observePointerSource(source)
            }
            // One click is one send to the focused client. The page closes
            // only after helper success when the preference asks it to;
            // usage likewise records acknowledged delivery, never a click
            // an unready or refusing helper did not deliver.
            onEmojiChosen: function (entry, applyTone) {
                var delivered = applyTone
                    ? EmojiGrid.entryForTone(entry, root.emojiSkinTone,
                        EmojiGrid.allEntries()) : entry
                // While the search is armed the overlay holds
                // keyboard focus, and a delivery must land in the client
                // that focus returns to — so the arm drops BEFORE the
                // helper or the clipboard chord is asked for anything.
                // The binding's None makes the compositor refocus the
                // last window ahead of the first keystroke. On a refused
                // send the search stays disarmed; a field click re-arms it.
                if (emojiPage.searchArmed) emojiPage.searchArmed = false
                // ONE route — the clipboard transaction. The typed
                // delivery routes (keysym taps, Unicode composition) are
                // gone from the protocol and the panel alike; the
                // byte-exact channel is used for every pick, and the
                // transaction's own queue serializes them (three wait,
                // the fourth refuses out loud).
                // The class is derived ONCE, here at the
                // click — request() takes it as a fact of the pick and
                // never re-derives: the derivation runs ahead of
                // the delivery's own gate, so it stays an idempotent
                // refresh of the same memory the event
                // stream keeps.
                emojiDelivery.request(delivered.emoji,
                    root.focusedClientClass())
            }
            onSkinToneChosen: function (tone) { root.chooseEmojiSkinTone(tone) }
            onDismissed: root.emojiOpen = false
            // Physical typing while the search is armed. The
            // page routed the raw event through EmojiGrid.searchKeyAction;
            // what lands here is the same action the caps would have sent.
            onPhysicalSearchInput: function (action, text) {
                root.applyEmojiSearchInput(action, text)
            }
        }
    }
}
