import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "KeyboardLayout.js" as Layout

Item {
    id: root
    implicitWidth: grid.implicitWidth
    implicitHeight: grid.implicitHeight
    signal closeRequested()

    // ---- Design tokens, copied 1:1 from the reference HTML/CSS ----
    readonly property real gapPx: Style.spacing.md
    readonly property real keyHeight: Style.space(42)
    readonly property real keyRadius: Style.cornerRadius
    readonly property real containerMaxWidth: Style.space(820)
    // Rows fill the same total width as the container minus its own
    // padding (which equals the gap), exactly like the CSS container's
    // `padding: var(--gap)` around `.keyboard-grid`.
    readonly property real rowWidth: containerMaxWidth - 2 * gapPx

    readonly property color keyBg: Util.alpha(Color.foreground, Style.normalFillAlpha)
    readonly property color keyHoverBg: Util.alpha(Color.foreground, Style.hoverFillAlpha)
    readonly property color keyActiveBg: Util.alpha(Color.foreground, Style.pressedFillAlpha)
    readonly property color keyBorderColor: Util.alpha(Color.foreground, Style.pressedFillAlpha)
    readonly property color accentColor: Util.alpha(Color.accent, Style.pressedFillAlpha)
    readonly property color textMain: Color.foreground
    readonly property color textDim: Color.muted
    readonly property color textHighlightColor: Color.foreground
    readonly property string keyboardFont: Style.font.family
    readonly property int keyBorderWidth: Style.normalBorderWidth
    readonly property int keyFontSize: Style.font.body
    readonly property int keySmallFontSize: Style.font.bodySmall

    property bool capsOn: false
    property bool shiftOn: false
    property bool shiftHeld: false
    property bool ctrlOn: false
    property bool ctrlHeld: false
    property bool altOn: false
    property bool altHeld: false
    property bool superOn: false
    property bool superHeld: false
    property bool altgrOn: false
    property bool altgrHeld: false
    property string currentLayout: "us"
    property var languageCycle: ["us"]
    property int layoutCycleIndex: 0
    property var layoutNameMap: ({})
    // The keyboard the switch is applied to. Switching "all" moves every device
    // on the seat, including pseudo-keyboards that never advance on their own,
    // which is how they end up sitting on different layouts from each other.
    property string typedKeyboard: ""
    property string typedKeyboardName: ""
    property string xkbRules: ""
    property string xkbModel: ""
    property string xkbLayouts: "us"
    property string xkbVariants: ""
    property string xkbOptions: ""
    property string xkbFile: ""
    property string currentLayoutName: {
        var name = layoutNameMap[currentLayout]
        return name ? name : currentLayout.toUpperCase()
    }
    property var symbolMap: ({})
    property var layoutRows: Layout.applyLanguage(Layout.rows, currentLayout, symbolMap)

    function updateLayoutRows() {
        layoutRows = Layout.applyLanguage(Layout.rows, currentLayout, symbolMap)
    }

    function parseLayoutSymbolOutput(text) {
        var map = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line) continue
            var parts = line.split("\t")
            if (parts.length < 2) continue
            map[parts[0]] = [parts[1], parts.length > 2 ? parts[2] : ""]
        }
        symbolMap = map
        updateLayoutRows()
    }


    function parseHyprLayoutOutput(text) {
        var lines = String(text || "").split("\n")
        var active = ""
        var detected = []
        var names = ({})
        var configGroup = 0

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line) continue
            var parts = line.split("\t")
            if (parts[0] === "DEVICE") {
                // Cleared unconditionally: a refresh that finds no safe
                // target must not leave the language button aiming at a
                // device that has gone missing or was never safe to advance.
                // An empty name lands here as a bare "DEVICE" after the line
                // trim, so this branch has to come before the field-count
                // guard below.
                typedKeyboard = String(parts[1] || "").trim()
                continue
            }
            if (parts.length < 2) continue
            if (parts[0] === "ACTIVE") {
                active = String(parts[1] || "").trim()
                continue
            }
            if (parts[0] === "DEVICE") {
                var device = String(parts[1] || "").trim()
                if (device) typedKeyboard = device
                continue
            }
            if (parts[0] === "CONFIG" && parts.length >= 8) {
                xkbRules = parts[1]
                xkbModel = parts[2]
                xkbLayouts = parts[3]
                xkbVariants = parts[4]
                xkbOptions = parts[5]
                xkbFile = parts[6] === "[[EMPTY]]" ? "" : parts[6]
                configGroup = parseInt(parts[7]) || 0
                continue
            }
            if (parts[0] === "LAYOUT") {
                detected.push(String(parts[1] || "").trim())
            }
            if (parts[0] === "NAME" && parts.length >= 3) {
                names[String(parts[1] || "").trim()] = String(parts[2] || "").trim()
            }
        }

        detected = detected.filter(function(layout) { return layout.length > 0 })
        if (detected.length > 0) {
            languageCycle = detected
        }
        // Merge any newly discovered names into the map
        var merged = ({})
        for (var k in layoutNameMap) merged[k] = layoutNameMap[k]
        for (var k in names) merged[k] = names[k]
        layoutNameMap = merged

        // Always follow the system. The old code adopted the layout once and
        // then froze, so a switch made with Caps Lock or the bar indicator left
        // the caps showing the previous alphabet while the compositor produced
        // the new one — the two looked swapped.
        var selected = active
        if (!selected && detected.length > 0) selected = detected[0]
        if (selected) {
            layoutCycleIndex = Math.max(0, detected.indexOf(selected))
            inputReady = false
            inputStatus = "configuring"
            sendCommandUnchecked("configure\t" + xkbRules + "\t" + xkbModel
                + "\t" + xkbLayouts + "\t" + xkbVariants + "\t" + xkbOptions
                + "\t" + xkbFile + "\t" + configGroup)
            if (selected !== currentLayout) loadLanguageLayout(selected)
        }
    }

    function refreshLayoutsFromHypr() {
        layoutDetectProcess.running = false
        // Two selections, deliberately different.
        //
        // The reading (group, layout list, RMLVO) comes from whichever typed
        // keyboard the evidence favours: the seat's active keyboard if a
        // filtered device holds it, then the device the last switch named,
        // then layout progress. Hyprland keeps XKB group state per device and
        // emits "activelayout" not only for deliberate switches but also for
        // hotplug, keymap (re)application and input-config reloads, so an
        // event name is weaker evidence than the flag — and the flag is what
        // "which device will the next physical key come from" actually means.
        // The flag moves on every real keypress, which is what keeps the
        // reading from going stale after the user switches devices.
        //
        // The switch target ("DEVICE", the device the language button
        // advances) only comes from those first two tiers. Advancing a
        // guessed device is what poisoned the seat before: a mouse advanced
        // once, the indicator read it forever after, and the label stopped
        // saying what typing produced. Until there is positive evidence, the
        // language button does nothing.
        //
        // The active-keyboard flag ("main" in devices JSON) is literally the
        // seat's current keyboard — HyprCtl prints IKeyboard::m_active as
        // "main". It only counts inside the filtered list: with an IME
        // running, fcitx5's virtual keyboard holds it whenever the user has
        // not typed since the IME last connected, and it lands on this
        // helper's own device right after typing. Residual windows that no
        // devices-JSON reading can close: hotplug or a mouse's media keys can
        // take the flag until the next physical keypress, and the flag alone
        // does not prove the device was typed on rather than merely plugged
        // in. The upstream fix is an event when the seat's current keyboard
        // changes, or a seat-level layout concept; Sway's keyboard groups are
        // the prior art.
        //
        // One caveat the JSON cannot answer: tied-at-zero devices are assumed
        // to share the seat's RMLVO, which holds unless the user configures
        // per-device keymaps (device:name { kb_layout }).
        layoutDetectProcess.command = ["bash", "-lc",
            "devices=$(hyprctl devices -j 2>/dev/null); "
            + "keyboard=$(printf '%s' \"$devices\" | jq -c --arg named \"$1\" '"
            + "[.keyboards[] | select((.name | test(\"^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)|omarchy-osk\"; \"i\")) | not)] as $typed | "
        + "($typed | map(select(.main == true))[0] // ($typed | map(select(.name == $named))[0]) // ($typed | max_by(.active_layout_index // 0)) // empty)' 2>/dev/null); "
        + "[[ -n \"$keyboard\" ]] || exit 1; "
        + "switchable=$(printf '%s' \"$devices\" | jq -r --arg named \"$1\" '"
        + "[.keyboards[] | select((.name | test(\"^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)|omarchy-osk\"; \"i\")) | not)] as $typed | "
        + "($typed | map(select(.main == true))[0] // ($typed | map(select(.name == $named))[0]) // {name: \"\"}) | .name' 2>/dev/null); "
            + "layouts_csv=$(printf '%s' \"$keyboard\" | jq -r '.layout // \"us\"'); "
            + "group=$(printf '%s' \"$keyboard\" | jq -r '.active_layout_index // 0'); "
            + "active=$(printf '%s' \"$layouts_csv\" | cut -d, -f$((group + 1))); "
            + "rules=$(printf '%s' \"$keyboard\" | jq -r '.rules // \"\"'); "
            + "model=$(printf '%s' \"$keyboard\" | jq -r '.model // \"\"'); "
            + "variants=$(printf '%s' \"$keyboard\" | jq -r '.variant // \"\"'); "
            + "options=$(printf '%s' \"$keyboard\" | jq -r '.options // \"\"'); "
            + "kb_file=$(hyprctl getoption input:kb_file -j 2>/dev/null | jq -r '.str // \"\"'); "
            + "printf 'ACTIVE\\t%s\\nDEVICE\\t%s\\nCONFIG\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "
            + "\"$active\" \"$switchable\" \"$rules\" \"$model\" \"$layouts_csv\" \"$variants\" \"$options\" \"$kb_file\" \"$group\"; "
            + "layouts=$(printf '%s' \"$layouts_csv\" | tr ',' '\\n' | sed '/^$/d'); "
            + "echo \"$layouts\" | awk '{print \"LAYOUT\\t\" $0}'; "
            + "echo \"$layouts\" | while read code; do "
            + "  name=$(awk -v c=\"$code\" 'BEGIN{s=0} /^! layout/{s=1;next} /^!/{if(s) exit} s && NF>=2 && $1==c { $1=\"\"; sub(/^ +/,\"\",$0); print $0; exit }' /usr/share/X11/xkb/rules/base.lst 2>/dev/null); "
            + "  [[ -n \"$name\" ]] && printf 'NAME\\t%s\\t%s\\n' \"$code\" \"$name\"; "
            + "done", "onscreen-keyboard", typedKeyboardName]
        layoutDetectProcess.running = true
    }

    function loadLanguageLayout(layoutCode) {
        currentLayout = layoutCode
        updateLayoutRows()
        // Compile the layout with xkbcli rather than reading
        // /usr/share/X11/xkb/symbols/<code> directly: most layouts define their
        // real keys in an include (ua's default variant is `include "ua(legacy)"`
        // plus overrides, ru's is `include "ru(common)"`), so parsing the raw
        // file only ever sees the handful of override keys. A compiled keymap is
        // flat, so a plain line match over `key <X> { [ a, b ] }` is enough.
        // xkbcli ships with libxkbcommon, which Hyprland already depends on.
        // A Process that is already running ignores `running = true` and keeps
        // the command it started with, so a second switch while the first
        // compile is in flight would apply the old layout's symbols to the new
        // one and never correct itself. Stop it first.
        layoutLoadProcess.running = false
        var variantList = String(xkbVariants || "").split(",")
        var activeVariant = variantList[layoutCycleIndex] || ""
        // pipefail so a failed xkbcli is not masked by awk exiting 0, which
        // would install an empty map and silently leave the keyboard blank.
        layoutLoadProcess.command = ["bash", "-lc",
            // A key definition spans one line for simple keys but several when
            // it carries an explicit type, which is how xkbcli emits most
            // alphabetic keys on ara, in, il, kz, uz and lk:
            //     key <AD01> {
            //         type= "FOUR_LEVEL",
            //         symbols[1]= [ U094C, U0914, NoSymbol, NoSymbol ]
            //     };
            // Matching only the single-line form loses every letter on those
            // layouts and leaves a US keyboard on screen. Buffer the whole
            // definition instead, then take the symbol list from it. Reading
            // `symbols[N]=` first matters: `symbols[1]` would otherwise be
            // mistaken for the bracketed list by a plain `[...]` match.
            "set -o pipefail; "
            + "if [[ -n \"$7\" ]]; then source=(--keymap \"$7\"); wanted=$8; "
            + "else source=(--rules \"${1:-evdev}\" --model \"${2:-pc105}\" --layout \"$3\" --variant \"$4\" --options \"$5\"); wanted=1; fi; "
            + "xkbcli compile-keymap \"${source[@]}\" 2>/dev/null | awk -v wanted=\"$wanted\" '\n"
            + " match($0, /key[[:space:]]*<([A-Z0-9]+)>/, k) { name=k[1]; buf=\"\"; inkey=1 }\n"
            + " inkey {\n"
            + "   buf = buf \" \" $0\n"
            + "   if (index($0, \"}\")) {\n"
            + "     typed = \"symbols\\\\[\" wanted \"\\\\][[:space:]]*=[[:space:]]*\\\\[([^]]+)\\\\]\"\n"
            + "     if (match(buf, typed, s) || (wanted == 1 &&\n"
            + "         match(buf, /\\{[[:space:]]*\\[([^]]+)\\]/, s)) {\n"
            + "       split(s[1], arr, /,/)\n"
            + "       gsub(/[[:space:]]+/, \"\", arr[1])\n"
            + "       gsub(/[[:space:]]+/, \"\", arr[2])\n"
            + "       print name \"\\t\" arr[1] \"\\t\" arr[2]\n"
            + "     }\n"
            + "     inkey=0\n"
            + "   }\n"
            + " }\n"
            // Passed as an argument rather than concatenated into the script:
            // the code comes from hyprctl, and splicing it in would let a stray
            // space or shell metacharacter change the command.
            + "'", "onscreen-keyboard", xkbRules, xkbModel, layoutCode,
            activeVariant, xkbOptions, "", xkbFile, String(layoutCycleIndex + 1)]
        layoutLoadProcess.running = true
    }

    function cycleLanguage() {
        if (languageCycle.length < 2) return
        // Advance our local index so we know exactly what layout is next,
        // independent of the system's virtual keyboard reporting wrong index.
        // switchxkblayout is a hyprctl command, not a dispatcher, so it cannot
        // go over the dispatch socket — the built-in layout widget runs it the
        // same way. This is a one-off on a button press rather than anything on
        // the typing path, which stays free of spawned processes.
        //
        // Nothing is applied locally: the activelayout event reports what
        // actually happened, and guessing here is what let the panel drift out
        // of step with the compositor.
        if (!typedKeyboard) return
        Quickshell.execDetached(["hyprctl", "switchxkblayout", typedKeyboard, "next"])
    }

    Component.onCompleted: refreshLayoutsFromHypr()

    Process {
        id: layoutDetectProcess
        property string collected: ""
        stdout: SplitParser {
            onRead: function(data) {
                layoutDetectProcess.collected += data + "\n"
            }
        }
        onRunningChanged: {
            if (running) collected = ""
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 || exitStatus !== 0) return
            root.parseHyprLayoutOutput(layoutDetectProcess.collected)
        }
    }

    Process {
        id: layoutLoadProcess
        property string collected: ""
        stdout: SplitParser {
            onRead: function(data) {
                layoutLoadProcess.collected += data + "\n"
            }
        }
        onRunningChanged: {
            if (running) collected = ""
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0 && exitStatus === 0) {
                root.parseLayoutSymbolOutput(layoutLoadProcess.collected)
                return
            }
            root.symbolMap = ({})
            root.updateLayoutRows()
        }
    }

    // The compositor is the single source of truth for which layout is active.
    //
    // It has to be, now that keys are sent as positions: the character produced
    // is whatever the compositor's layout says, so if the panel believed
    // something else the caps would show one alphabet while another came out.
    // Switching outside the panel — Caps Lock, the bar indicator, a keybind —
    // is the same event as switching inside it, and both are picked up here
    // rather than by a timer, which is how the built-in layout widget does it.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!event || !event.name) return
            var name = String(event.name)
            if (name === "activelayout") {
                var parts = null
                try { if (event.parse) parts = event.parse(2) } catch (error) {}
                if (!parts) parts = String(event.data || "").split(",")
                var named = String(parts[0] || "")
                var lower = named.toLowerCase()
                if (named && lower.indexOf("hl-virtual-keyboard") !== 0
                        && lower.indexOf("omarchy-osk") === -1) {
                    root.typedKeyboardName = named
                }
            }
            // A reload can add or remove layouts without moving anything, so it
            // changes what the panel may cycle through even with no switch.
            if (name.indexOf("activelayout") !== -1 || name === "configreloaded") {
                root.refreshLayoutsFromHypr()
            }
        }
    }

    // A device appearing or leaving raises no event of its own, and a query
    // that failed at login would otherwise never be retried. Slow on purpose:
    // the events above carry the switches, this only repairs.
    Timer {
        id: layoutSyncTimer
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.refreshLayoutsFromHypr()
    }

    function activeModifiers() {
        var mods = []
        if (ctrlOn) mods.push("ctrl")
        if (altOn) mods.push("alt")
        if (superOn) mods.push("logo")
        if (altgrOn) mods.push("altgr")
        if (shiftOn) mods.push("shift")
        return mods
    }

    function clearComboMods() {
        shiftOn = shiftHeld
        ctrlOn = ctrlHeld
        altOn = altHeld
        superOn = superHeld
        altgrOn = altgrHeld
    }

    function isUpper() {
        return capsOn !== shiftOn
    }

    function isSymbolShiftActive() {
        return shiftOn
    }

    function isHoldableModifierKey(key) {
        switch (key) {
        case "shift":
        case "ctrl":
        case "alt":
        case "logo":
        case "altgr":
            return true
        }
        return false
    }

    function modifierHeld(key) {
        switch (key) {
        case "shift": return shiftHeld
        case "ctrl": return ctrlHeld
        case "alt": return altHeld
        case "logo": return superHeld
        case "altgr": return altgrHeld
        }
        return false
    }

    function setModifierHeld(key, held) {
        switch (key) {
        case "shift": shiftHeld = held; shiftOn = held; return
        case "ctrl": ctrlHeld = held; ctrlOn = held; return
        case "alt": altHeld = held; altOn = held; return
        case "logo": superHeld = held; superOn = held; return
        case "altgr": altgrHeld = held; altgrOn = held; return
        }
    }

    function toggleModifier(key, doubleClick) {
        if (doubleClick) {
            setModifierHeld(key, !modifierHeld(key))
            return
        }
        if (modifierHeld(key)) {
            setModifierHeld(key, false)
            return
        }
        switch (key) {
        case "shift": shiftOn = !shiftOn; return
        case "ctrl": ctrlOn = !ctrlOn; return
        case "alt": altOn = !altOn; return
        case "logo": superOn = !superOn; return
        case "altgr": altgrOn = !altgrOn; return
        }
    }

    // A letter key is one whose shifted symbol is simply the capital of its
    // base, which holds in any script and needs no per-alphabet table.
    // `/^[a-z]$/` recognised only Latin, so Cyrillic and Greek letters were
    // treated as punctuation: Caps Lock did nothing on them and they rendered
    // as stacked dual keys. Asking merely whether the base has a capital is not
    // enough either — French AZERTY carries é on the same key as 2, and é does
    // have a capital, so Caps Lock would type 2 instead of É.
    function isLetterKey(keyData) {
        var base = keyData.t || ""
        var shifted = keyData.s || ""
        return base.length > 0 && shifted.length > 0 && shifted === base.toUpperCase()
    }

    function resolvedTypedChar(keyData) {
        if (isLetterKey(keyData)) {
            return isUpper() && keyData.s ? keyData.s : keyData.t
        }
        return shiftOn && keyData.s ? keyData.s : keyData.t
    }

    // Punctuation/number keys show both symbols stacked (like the
    // reference's `.key.dual`); plain letter keys just swap case.
    function isDualKey(keyData) {
        return !!keyData.s && !isLetterKey(keyData)
    }

    // Input goes to the helper daemon over a unix socket; the panel never
    // takes keyboard focus (`keyboardFocus: None` in Panel.qml), so the
    // window being typed into keeps it and the daemon's keystrokes land
    // there. Nothing here spawns a process: the plugin runs inside the
    // long-lived shell, and the Omarchy guide asks plugins not to launch
    // shell processes. The first version spawned `wtype` per keystroke, and
    // could never have worked well even had it been allowed — a fresh
    // `wtype` per key uploads a synthetic keymap that XWayland ignores, so
    // keys never reached Proton games or Electron apps, and each spawn cost
    // tens of milliseconds.
    property bool inputReady: false
    property string inputStatus: "connecting"

    Socket {
        id: daemon
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/omarchy-osk/control.sock"
        connected: true

        onConnectionStateChanged: {
            if (connected) {
                // Readiness is not the same as "the socket answered": the
                // daemon accepts commands before the compositor keymap has been
                // forwarded to its virtual keyboard, and would drop every key.
                write("hello 2\n")
                flush()
            } else {
                root.inputReady = false
                root.inputStatus = "reconnecting"
                reconnectTimer.restart()
            }
        }

        parser: SplitParser {
            onRead: function (line) {
                var reply = String(line).trim()
                if (reply === "hello 2") {
                    root.inputReady = false
                    root.inputStatus = "configuring"
                    // A reconnect can land with the daemon still holding
                    // modifiers this panel no longer thinks are down.
                    root.clearComboMods()
                    daemon.write("mods 0\n")
                    daemon.flush()
                    // A restarted helper is back at group 0 and has no idea
                    // which layout is current. Re-reading the compositor sends
                    // the right group; using layoutCycleIndex here would send
                    // whatever it held before the first sync, which is 0 on a
                    // fresh panel and would force the first layout.
                    root.refreshLayoutsFromHypr()
                } else if (reply === "configured") {
                    root.inputReady = true
                    root.inputStatus = "ready"
                } else if (reply.indexOf("err") === 0) {
                    root.inputReady = false
                    root.inputStatus = reply
                }
            }
        }
    }

    Timer {
        id: reconnectTimer
        // Capped so a missing helper costs a connect attempt every couple of
        // seconds rather than a busy loop.
        interval: 2000
        repeat: false
        onTriggered: daemon.connected = true
    }

    function sendCommand(text) {
        if (!inputReady) return false
        return sendCommandUnchecked(text)
    }

    function sendCommandUnchecked(text) {
        daemon.write(text + "\n")
        daemon.flush()
        return true
    }

    /// Taps a key position with modifier positions held around it. Modifiers go
    /// as real key presses rather than a modifier mask so the compositor derives
    /// the state exactly as it would from a physical keyboard.
    function tapPosition(position, modifierPositions) {
        if (!position) return
        for (var i = 0; i < modifierPositions.length; i++) {
            sendCommand("down " + modifierPositions[i])
        }
        sendCommand("tap " + position)
        for (var j = modifierPositions.length - 1; j >= 0; j--) {
            sendCommand("up " + modifierPositions[j])
        }
    }

    function heldModifierPositions() {
        var positions = []
        var names = activeModifiers()
        for (var i = 0; i < names.length; i++) {
            var position = Layout.positionForModifier(names[i])
            if (position) positions.push(position)
        }
        return positions
    }

    function pressChar(keyData) {
        if (!keyData.k) return

        // Shift is applied as a real Shift press rather than by picking the
        // shifted character, because the compositor resolves the position
        // through its own layout. Which of Caps or Shift is doing the work
        // follows the same rule the key caps are drawn with, so what is shown
        // is what is typed.
        var positions = heldModifierPositions().filter(function (position) {
            return position !== "LFSH"
        })
        var wantsShift = isLetterKey(keyData) ? isUpper() : shiftOn
        if (wantsShift) positions.push("LFSH")

        tapPosition(keyData.k, positions)

        if (activeModifiers().length > 0) {
            clearComboMods()
        }
        shiftOn = shiftHeld
    }

    function pressSpecial(keyData, doubleClick) {
        switch (keyData.key) {
        case "close": closeRequested(); return
        case "emoji": Quickshell.execDetached(["omarchy-menu-emoji"]); return
        case "lang": cycleLanguage(); return
        case "caps": capsOn = !capsOn; return
        case "shift": toggleModifier("shift", doubleClick); return
        case "ctrl": toggleModifier("ctrl", doubleClick); return
        case "alt": toggleModifier("alt", doubleClick); return
        case "logo": toggleModifier("logo", doubleClick); return
        case "altgr": toggleModifier("altgr", doubleClick); return
        }
        var position = Layout.positionForKeysym(keyData.key)
        if (!position) return
        tapPosition(position, heldModifierPositions())
        clearComboMods()
    }

    function isToggled(keyData) {
        switch (keyData.key) {
        case "caps": return capsOn
        case "shift": return shiftOn
        case "ctrl": return ctrlOn
        case "alt": return altOn
        case "logo": return superOn
        case "altgr": return altgrOn
        }
        return false
    }

    Column {
        id: grid
        spacing: root.gapPx

        Repeater {
            model: root.layoutRows
            delegate: Row {
                id: rowItem
                spacing: root.gapPx
                readonly property var rowModel: modelData
                readonly property real flexSum: rowModel.reduce(function (acc, item) {
                    return acc + (item.w || 1)
                }, 0)
                readonly property real innerWidth: root.rowWidth - (rowModel.length - 1) * root.gapPx

                Repeater {
                    model: rowModel
                    delegate: Item {
                        id: keyDelegate
                        property var keyData: modelData
                        width: rowItem.innerWidth * (keyData.w || 1) / rowItem.flexSum
                        height: root.keyHeight

                        Rectangle {
                            id: keyRect
                            anchors.fill: parent
                            visible: keyData.cluster !== "arrows"
                            radius: root.keyRadius
                            border.width: root.keyBorderWidth

                            property bool toggled: root.isToggled(keyData)
                            // The language key reads as disabled while the
                            // panel has no safe switch target; see
                            // refreshLayoutsFromHypr for why one may not exist.
                            property bool isLang: keyData.key === "lang"
                            property bool isDual: root.isDualKey(keyData)

                            color: isLang ? (root.typedKeyboard ? root.accentColor : root.keyBg)
                                : toggled ? root.accentColor
                                : mouseArea.pressed ? root.keyActiveBg
                                : mouseArea.containsMouse ? root.keyHoverBg
                                : root.keyBg
                            border.color: isLang ? (root.typedKeyboard ? root.accentColor : root.keyBorderColor)
                                : toggled ? root.accentColor
                                : root.keyBorderColor

                            Text {
                                visible: !keyRect.isDual
                                anchors.centerIn: parent
                                text: keyData.label
                                    ? keyData.label
                                    : root.resolvedTypedChar(keyData)
                                color: keyRect.isLang || keyRect.toggled
                                    ? root.textHighlightColor
                                    : root.textMain
                                font.family: root.keyboardFont
                                font.pixelSize: root.keyFontSize
                            }

                            // Stacked dual symbols: shifted symbol on top
                            // (dim by default), base symbol on the bottom
                            // (bright by default) — swapping emphasis when
                            // Shift is held, mirroring `.key.dual.shift-active`.
                            Text {
                                visible: keyRect.isDual
                                text: keyData.s
                                anchors.top: parent.top
                                anchors.topMargin: root.gapPx
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: root.isSymbolShiftActive() ? root.textHighlightColor : root.textDim
                                font.bold: root.isSymbolShiftActive()
                                font.family: root.keyboardFont
                                font.pixelSize: root.keySmallFontSize
                            }

                            Text {
                                visible: keyRect.isDual
                                text: keyData.t
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: root.gapPx
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: root.isSymbolShiftActive() ? root.textDim : root.textMain
                                font.family: root.keyboardFont
                                font.pixelSize: root.keyFontSize
                            }

                            MouseArea {
                                id: mouseArea
                                anchors.fill: parent
                                hoverEnabled: true

                                Timer {
                                    id: modifierSingleClickDelay
                                    interval: 250
                                    repeat: false
                                    property var pendingKeyData: null
                                    onTriggered: {
                                        if (!pendingKeyData) return
                                        root.pressSpecial(pendingKeyData, false)
                                        pendingKeyData = null
                                    }
                                }

                                // Ordinary keys fire on press, not on click. A
                                // click only completes when the button comes
                                // back up, so waiting for it charges every
                                // keystroke the length of the press — which
                                // reads as lag even though nothing is slow.
                                // Real keyboards act on the way down.
                                onPressed: {
                                    if (!keyData.key) root.pressChar(keyData)
                                }

                                // Keys with a double-press meaning still need
                                // the click, since a press alone cannot tell a
                                // tap from the first half of a double.
                                onClicked: {
                                    if (!keyData.key) return
                                    if (!root.isHoldableModifierKey(keyData.key)) {
                                        root.pressSpecial(keyData, false)
                                        return
                                    }
                                    modifierSingleClickDelay.pendingKeyData = keyData
                                    modifierSingleClickDelay.restart()
                                }

                                onDoubleClicked: {
                                    if (!keyData.key || !root.isHoldableModifierKey(keyData.key)) return
                                    modifierSingleClickDelay.pendingKeyData = null
                                    modifierSingleClickDelay.stop()
                                    root.pressSpecial(keyData, true)
                                }
                            }
                        }

                        Row {
                            id: arrowRow
                            anchors.fill: parent
                            visible: keyData.cluster === "arrows"
                            spacing: root.gapPx
                            readonly property real subWidth: (width - 2 * root.gapPx) / 3

                            Rectangle {
                                width: arrowRow.subWidth
                                height: parent.height
                                radius: root.keyRadius
                                border.width: root.keyBorderWidth
                                border.color: root.keyBorderColor
                                color: leftArrowArea.pressed ? root.keyActiveBg
                                    : leftArrowArea.containsMouse ? root.keyHoverBg
                                    : root.keyBg
                                Text {
                                    anchors.centerIn: parent
                                    text: "\u25c0"
                                    color: root.textMain
                                    font.family: root.keyboardFont
                                    font.pixelSize: root.keyFontSize
                                }
                                MouseArea {
                                    id: leftArrowArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.pressSpecial({ key: "Left" })
                                }
                            }

                            Column {
                                width: arrowRow.subWidth
                                height: parent.height
                                spacing: root.gapPx

                                Rectangle {
                                    width: parent.width
                                    height: (parent.height - parent.spacing) / 2
                                    radius: root.keyRadius
                                    border.width: root.keyBorderWidth
                                    border.color: root.keyBorderColor
                                    color: upArrowArea.pressed ? root.keyActiveBg
                                        : upArrowArea.containsMouse ? root.keyHoverBg
                                        : root.keyBg
                                    Text {
                                        anchors.centerIn: parent
                                        text: "\u25b2"
                                        color: root.textMain
                                        font.family: root.keyboardFont
                                        font.pixelSize: root.keySmallFontSize
                                    }
                                    MouseArea {
                                        id: upArrowArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: root.pressSpecial({ key: "Up" })
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: (parent.height - parent.spacing) / 2
                                    radius: root.keyRadius
                                    border.width: root.keyBorderWidth
                                    border.color: root.keyBorderColor
                                    color: downArrowArea.pressed ? root.keyActiveBg
                                        : downArrowArea.containsMouse ? root.keyHoverBg
                                        : root.keyBg
                                    Text {
                                        anchors.centerIn: parent
                                        text: "\u25bc"
                                        color: root.textMain
                                        font.family: root.keyboardFont
                                        font.pixelSize: root.keySmallFontSize
                                    }
                                    MouseArea {
                                        id: downArrowArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: root.pressSpecial({ key: "Down" })
                                    }
                                }
                            }

                            Rectangle {
                                width: arrowRow.subWidth
                                height: parent.height
                                radius: root.keyRadius
                                border.width: root.keyBorderWidth
                                border.color: root.keyBorderColor
                                color: rightArrowArea.pressed ? root.keyActiveBg
                                    : rightArrowArea.containsMouse ? root.keyHoverBg
                                    : root.keyBg
                                Text {
                                    anchors.centerIn: parent
                                    text: "\u25b6"
                                    color: root.textMain
                                    font.family: root.keyboardFont
                                    font.pixelSize: root.keyFontSize
                                }
                                MouseArea {
                                    id: rightArrowArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.pressSpecial({ key: "Right" })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
