import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Config.js" as ConfigFile

Item {
    id: root

    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool dependenciesReady: true

    // ---- configuration ----
    //
    // One JSON file at $XDG_CONFIG_HOME/omarchy-osk/config.json is both the
    // documented user config and the persisted state; there is no second
    // state file. The file is read at startup and written when state changes;
    // anything missing or malformed in it falls back to the documented
    // defaults (spec-v1 §10) rather than failing to start.
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
        || ((Quickshell.env("HOME") || "") + "/.config")) + "/omarchy-osk"
    readonly property string configPath: configDir + "/config.json"

    // Geometry (spec-v1 §7). Docked — the default, because it needs no
    // positioning decision from someone who just installed the plugin —
    // reserves a full-width strip along the bottom edge so windows move up
    // instead of being covered; floating overlays and is dragged around.
    // `position` and `size_preset` are floating-mode state, persisted here
    // but only given their UI by the floating ticket.
    property string mode: ConfigFile.defaults().mode
    property var floatingPosition: null
    property string sizePreset: "medium"

    // Size presets (spec-v1 §7): a short cycle from a button, not a resize
    // handle. `medium` is the geometry the keyboard shipped with and the
    // smallest of the three — the presets only go up, because the hit targets
    // are already sized for touch at `medium` and a smaller preset would
    // trade that away. An unknown name in the config file lands on `medium`,
    // which is what `indexOf` returning -1 already does below.
    readonly property var sizePresetOrder: ["medium", "large", "x-large"]
    readonly property var sizePresetScales: ({ "medium": 1.0, "large": 1.2, "x-large": 1.45 })
    readonly property var sizePresetLabels: ({ "medium": "M", "large": "L", "x-large": "XL" })
    readonly property real sizeScale: root.sizePresetScales[root.sizePreset] || 1.0

    function cycleSizePreset() {
        var index = root.sizePresetOrder.indexOf(root.sizePreset)
        root.sizePreset = root.sizePresetOrder[(index + 1) % root.sizePresetOrder.length]
        // A bigger card can now hang off the edge it was dragged near.
        root.applyFloatingPosition()
        root.saveConfig()
    }

    // Key click sound: the freedesktop sound theme's event sound, off by
    // default — the stated use case is watching a film, and the mouse already
    // makes a click.
    property bool sound: false
    // v1 escape hatch for the independent colour schema (spec-v1 §8); it
    // follows the theme and does nothing else yet, but is persisted so the
    // key exists from the start.
    property bool followTheme: true
    // Keys the config file carries that v1 does not know about, preserved so
    // the next write does not eat them.
    property var configExtra: ({})
    // Absolute path of the PCM copy the click effect plays; empty until
    // resolved or when the theme has no such event.
    property string soundFile: ""

    // Every colour, font, radius and spacing the panel draws with comes from
    // here, and from nowhere else (spec-v1 §8). Following the theme is what a
    // plain binding through it already does — the shell reassigns the shared
    // tokens on a theme switch and the keyboard redraws where it stands, with
    // no restart, no keymap compile and no reconnection, because none of that
    // is on this path. `follow_theme: false` is the one thing that needs code.
    Theme {
        id: tokens
        follow: root.followTheme
    }

    function checkDependencies() {
        dependencyCheck.running = true
    }

    function installDependencies() {
        if (dependencyInstall.running) return
        dependencyInstall.running = true
    }

    // Hyprland hides the pointer while keys are being pressed, and the keys this
    // panel sends are real ones, so the cursor vanished under the very finger
    // aiming it. Suspending that behaviour while the keyboard is on screen keeps
    // it for ordinary typing, where it is wanted.
    //
    // Applied with `hyprctl eval` and Hyprland's Lua config call: `hyprctl
    // keyword` refuses outright under the Lua parser ("keyword can't work with
    // non-legacy parsers. Use eval."). It only changes the running session, so a
    // config reload restores the user's setting even if the shell dies with the
    // panel open and never runs the restore below.
    property string cursorHideSetting: ""

    function suspendCursorHiding() {
        cursorHideProbe.running = false
        cursorHideProbe.running = true
    }

    function restoreCursorHiding() {
        if (!cursorHideSetting) return
        Quickshell.execDetached(["hyprctl", "eval",
            "hl.config({ cursor = { hide_on_key_press = " + cursorHideSetting + " } })"])
        cursorHideSetting = ""
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
        if (root.mode === newMode) return
        root.mode = newMode
        // The docked pin releases here, so the card falls back to whatever x/y
        // it last had; put it where floating actually left it.
        root.applyFloatingPosition()
        root.saveConfig()
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

    // Floating position is stored local to whatever output the panel is on,
    // not in compositor coordinates: the panel follows the pointer's monitor at
    // open, so a global position would put it half off a differently-sized
    // second screen. Re-clamped on every application, because the output, the
    // preset or the theme may all have changed since it was written.
    function applyFloatingPosition() {
        if (root.mode !== "floating") return
        if (!root.floatingPosition) return
        if (panel.width <= 0 || panel.height <= 0) return
        card.x = root.clamp(root.floatingPosition.x, 0, panel.width - card.width)
        card.y = root.clamp(root.floatingPosition.y, 0, panel.height - card.height)
    }

    // A press on the bar that moved nothing is still a release, and every save
    // is a blocking atomic write — so only a position that actually changed is
    // written back.
    function rememberFloatingPosition() {
        var previous = root.floatingPosition
        if (previous && previous.x === card.x && previous.y === card.y) return
        root.floatingPosition = { x: card.x, y: card.y }
        root.saveConfig()
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

    // Read once at startup. Per-key fallbacks live in Config.js; a file this
    // cannot learn from leaves the panel on the documented defaults.
    function loadConfig() {
        var parsed = ConfigFile.parse(configFile.text())
        root.mode = parsed.mode
        root.floatingPosition = parsed.position
        // Config.js accepts any non-empty string for the preset; the panel is
        // where the actual preset names live, so an unknown one becomes the
        // default here rather than leaving the button with nothing to draw.
        root.sizePreset = root.sizePresetOrder.indexOf(parsed.sizePreset) === -1
            ? "medium" : parsed.sizePreset
        root.sound = parsed.sound
        root.followTheme = parsed.followTheme
        root.configExtra = parsed.extra
        if (root.sound) root.resolveSoundFile()
    }

    // Writes the whole current state through Config.js. The directory is
    // made first because on a first run it does not exist yet; mkdir -p is
    // idempotent and the save itself is rare (state changes), so the extra
    // process is cheaper than maintaining directory-creation logic in QML.
    function saveConfig() {
        configDirMaker.running = true
    }

    function resolveSoundFile() {
        // Stop first: a Process that is already running ignores `running =
        // true` and would keep the previous lookup's command (see the same
        // dance in Keyboard.qml for the keycap pipeline).
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
            // With `follow_theme: false` the tokens are held at whatever the
            // theme was the first time the keyboard was shown; see Theme.qml
            // for why the snapshot is taken here and not at load. A no-op
            // once taken, and a no-op entirely while following.
            if (!root.followTheme) tokens.freeze()
            root.suspendCursorHiding()
            root.moveToPointerScreen(function (pointer, pointerScreen) {
                if (pointerScreen) panel.screen = pointerScreen
                root.applyFloatingPosition()
            })
            return
        }
        root.restoreCursorHiding()
        // A locked modifier is genuinely held down at the device, so closing
        // the panel has to let go of it. Otherwise the keyboard disappears and
        // the session carries on as though Ctrl were taped down.
        keyboard.releaseModifiers()
    }

    // Reads the current value before overriding it, so the user's own choice is
    // what gets restored rather than a guess.
    Process {
        id: cursorHideProbe
        command: ["hyprctl", "getoption", "cursor:hide_on_key_press", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var enabled = false
                try {
                    // hyprctl reports this one as {"bool": true}; older builds
                    // used "int", so accept either rather than silently reading
                    // undefined and deciding the option is off.
                    var parsed = JSON.parse(text)
                    enabled = parsed.bool === true || parsed.int === 1
                } catch (error) {
                    return
                }
                if (!enabled) return
                root.cursorHideSetting = "true"
                Quickshell.execDetached(["hyprctl", "eval",
                    "hl.config({ cursor = { hide_on_key_press = false } })"])
            }
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

    Component.onCompleted: {
        root.loadConfig()
        root.checkDependencies()
    }

    // The one config file. The first read is blocking so the panel's geometry
    // follows the file before anything is shown; writes are blocking too, so
    // two state changes in quick succession cannot write out of order, and
    // atomic so a power loss mid-write leaves either the old file or the new
    // one, never a torn one. A missing file is the normal first run, so its
    // load error is not printed.
    FileView {
        id: configFile
        path: root.configPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
    }

    Process {
        id: configDirMaker
        command: ["mkdir", "-p", root.configDir]
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("[osk] could not create", root.configDir, "- configuration not saved")
                return
            }
            configFile.setText(ConfigFile.serialize({
                mode: root.mode,
                position: root.floatingPosition,
                sizePreset: root.sizePreset,
                sound: root.sound,
                followTheme: root.followTheme,
                extra: root.configExtra
            }))
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
            onStreamFinished: root.soundFile = text.trim()
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 1) {
                console.warn("[osk] no '" + soundResolve.eventId
                    + "' event found in the freedesktop sound theme; the key click stays silent")
                return
            }
            if (exitCode !== 0 || exitStatus !== 0) {
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
            if (status === Loader.Error)
                console.warn("[osk] QtMultimedia is not available; the key click sound stays off")
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
        // and re-clamped.
        onWidthChanged: root.applyFloatingPosition()
        onHeightChanged: root.applyFloatingPosition()

        // The whole point: never take keyboard focus, so the app window
        // you're typing into keeps it, and the helper's keystrokes land
        // there. Clicks on the keys still work fine with keyboardFocus: None
        // — only keyboard input routing is refused at the compositor level.
        WlrLayershell.namespace: "io.github.vladkarok.osk"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // Docked reserves its height along the bottom edge — windows move up
        // rather than being covered, and closing the panel hands the space
        // back (a hidden layer surface reserves nothing). Fullscreen windows
        // ignore layer-shell exclusive zones, so a fullscreen film is
        // overlaid instead; that is the accepted behaviour, not a bug.
        // Floating reserves nothing, exactly as before.
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
            radius: root.mode === "docked" ? 0 : tokens.cornerRadius
            color: tokens.popupsBackground
            borderSpec: tokens.cardBorderSpec

            // Docked pins the card into the strip it fills. Re-asserted here
            // rather than bound inline, because dragging in floating mode
            // writes x/y directly and destroys whatever binding was there —
            // a plain inline binding would leave the docked strip stranded
            // wherever it was last dragged.
            Binding { target: card; property: "x"; value: 0; when: root.mode === "docked" }
            Binding { target: card; property: "y"; value: 0; when: root.mode === "docked" }

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

                Text {
                    anchors {
                        horizontalCenter: parent.horizontalCenter
                        verticalCenter: languageSwitch.verticalCenter
                    }
                    text: root.mode === "docked"
                        ? "\u2328 Docked \u00b7 Double press Shift/Ctrl/Alt/Super to lock"
                        : "\u2328 Drag to move \u00b7 Double press Shift/Ctrl/Alt/Super to lock"
                    color: tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                    z: 1
                }

                Rectangle {
                    id: languageSwitch
                    anchors {
                        left: parent.left
                        leftMargin: keyboard.gapPx * 2
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

                // The size presets, cycled (spec-v1 §7). A button rather than a
                // resize handle: free-form resizing is a lot of state for
                // something operated one-handed from a couch, and a corner grip
                // is the wrong control for that posture. The label shows the
                // preset now in force, not the next one — the keyboard in front
                // of the user is the preview of what the next click does.
                Rectangle {
                    id: sizeButton
                    anchors {
                        right: modeButton.left
                        rightMargin: keyboard.gapPx
                        bottom: parent.bottom
                        bottomMargin: keyboard.gapPx
                    }
                    width: Math.max(tokens.space(30), sizeLabel.implicitWidth + keyboard.gapPx * 3)
                    height: tokens.space(30)
                    radius: tokens.cornerRadius
                    color: sizeArea.pressed ? tokens.accent
                        : sizeArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: sizeArea.containsMouse ? Util.alpha(tokens.accent, tokens.pressedFillAlpha) : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth
                    z: 2

                    Text {
                        id: sizeLabel
                        anchors.centerIn: parent
                        text: root.sizePresetLabels[root.sizePreset] || "M"
                        color: tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: true
                    }

                    MouseArea {
                        id: sizeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.cycleSizePreset()
                    }
                }

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
        }
    }
}
