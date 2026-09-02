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
    // Absolute path of the resolved key-click sound; empty until looked up or
    // when the theme has no such event.
    property string soundFile: ""

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
        root.saveConfig()
    }

    // Read once at startup. Per-key fallbacks live in Config.js; a file this
    // cannot learn from leaves the panel on the documented defaults.
    function loadConfig() {
        var parsed = ConfigFile.parse(configFile.text())
        root.mode = parsed.mode
        root.floatingPosition = parsed.position
        root.sizePreset = parsed.sizePreset
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
            root.suspendCursorHiding()
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

    // Resolves the freedesktop sound theme's file for the click exactly once,
    // when the sound is on at startup — never per keystroke. Looked up through
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
            + "[ -f \"$file\" ] && { printf '%s' \"$file\"; exit 0; }; "
            + "done; exit 1",
            "omarchy-osk-sound", soundResolve.eventId,
            Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"),
            Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.soundFile = text.trim()
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("[osk] no '" + soundResolve.eventId
                    + "' event found in the freedesktop sound theme; the key click stays silent")
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
        // (devices, getoption), jq (devices JSON) and xkbcli (compiling the
        // key caps' symbols); all three come with the packages the install
        // button below pulls in.
        command: ["bash", "-c",
            "command -v hyprctl >/dev/null && command -v jq >/dev/null && command -v xkbcli >/dev/null"]
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
        + Style.spacing.popupPadding / 2

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
        height: root.cardHeight
        color: "transparent"
        mask: Region {
            item: card
        }

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
                : Math.min(panel.width - Style.spacing.popupPadding, keyboard.implicitWidth + keyboard.gapPx * 2) + Style.spacing.popupPadding
            height: root.cardHeight
            x: (panel.width - width) / 2
            y: panel.height - height - Style.spacing.lg
            radius: root.mode === "docked" ? 0 : Style.cornerRadius
            color: Color.popups.background
            borderSpec: Border.hyprlandActiveSpec(Color.accent, 2)

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
                height: Style.space(30) + keyboard.gapPx * 3

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
                }

                Text {
                    anchors {
                        horizontalCenter: parent.horizontalCenter
                        verticalCenter: languageSwitch.verticalCenter
                    }
                    text: root.mode === "docked"
                        ? "\u2328 Docked \u00b7 Double press Shift/Ctrl/Alt/Super to lock"
                        : "\u2328 Drag to move \u00b7 Double press Shift/Ctrl/Alt/Super to lock"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
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
                    height: Style.space(30)
                    radius: Style.cornerRadius
                    // Reads as disabled while the panel has no safe switch
                    // target (see refreshLayoutsFromHypr in Keyboard.qml):
                    // clicking still calls cycleLanguage, which refuses to
                    // guess rather than advance a device nobody typed on.
                    color: !keyboard.typedKeyboard ? Util.alpha(Color.foreground, Style.normalFillAlpha)
                        : languageArea.containsMouse ? (languageArea.pressed ? Color.accent : Util.alpha(Color.foreground, Style.hoverFillAlpha))
                        : Util.alpha(Color.foreground, Style.normalFillAlpha)
                    border.color: Util.alpha(Color.foreground, Style.pressedFillAlpha)
                    border.width: Style.normalBorderWidth
                    z: 2

                    Text {
                        id: langLabel
                        anchors.centerIn: parent
                        text: keyboard.currentLayoutName
                        color: keyboard.typedKeyboard ? Color.foreground : Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                    }

                    MouseArea {
                        id: languageArea
                        anchors.fill: parent
                        onClicked: keyboard.cycleLanguage()
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
                    height: Style.space(30)
                    radius: Style.cornerRadius
                    color: modeArea.pressed ? Color.accent
                        : modeArea.containsMouse ? Util.alpha(Color.foreground, Style.hoverFillAlpha)
                        : Util.alpha(Color.foreground, Style.normalFillAlpha)
                    border.color: modeArea.containsMouse ? Util.alpha(Color.accent, Style.pressedFillAlpha) : Util.alpha(Color.foreground, Style.pressedFillAlpha)
                    border.width: Style.normalBorderWidth
                    z: 2

                    Text {
                        id: modeLabel
                        anchors.centerIn: parent
                        text: root.mode === "docked" ? "Float" : "Dock"
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
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
                    width: Style.space(30)
                    height: Style.space(30)
                    radius: Style.cornerRadius
                    color: closeArea.pressed ? Color.urgent
                        : closeArea.containsMouse ? Util.alpha(Color.urgent, Style.hoverFillAlpha)
                        : Util.alpha(Color.foreground, Style.normalFillAlpha)
                    border.color: closeArea.containsMouse ? Util.alpha(Color.urgent, Style.pressedFillAlpha) : Util.alpha(Color.foreground, Style.pressedFillAlpha)
                    border.width: Style.normalBorderWidth
                    z: 2

                    Text {
                        id: closeLabel
                        anchors.centerIn: parent
                        text: "\u2715"
                        color: closeArea.containsMouse ? Color.urgent : Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
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
                height: Style.space(36)
                radius: Style.cornerRadius
                color: Color.popups.background
                border.color: Color.accent
                border.width: Style.normalBorderWidth

                Text {
                    anchors {
                        left: parent.left
                        leftMargin: Style.spacing.md
                        verticalCenter: parent.verticalCenter
                    }
                    text: dependencyInstall.running
                        ? "Installing keyboard dependencies..."
                        : "Keyboard dependencies are missing"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Rectangle {
                    anchors {
                        right: parent.right
                        rightMargin: Style.spacing.sm
                        verticalCenter: parent.verticalCenter
                    }
                    width: installLabel.implicitWidth + Style.spacing.lg
                    height: Style.space(28)
                    radius: Style.cornerRadius
                    color: installArea.pressed ? Color.accent : Color.foreground

                    Text {
                        id: installLabel
                        anchors.centerIn: parent
                        text: dependencyInstall.running ? "Working..." : "Install"
                        color: Color.background
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
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
