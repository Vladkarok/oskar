import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "KeyboardLayout.js" as Layout
import "ModifierReducer.js" as Modifiers

Item {
    id: root
    implicitWidth: grid.implicitWidth
    implicitHeight: grid.implicitHeight
    signal closeRequested()
    // Emitted for every keystroke-shaped press — letters, arrows, modifier
    // clicks, Caps Lock — and never for the panel's own UI actions. The panel
    // plays the key click sound on it (spec-v1 §10).
    signal keyPressed()

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
    // The three modifier states, told apart by fill weight rather than by two
    // shades of one colour (spec-v1 §5): idle is the ordinary key, latched is
    // an accent tint under a thick accent outline, locked is solid accent with
    // the label knocked out.
    readonly property color latchedFill: Style.selectedAccentFill
    readonly property color lockedFill: Color.accent
    readonly property color lockedText: Color.background
    readonly property color textMain: Color.foreground
    readonly property color textDim: Color.muted
    readonly property color textHighlightColor: Color.foreground
    readonly property string keyboardFont: Style.font.family
    readonly property int keyBorderWidth: Style.normalBorderWidth
    // Doubled rather than taken straight from focusBorderWidth, which falls
    // back to the normal width on themes that do not set it — a latched
    // outline the same thickness as an idle one is not a distinguishable state.
    readonly property int latchedBorderWidth: Math.max(2 * keyBorderWidth, Style.focusBorderWidth)
    readonly property int keyFontSize: Style.font.body
    readonly property int keySmallFontSize: Style.font.bodySmall

    property bool capsOn: false
    // Every modifier's idle/latched/locked state, owned by the reducer
    // (spec-v1 §15, seam 2). The panel holds the value and draws it; the
    // transitions and the protocol lines are the module's.
    property var modifierState: Modifiers.initialState()
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
        console.log("[osk] loadLanguageLayout:", layoutCode, "variant-index:", layoutCycleIndex)
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
            + "         match(buf, /\\{[[:space:]]*\\[([^]]+)\\]/, s))) {\n"
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
        console.log("[osk] keycaps process starting for", layoutCode)
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
            console.log("[osk] keycaps process running:", running)
            if (running) collected = ""
        }
        onExited: function(exitCode, exitStatus) {
            console.log("[osk] keycaps process exited:", exitCode, exitStatus, "collected bytes:", collected.length)
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

    /// Runs one event through the reducer and writes whatever it says to
    /// write. The only path modifier state changes on, so the panel cannot
    /// drift from what the seam's tests cover.
    ///
    /// Refused outright while the helper is not ready, rather than advancing
    /// the state over writes that go nowhere: a lock whose `down` was dropped
    /// would leave the cap showing a modifier the compositor never received,
    /// which is the one thing the indicator must not do. Nothing is typeable
    /// in that state anyway.
    function applyModifierEvent(event) {
        if (!inputReady) return
        var outcome = Modifiers.reduce(modifierState, event)
        modifierState = outcome.state
        for (var i = 0; i < outcome.lines.length; i++) {
            sendCommand(outcome.lines[i])
        }
    }

    /// Lifts whatever is locked and returns every modifier to idle. The panel
    /// closing is not the compositor forgetting: a locked Ctrl is really held
    /// at the device, and leaving it that way turns closing the keyboard into
    /// a session that behaves as if Ctrl were taped down.
    function releaseModifiers() {
        applyModifierEvent({ type: "releaseAll" })
    }

    function shiftActive() {
        return Modifiers.isActive(modifierState, "shift")
    }

    function isUpper() {
        return capsOn !== shiftActive()
    }

    function isSymbolShiftActive() {
        return shiftActive()
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
        return shiftActive() && keyData.s ? keyData.s : keyData.t
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
    // The helper socket, created by the loader below. Root-scope alias because
    // the component's own id does not reach the functions out here.
    property QtObject daemonSocket: daemonLoader.item

    // The helper may start after the shell: systemd orders the service
    // against graphical-session.target, not against the shell, so the panel's
    // first connection attempt can find no socket. Quickshell's Socket never
    // recovers from that — a failed connect leaves its internal QLocalSocket
    // in place, and setConnected(true) only dials when that object is gone,
    // with nothing but a successful connection ever clearing it — so the
    // whole socket is rebuilt whenever the helper's socket file exists and
    // the helper has not answered hello yet. A daemon that dies later needs
    // none of this: the disconnected path clears the object and the pending
    // targetConnected redials on its own. One rebuild per two seconds while
    // the helper is down; a completed handshake stops the timer.
    Loader {
        id: daemonLoader
        active: true
        sourceComponent: daemonComponent
    }

    Component {
        id: daemonComponent

        Socket {
            id: daemon
            path: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/omarchy-osk/control.sock"
            connected: true

            onConnectionStateChanged: {
                if (connected) {
                    // Readiness is not the same as "the socket answered": the
                    // daemon accepts commands before the compositor keymap has
                    // been forwarded to its virtual keyboard, and would drop
                    // every key. hello therefore goes out on a short delay
                    // after the flip — inline writes were observed landing on
                    // a closed device during the VM dogfooding.
                    helloTimer.restart()
                } else {
                    root.inputReady = false
                    root.inputStatus = "reconnecting"
                }
            }

            parser: SplitParser {
                onRead: function (line) {
                    var reply = String(line).trim()
                    if (reply === "hello 2") {
                        root.inputReady = false
                        root.inputStatus = "configuring"
                        // The helper released everything this panel's old
                        // connection held when that socket closed, so a
                        // locked modifier did not survive the reconnect
                        // however the indicator looked. Reset to match, and
                        // do it without emitting the releases — sending `up`
                        // for a code nobody holds is a lie in the other
                        // direction.
                        root.modifierState = Modifiers.initialState()
                        daemon.write("mods 0\n")
                        daemon.flush()
                        // A restarted helper is back at group 0 and has no idea
                        // which layout is current. Re-reading the compositor
                        // sends the right group; using layoutCycleIndex here
                        // would send whatever it held before the first sync,
                        // which is 0 on a fresh panel and would force the
                        // first layout.
                        root.refreshLayoutsFromHypr()
                    } else if (reply === "configured") {
                        root.inputReady = true
                        root.inputStatus = "ready"
                    } else if (reply.indexOf("err") === 0) {
                        if (reply === "err not ready") {
                            // A helper fresh out of systemd start answers err
                            // until its default keymap is installed; it cannot
                            // become ready without a configure, and nothing
                            // else sends one — so ask the compositor now
                            // instead of waiting out the repair timer.
                            root.refreshLayoutsFromHypr()
                        } else if (reply === "err key held" || reply === "err not holding") {
                            // Ownership refusals mean the daemon's hold state
                            // is ahead of ours; the device is fine and typing
                            // stays enabled. The panel's chords never produce
                            // them, so one appearing is a client bug worth
                            // surfacing in the status without bricking the
                            // keyboard.
                            root.inputStatus = reply
                        } else {
                            root.inputReady = false
                            root.inputStatus = reply
                        }
                    }
                }
            }
        }
    }

    Timer {
        id: helloTimer
        // Gives a fresh connection attempt a moment to actually open before
        // hello goes out. When the helper is still down the write fails
        // harmlessly and the next rebuild dials again.
        interval: 150
        repeat: false
        onTriggered: {
            if (root.daemonSocket) {
                root.daemonSocket.write("hello 2\n")
                root.daemonSocket.flush()
            }
        }
    }

    Process {
        id: socketPathCheck
        command: ["test", "-S", (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/omarchy-osk/control.sock"]
        onExited: function(exitCode, exitStatus) {
            // The check ran a moment ago; the socket may have connected since
            // (the original attempt succeeding, or a sibling tick's rebuild).
            // Rebuilding a live connection would drop it mid-handshake.
            var item = root.daemonSocket
            if (exitCode === 0 && !root.inputReady && !(item && item.connected)) {
                daemonLoader.active = false
                daemonLoader.active = true
            }
        }
    }

    Timer {
        id: reconnectTimer
        interval: 2000
        repeat: true
        running: !root.inputReady
        onTriggered: {
            // An open socket is never torn down, whatever the handshake is
            // doing: a configure round trip can outlast this tick, and
            // rebuilding mid-handshake would drop it and restart the dance.
            // Open-but-unready gets a fresh hello; absent or wedged gets the
            // rebuild, if the helper's socket file is on disk.
            var item = root.daemonSocket
            if (item && item.connected) {
                helloTimer.restart()
                return
            }
            socketPathCheck.running = true
        }
    }

    function sendCommand(text) {
        if (!inputReady) return false
        return sendCommandUnchecked(text)
    }

    function sendCommandUnchecked(text) {
        if (!daemonSocket) return false
        daemonSocket.write(text + "\n")
        daemonSocket.flush()
        return true
    }

    // Shift is applied as a real Shift press rather than by picking the shifted
    // character, because the compositor resolves the position through its own
    // layout. Which of Caps or Shift is doing the work follows the same rule
    // the key caps are drawn with, so what is shown is what is typed — the
    // reducer decides both, from the same `letter` and `caps` facts.
    function pressChar(keyData) {
        if (!keyData.k) return
        root.keyPressed()
        applyModifierEvent({
            type: "press",
            position: keyData.k,
            letter: isLetterKey(keyData),
            caps: capsOn
        })
    }

    function pressSpecial(keyData, doubleClick) {
        switch (keyData.key) {
        case "close": closeRequested(); return
        case "emoji": Quickshell.execDetached(["omarchy-menu-emoji"]); return
        case "lang": cycleLanguage(); return
        case "caps":
            root.keyPressed()
            capsOn = !capsOn
            return
        }
        if (Modifiers.isModifier(keyData.key)) {
            root.keyPressed()
            applyModifierEvent({
                type: doubleClick ? "doubleClick" : "click",
                modifier: keyData.key
            })
            return
        }
        var position = Layout.positionForKeysym(keyData.key)
        if (!position) return
        root.keyPressed()
        applyModifierEvent({ type: "press", position: position })
    }

    /// "idle", "latched" or "locked" for anything that has those states, so the
    /// cap can draw all three distinguishably rather than lit-or-not.
    function keyModifierState(keyData) {
        if (keyData.key === "caps") return capsOn ? "locked" : "idle"
        if (!Modifiers.isModifier(keyData.key)) return "idle"
        return modifierState[keyData.key]
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

                            // Three states have to be told apart at a glance
                            // (spec-v1 §5), so they differ in more than
                            // shade: latched is an accent outline over the
                            // ordinary fill, locked is filled accent. One
                            // reads as armed, the other as held down.
                            property string modState: root.keyModifierState(keyData)
                            property bool latched: modState === "latched"
                            property bool locked: modState === "locked"
                            // The language key reads as disabled while the
                            // panel has no safe switch target; see
                            // refreshLayoutsFromHypr for why one may not exist.
                            property bool isLang: keyData.key === "lang"
                            property bool isDual: root.isDualKey(keyData)

                            color: isLang ? (root.typedKeyboard ? root.accentColor : root.keyBg)
                                : locked ? root.lockedFill
                                : latched ? root.latchedFill
                                : mouseArea.pressed ? root.keyActiveBg
                                : mouseArea.containsMouse ? root.keyHoverBg
                                : root.keyBg
                            border.color: isLang ? (root.typedKeyboard ? root.accentColor : root.keyBorderColor)
                                : (latched || locked) ? Color.accent
                                : root.keyBorderColor
                            border.width: latched ? root.latchedBorderWidth : root.keyBorderWidth

                            Text {
                                visible: !keyRect.isDual
                                anchors.centerIn: parent
                                text: keyData.label
                                    ? keyData.label
                                    : root.resolvedTypedChar(keyData)
                                color: keyRect.locked ? root.lockedText
                                    : keyRect.isLang ? root.textHighlightColor
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

                                // Everything that types fires on press, not on
                                // click. Two reasons, and the second one is
                                // the load-bearing one.
                                //
                                // A click only completes when the button comes
                                // back up, so waiting for it charges every
                                // keystroke the length of the press — which
                                // reads as lag even though nothing is slow.
                                // Real keyboards act on the way down.
                                //
                                // And `clicked` is not emitted at all for the
                                // second press of a double click: the delegate
                                // has an `onDoubleClicked`, so Qt marks that
                                // press consumed and the sequence a cap sees
                                // for two fast taps is press, click, press,
                                // doubleClick. A cap driven from `onClicked`
                                // therefore loses every other tap once the
                                // taps fall inside the double-click interval —
                                // five fast Backspaces deleted three. `pressed`
                                // is emitted for both, which is why letter caps
                                // never showed the loss.
                                onPressed: {
                                    if (!keyData.key) {
                                        root.pressChar(keyData)
                                        return
                                    }
                                    if (Layout.positionForKeysym(keyData.key)) {
                                        root.pressSpecial(keyData, false)
                                    }
                                }

                                // What is left on the click is what does not
                                // type: the modifiers, whose double press is a
                                // second meaning a press alone cannot tell
                                // apart, and the command caps (close, emoji,
                                // lang, caps) where acting on the way down
                                // would tear the panel out from under the
                                // button that is still held.
                                onClicked: {
                                    if (!keyData.key) return
                                    if (Layout.positionForKeysym(keyData.key)) return
                                    if (!Modifiers.isModifier(keyData.key)) {
                                        root.pressSpecial(keyData, false)
                                        return
                                    }
                                    modifierSingleClickDelay.pendingKeyData = keyData
                                    modifierSingleClickDelay.restart()
                                }

                                onDoubleClicked: {
                                    if (!keyData.key || !Modifiers.isModifier(keyData.key)) return
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
