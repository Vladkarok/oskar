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
    // Pinned to the taller of the two pages rather than to whichever is on
    // screen. Docked mode reserves this height (§7), so letting it follow the
    // current page would shove every window on the output up and down each time
    // &123 is pressed. The grid is anchored to the bottom, so the command row —
    // modifiers, space, arrows, and the page key itself — stays under the
    // pointer across a switch and the slack appears at the top.
    readonly property int maxPageRows: Math.max(Layout.rows.length, Layout.symbolRows("").length,
        Layout.curatedMaxRows)
    implicitHeight: maxPageRows * keyHeight + (maxPageRows - 1) * gapPx
    signal closeRequested()
    // Emitted for every keystroke-shaped press — letters, arrows, modifier
    // clicks, Caps Lock — and never for the panel's own UI actions. The panel
    // plays the key click sound on it (spec-v1 §10).
    signal keyPressed()

    // The size preset's multiplier on top of the theme's own scaling
    // (spec-v1 §7). Everything the grid measures in pixels goes through it, so
    // a preset changes the whole keyboard proportionally — key height, gaps and
    // glyphs together — rather than stretching keys into letterboxes.
    property real uiScale: 1.0
    // How much width the panel can actually give the grid. A preset larger than
    // the output shrinks to fit instead of overflowing the card off-screen.
    // Zero means unconstrained (nothing has measured yet).
    property real availableWidth: 0

    // The panel's Theme facade over Omarchy's shared style tokens (spec-v1
    // §8). Passed in rather than reading `Color`/`Style` here, so that
    // `follow_theme` is decided in one place and the grid cannot end up
    // half-frozen.
    required property Theme theme

    // ---- Design tokens, copied 1:1 from the reference HTML/CSS ----
    readonly property real gapPx: Math.max(1, Math.round(root.theme.spacingMd * uiScale))
    readonly property real keyHeight: root.theme.space(42) * uiScale
    readonly property real keyRadius: root.theme.cornerRadius
    readonly property real containerMaxWidth: availableWidth > 0
        ? Math.min(root.theme.space(820) * uiScale, availableWidth)
        : root.theme.space(820) * uiScale
    // Rows fill the same total width as the container minus its own
    // padding (which equals the gap), exactly like the CSS container's
    // `padding: var(--gap)` around `.keyboard-grid`.
    readonly property real rowWidth: containerMaxWidth - 2 * gapPx

    // ---- Shared grid pitch (ticket 03, owner round 3) ----
    //
    // Every row is laid out on one cell size: a cap spans `w` cells, each
    // `cellPitch` wide including one gap, so its drawn width is
    // `w * cellPitch - gapPx`. This replaces the per-row proportional flex
    // that row sums of 13.95–17.25 units fed, and which rendered command-row
    // keys and arrows about 20% narrower than the letters above them. With
    // every row declared to the same gridUnits — the tables in
    // KeyboardLayout.js, guarded below — columns align across rows by
    // construction, all rows end flush at both edges
    // (`gridUnits * cellPitch - gapPx == rowWidth`), key sizes are
    // uniform between rows the way the Windows 11 touch keyboard's are, and
    // every width being a multiple of 0.5 keeps all rows' vertical gap lines
    // on one half-unit lattice: adjacent rows' gap lines are offset by
    // exactly half a unit — the classic stagger of the owner's measured
    // Windows reference — so every gap lands mid-key of the neighbouring
    // rows instead of on top of one.
    readonly property real gridUnits: 15.5
    readonly property real cellPitch: (root.rowWidth + root.gapPx) / root.gridUnits

    // ---- Hit geometry (ticket 15) ----
    //
    // The gaps are visual only. A cap is drawn at its own size, but the area
    // that answers the mouse reaches to the midpoint of the gap on every side
    // it shares with a neighbour, so the grid tiles and a click between two
    // caps lands on one of them instead of nowhere. This is a mouse-driven
    // keyboard; a miss costs a correction.
    //
    // Non-overlap is by construction, not by hope, and that is the whole of
    // the design. Neighbours in a row are exactly `gapPx` apart and each
    // claims `gapPx / 2` of it, so the two areas meet on a line and share no
    // area. Rows are `gapPx` apart in the Column and split it the same way,
    // which makes the row bands disjoint in y before the caps inside them are
    // considered at all. So the grid is a partition: a row band, then a column
    // within it. The line itself is not a tie either — `QQuickItem::contains`
    // is half-open, excluding the far edge, so a coordinate exactly on a
    // boundary belongs to the right (or lower) neighbour and to nothing else.
    // Nothing here is decided by stacking order, which is the failure this has
    // to avoid: two areas over one point would pick a winner by sibling order
    // and read as a random wrong character.
    //
    // Hover follows the hit area, so the cap that owns a gap lights up while
    // the pointer is in it. That is the intent, not a side effect: it is how
    // the user sees where the boundary is.
    readonly property real halfGap: gapPx / 2
    // What the outermost caps claim on their outward side. The card's padding
    // around the grid equals the gap (see `rowWidth` above), so this hands the
    // border strip to the caps against it and stops exactly where the card's
    // own chrome starts — the drag bar sits `gapPx` above the top row, so the
    // top row's area meets it rather than stealing from it.
    readonly property real edgeOutset: gapPx

    readonly property color keyBg: Util.alpha(root.theme.foreground, root.theme.normalFillAlpha)
    readonly property color keyHoverBg: Util.alpha(root.theme.foreground, root.theme.hoverFillAlpha)
    readonly property color keyActiveBg: Util.alpha(root.theme.foreground, root.theme.pressedFillAlpha)
    readonly property color keyBorderColor: Util.alpha(root.theme.foreground, root.theme.pressedFillAlpha)
    readonly property color accentColor: Util.alpha(root.theme.accent, root.theme.pressedFillAlpha)
    // The three modifier states, told apart by fill weight rather than by two
    // shades of one colour (spec-v1 §5): idle is the ordinary key, latched is
    // an accent tint under a thick accent outline, locked is solid accent with
    // the label knocked out.
    readonly property color latchedFill: root.theme.selectedAccentFill
    readonly property color lockedFill: root.theme.accent
    readonly property color lockedText: root.theme.background
    readonly property color textMain: root.theme.foreground
    readonly property color textDim: root.theme.muted
    readonly property color textHighlightColor: root.theme.foreground
    readonly property string keyboardFont: root.theme.fontFamily
    readonly property int keyBorderWidth: root.theme.normalBorderWidth
    // Doubled rather than taken straight from focusBorderWidth, which falls
    // back to the normal width on themes that do not set it — a latched
    // outline the same thickness as an idle one is not a distinguishable state.
    readonly property int latchedBorderWidth: Math.max(2 * keyBorderWidth, root.theme.focusBorderWidth)
    readonly property int keyFontSize: Math.max(1, Math.round(root.theme.fontBody * uiScale))
    readonly property int keySmallFontSize: Math.max(1, Math.round(root.theme.fontBodySmall * uiScale))

    // Every modifier's idle/latched state, Shift's additional locked state,
    // and Caps' dedicated boolean state, owned by the reducer (spec-v1 §15,
    // seam 2). The panel draws it; transitions and lines are the module's.
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
    // Names positively identified from the kernel/udev snapshot. A mouse's
    // keyboard-shaped HID interface is rejected before it reaches this list.
    property var startupKeyboards: []
    property string startupKeyboardName: ""
    property bool startupInventorySeen: false
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
    // Whether symbolMap is the compiled keymap's answer for the layout now
    // active, and whether the last attempt to make it so failed outright
    // (spec-v1.1 §3). `keycapsReady` starts false deliberately: the equality
    // shortcut below used to skip the first load whenever the detected layout
    // equalled the `us` default here, which left the map empty at cold start
    // and every symbols-page level cap blank until a layout change happened
    // to run. `keycapsFailed` is the keymap-wide state, not a per-cap miss —
    // a pipeline that failed, or exited cleanly having resolved nothing, is
    // decisions.md §11's silent failure, and the panel shows it instead of
    // letting the built-in table pass for the keymap.
    property bool keycapsReady: false
    property bool keycapsFailed: false
    // Incremented every time a keycap load starts, and captured by the
    // process for the run it is about to begin. A compile that is stopped
    // to make room for a newer load still dies by SIGTERM and still
    // delivers onExited; the captured generation is how that exit is told
    // apart from the live run's.
    property int keycapGeneration: 0
    // Which page is drawn (spec-v1 §4): main, symbols, or the curated page 2
    // (spec-v1.1 §3). A page is not a mode and not a modifier: it changes
    // what can be seen and nothing else — not the keymap, not the group, not
    // what any modifier is holding.
    property string page: "main"
    // Page 2's rows and its availability count, derived from symbolMap in the
    // same rebuild that feeds the keycaps — never per click (spec-v1.1 §3).
    // Availability is the active keymap's answer about itself, so it changes
    // when the keymap does: on a configured-layout change, a group switch, or
    // a keycap pipeline failure, each of which reloads symbolMap.
    property var curatedPage: Layout.curatedPageRows(symbolMap)
    property var layoutRows: Layout.applyLanguage(pageRows(), currentLayout, symbolMap)
    // A row that misses gridUnits is a defect, not a style choice: under the
    // shared pitch a short row stops short of the card's right edge and a
    // long one runs past it. A width off the half-unit lattice — anything
    // that is not a multiple of 0.5 — sums fine but puts that cap's edges
    // between everyone else's gap lines, which is the stagger defect the
    // tables exist to avoid. One loud line per offending row at rebuild
    // time, in the same spirit as reportMisses in KeyboardLayout.js.
    onLayoutRowsChanged: {
        for (var i = 0; i < layoutRows.length; i++) {
            var sum = 0
            for (var j = 0; j < layoutRows[i].length; j++) {
                var w = layoutRows[i][j].w || 1
                if ((w * 2) % 1 !== 0) {
                    console.error("[osk] row " + i + " cap " + j + " width "
                        + w + " is not a multiple of half a unit")
                }
                sum += w
            }
            if (Math.abs(sum - gridUnits) > 0.01) {
                console.error("[osk] row " + i + " widths sum to " + sum
                    + ", expected " + gridUnits)
            }
        }
    }

    // The page key's label names where the next press goes (spec-v1 §4): on
    // the main page that is always the symbols page; past it, the curated
    // page when it exists and the main page when it does not.
    function pageLabel() {
        if (page === "main") return "&123"
        if (page === "curated") return "ABC"
        return curatedPage.available >= Layout.curatedMinimum ? "€±§" : "ABC"
    }

    function pageRows() {
        var rows = page === "curated" ? curatedPage.rows
            : page === "symbols" ? Layout.symbolRows(pageLabel()) : Layout.rows
        if (!modifierState.fn) return rows
        var replaced = rows.slice()
        replaced[0] = Layout.functionRow
        return replaced
    }

    function updateLayoutRows() {
        // A keymap change while page 2 is on screen can drop it below the
        // eight-symbol threshold; the page then no longer exists, and the
        // grid falls back to the main page rather than drawing a stub.
        if (page === "curated" && curatedPage.available < Layout.curatedMinimum)
            page = "main"
        layoutRows = Layout.applyLanguage(pageRows(), currentLayout, symbolMap)
    }

    /// The one key in and the same key out. The reducer is told, so that what
    /// the modifiers do across a switch is decided in the one place the seam
    /// covers rather than here; it holds everything where it was, which is why
    /// locked Shift is still locked and still drawn locked on the far side.
    /// The cycle is main → symbols → curated → main, and the curated hop
    /// exists only when page 2 does (eight or more symbols available,
    /// spec-v1.1 §3) — the label always names the destination, so when the
    /// hop is missing the symbols page's key reads "ABC" again.
    function togglePage() {
        page = page === "main" ? "symbols"
            : page === "symbols" && curatedPage.available >= Layout.curatedMinimum
                ? "curated" : "main"
        updateLayoutRows()
        applyModifierEvent({ type: "pageSwitch" })
    }

    /// Both readers below are fed the same thing: a run of tab-delimited
    /// records on a helper's stdout, one per line, blank lines meaning nothing.
    /// Turning that into fields is the whole of what they have in common, so it
    /// is written once here rather than twice with two chances to drift. Short
    /// records survive on purpose — a record whose only field is its tag is
    /// meaningful to one of the callers, so the arity guard belongs to whoever
    /// needs it, not here.
    function tabRecords(text) {
        return String(text || "").split("\n")
            .map(function (line) { return line.trim() })
            .filter(function (line) { return line.length > 0 })
            .map(function (line) { return line.split("\t") })
    }

    /// Resolves the pipeline's tab records over symbolMap and returns how
    /// many records resolved. Nothing is installed for a record-less run:
    /// the caller owns the §11 decision, and pre-installing an empty map
    /// here would be the silent-empty class this gate exists to close.
    function parseLayoutSymbolOutput(text) {
        var map = ({})
        var records = 0
        tabRecords(text).forEach(function (parts) {
            if (parts.length < 2) return
            // Every level the pipeline carried: two for as long as the
            // symbols page cared, four now that the curated page resolves
            // the keymap's AltGr levels too (spec-v1.1 §3). Missing levels
            // stay empty strings, which the overlay and the curated index
            // both read as "nothing here".
            map[parts[0]] = parts.slice(1)
            records += 1
        })
        if (records > 0) {
            symbolMap = map
            updateLayoutRows()
        }
        return records
    }


    function parseHyprLayoutOutput(text) {
        var active = ""
        var detected = []
        var names = ({})
        var configGroup = 0

        tabRecords(text).forEach(function (parts) {
            if (parts[0] === "DEVICE") {
                // Cleared unconditionally: a refresh that finds no safe
                // target must not leave the language button aiming at a
                // device that has gone missing or was never safe to advance.
                // An empty name lands here as a bare "DEVICE" after the line
                // trim, so this branch has to come before the field-count
                // guard below.
                typedKeyboard = String(parts[1] || "").trim()
                return
            }
            if (parts.length < 2) return
            if (parts[0] === "ACTIVE") {
                active = String(parts[1] || "").trim()
                return
            }
            if (parts[0] === "CONFIG" && parts.length >= 8) {
                xkbRules = parts[1]
                xkbModel = parts[2]
                xkbLayouts = parts[3]
                xkbVariants = parts[4]
                xkbOptions = parts[5]
                xkbFile = parts[6] === "[[EMPTY]]" ? "" : parts[6]
                configGroup = parseInt(parts[7]) || 0
                return
            }
            if (parts[0] === "LAYOUT") {
                detected.push(String(parts[1] || "").trim())
            }
            if (parts[0] === "NAME" && parts.length >= 3) {
                names[String(parts[1] || "").trim()] = String(parts[2] || "").trim()
            }
        })

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
            // Load when the layout changed, or whenever the keymap's own
            // answer is not in hand yet. The equality test alone was the
            // cold-start defect: `currentLayout` starts at "us", so a session
            // opening on `us` — the default guest config — never asked the
            // keycap pipeline at all, and the symbols page drew one blank cap
            // per position. The second half of the condition is also the
            // retry: a failed or empty pipeline leaves `keycapsReady` false,
            // so the next layout event (a helper recovery, a config reload,
            // the keyboards inventory) tries again on its own. No polling.
            if (selected !== currentLayout || !keycapsReady)
                loadLanguageLayout(selected)
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
        // advances) comes from those same two tiers. At startup the named tier
        // is seeded by the helper's positive physical-device snapshot; a real
        // layout event replaces it. Advancing a guessed device is what
        // poisoned the seat before: a mouse advanced
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
            + "selection=$(printf '%s' \"$devices\" | jq -c --arg named \"$1\" --arg safe \"$2\" '"
            + "[.keyboards[] | select((.name | test(\"^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)|omarchy-osk\"; \"i\")) | not)] as $typed | "
        + "def safe_name($name): $safe | split(\"\\n\") | any(. as $base | $base != \"\" and ($name == $base or (($name | startswith($base + \"-\")) and ($name[($base | length) + 1:] | test(\"^[0-9]+$\"))))); "
        + "[$typed[] | select(safe_name(.name))] as $safe_typed | "
        + "($typed | map(select(.main == true)) | .[0]) as $current | "
        + "($typed | map(select(.name == $named)) | .[0]) as $named_device | "
        + "($safe_typed | map(select(.main == true)) | .[0]) as $safe_current | "
        + "($safe_typed | map(select(.name == $named)) | .[0]) as $safe_named | "
        + "{keyboard: ($current // $named_device // ($typed | max_by(.active_layout_index // 0)) // null), "
        + "switchable: (($safe_current // $safe_named // {name: \"\"}) | .name)}' 2>/dev/null); "
        + "keyboard=$(printf '%s' \"$selection\" | jq -c '.keyboard // empty'); "
        + "[[ -n \"$keyboard\" ]] || exit 1; "
        + "switchable=$(printf '%s' \"$selection\" | jq -r '.switchable // \"\"'); "
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
            + "done", "onscreen-keyboard", typedKeyboardName, startupKeyboards.join("\n")]
        layoutDetectProcess.running = true
    }

    function loadLanguageLayout(layoutCode) {
        console.log("[osk] loadLanguageLayout:", layoutCode, "variant-index:", layoutCycleIndex)
        // A load is now in flight: only its own successful result may say the
        // caps are ready. Cleared here rather than left at its old value so a
        // failure mid-switch cannot strand the panel reporting a map that
        // belongs to the previous layout.
        keycapsReady = false
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
        // A load that is still running gets stopped for this one, and its
        // death by SIGTERM still delivers onExited. The counter increment is
        // what marks every run before this one superseded; the process
        // records the generation only when a run actually starts, which is
        // what lets the exit handler attribute each exit to its run.
        root.keycapGeneration += 1
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
            + "       gsub(/[[:space:]]+/, \"\", arr[3])\n"
            + "       gsub(/[[:space:]]+/, \"\", arr[4])\n"
            + "       print name \"\\t\" arr[1] \"\\t\" arr[2] \"\\t\" arr[3] \"\\t\" arr[4]\n"
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
        // The generation of the run actually executing, recorded at start —
        // not at request. Quickshell defers a start requested while the
        // previous run is still dying until that run's exit has been
        // delivered, so a superseded run's exit arrives after the request
        // counter has already moved on but before any newer process exists.
        // Attributing each exit to the generation that was started is the
        // only comparison that survives that window; request-time slots and
        // isRunning() both read as current and wave the stale exit through.
        property int startedGeneration: 0
        onStarted: startedGeneration = root.keycapGeneration
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
            var cleanExit = exitCode === 0 && exitStatus === 0
            console.log("[osk] keycaps process exited:", exitCode, exitStatus, "collected bytes:", collected.length)
            // A superseded compile dies by SIGTERM when the next load stops
            // it, and that exit is delivered after the request counter has
            // moved on but before the replacement process has started. An
            // exit whose run began under an older generation therefore says
            // nothing about the load now pending: it must not drop the map
            // or raise the failure state — the live run's own exit decides
            // that.
            if (layoutLoadProcess.startedGeneration !== root.keycapGeneration) {
                console.log("[osk] keycaps exit superseded; the live load decides")
                return
            }
            if (cleanExit) {
                // Records, not bytes: a clean exit whose stdout holds only a
                // stray non-record line resolves nothing, and counting its
                // bytes would install an empty map as ready — the §11
                // silent-empty class this gate exists to close.
                var records = root.parseLayoutSymbolOutput(layoutLoadProcess.collected)
                if (records > 0) {
                    root.keycapsReady = true
                    root.keycapsFailed = false
                    return
                }
                console.error("[osk] keycap pipeline resolved 0 records for "
                    + root.currentLayout)
            } else {
                console.error("[osk] keycap pipeline failed for "
                    + root.currentLayout + " (exit " + exitCode + "/" + exitStatus + ")")
            }
            // Both failure shapes are the §11 mode, not an empty layout: a
            // compiled keymap always names its key positions, so a failed or
            // record-less run means the pipeline answered the wrong question.
            // Drop the map and raise the panel's keymap-wide state.
            root.symbolMap = ({})
            root.keycapsReady = false
            root.keycapsFailed = true
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

    // Hyprland's IPC has no input-device hotplug event. udev does, so one
    // event stream requests fresh helper/compositor snapshots on add/remove.
    // It wakes for events only; there is no seat poll or heartbeat.
    Process {
        id: inputDeviceMonitor
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=input", "--property"]
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                if (line === "ACTION=add" || line === "ACTION=remove")
                    root.sendCommandUnchecked("keyboards")
            }
        }
    }

    /// Runs one event through the reducer and writes whatever it says to
    /// write. The only path modifier state changes on, so the panel cannot
    /// drift from what the seam's tests cover.
    ///
    /// Protocol-bearing events are refused while the helper is not ready,
    /// rather than advancing state over writes that go nowhere: a lock whose
    /// `down` was dropped would leave the cap showing a modifier the compositor
    /// never received. Caps and Fn are exceptions because they are local
    /// semantic controls and emit no protocol line; reconnecting must not
    /// delay them.
    function applyModifierEvent(event) {
        if (!inputReady && (!event || (event.type !== "capsClick" && event.type !== "fnClick"))) return
        var outcome = Modifiers.reduce(modifierState, event)
        modifierState = outcome.state
        for (var i = 0; i < outcome.lines.length; i++) {
            sendCommand(outcome.lines[i])
        }
    }

    /// Lifts locked Shift and returns every modifier to idle. The panel closing
    /// is not the compositor forgetting: locked Shift is really held at the
    /// device and must come up before the socket goes away.
    function releaseModifiers() {
        applyModifierEvent({ type: "releaseAll" })
    }

    function shiftActive() {
        return Modifiers.isActive(modifierState, "shift")
    }

    function isUpper() {
        return modifierState.caps !== shiftActive()
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
    // A symbols-page cap is never dual: it stands for one level, and the level
    // above it has its own cap on the row below.
    function isDualKey(keyData) {
        return !keyData.lvl && !!keyData.s && !isLetterKey(keyData)
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
                    if (reply === "hello 3") {
                        root.inputReady = false
                        root.inputStatus = "configuring"
                        // The helper released everything this panel's old
                        // connection held when that socket closed, so a
                        // locked modifier did not survive the reconnect
                        // however the indicator looked. Reset to match, and
                        // do it without emitting the releases — sending `up`
                        // for a code nobody holds is a lie in the other
                        // direction.
                        // Caps is a semantic panel control, not a held key on
                        // this connection, so a helper restart does not turn
                        // it off. Only the real device-held modifiers reset.
                        root.modifierState = Modifiers.reduce(
                            root.modifierState, { type: "releaseAll" }).state
                        daemon.write("mods 0\n")
                        daemon.write("keyboards\n")
                        daemon.flush()
                        // A restarted helper is back at group 0 and has no idea
                        // which layout is current. Re-reading the compositor
                        // sends the right group; using layoutCycleIndex here
                        // would send whatever it held before the first sync,
                        // which is 0 on a fresh panel and would force the
                        // first layout.
                    } else if (reply === "keyboards" || reply.indexOf("keyboards\t") === 0) {
                        var names = reply.split("\t").slice(1).filter(function(name) {
                            return name.length > 0
                        })
                        root.startupKeyboards = names
                        if (!root.startupInventorySeen) {
                            root.startupInventorySeen = true
                            root.startupKeyboardName = names.length > 0 ? names[0] : ""
                            if (!root.typedKeyboardName)
                                root.typedKeyboardName = root.startupKeyboardName
                        }
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
                root.daemonSocket.write("hello 3\n")
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
            // A level cap draws one level and has to type that level. Same
            // treatment as Caps Lock: real modifier presses around the key,
            // never a character the panel picked for itself — Shift for
            // level 2, AltGr (with Shift) for the curated page's levels 3
            // and 4 (spec-v1.1 §3). The reducer decides how those presses
            // wrap around the key and what a lock does to them.
            shift: keyData.lvl === 2 || keyData.lvl === 4,
            altgr: keyData.lvl === 3 || keyData.lvl === 4
        })
    }

    /// The release half of every cap that types. The key stayed down for as
    /// long as the mouse button did, which is what let the compositor repeat
    /// it; this lifts it, and the modifiers that were wrapped around it.
    function releaseKey() {
        applyModifierEvent({ type: "release" })
    }

    function pressSpecial(keyData, doubleClick) {
        switch (keyData.key) {
        case "close": closeRequested(); return
        case "emoji": Quickshell.execDetached(["omarchy-menu-emoji"]); return
        // Not a keystroke, so no click sound, for the same reason close is
        // silent: nothing was typed.
        case "page": togglePage(); return
        case "fn":
            applyModifierEvent({ type: "fnClick" })
            updateLayoutRows()
            return
        case "caps":
            root.keyPressed()
            applyModifierEvent({ type: "capsClick" })
            return
        }
        if (Modifiers.isModifier(keyData.key)) {
            // One click per physical press, and a lock is two presses, not
            // three: `doubleClick` arrives on top of the second press's own
            // click (issue 17) and would otherwise sound a third time.
            if (!doubleClick) root.keyPressed()
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

    /// Caps has exactly "off" and "on"; the real modifiers have "idle",
    /// "latched" and "locked" so all of their states remain distinguishable.
    function keyModifierState(keyData) {
        if (keyData.key === "caps") return modifierState.caps ? "on" : "off"
        if (keyData.key === "fn") return modifierState.fn ? "on" : "off"
        if (!Modifiers.isModifier(keyData.key)) return "idle"
        return modifierState[keyData.key]
    }

    Column {
        id: grid
        anchors.bottom: parent.bottom
        spacing: root.gapPx

        Repeater {
            model: root.layoutRows
            delegate: Row {
                id: rowItem
                spacing: root.gapPx
                readonly property var rowModel: modelData
                // `index` is the Repeater's, and the inner delegate's own
                // `index` shadows it, so the row's position is carried here.
                readonly property int rowIndex: index
                readonly property real hitTop: rowIndex === 0 ? root.edgeOutset : root.halfGap
                readonly property real hitBottom: rowIndex === root.layoutRows.length - 1
                    ? root.edgeOutset : root.halfGap

                Repeater {
                    model: rowModel
                    delegate: Item {
                        id: keyDelegate
                        property var keyData: modelData
                        width: (keyData.w || 1) * root.cellPitch - root.gapPx
                        height: root.keyHeight
                        readonly property real hitLeft: index === 0
                            ? root.edgeOutset : root.halfGap
                        readonly property real hitRight: index === rowItem.rowModel.length - 1
                            ? root.edgeOutset : root.halfGap

                        Rectangle {
                            id: keyRect
                            // A spacer slot ({ w } alone — the curated page's
                            // unfilled slots and its free row's pad) draws
                            // nothing: the page never shows a blank cap. An
                            // invisible item takes no mouse events either, so
                            // a dead slot stays dead while its neighbours'
                            // hit areas keep meeting at its midpoints.
                            visible: !Layout.isBlank(keyData)
                            anchors.fill: parent
                            radius: root.keyRadius

                            // Three states have to be told apart at a glance
                            // (spec-v1 §5), so they differ in more than
                            // shade: latched is an accent outline over the
                            // ordinary fill, locked is filled accent. One
                            // reads as armed, the other as held down.
                            property string modState: root.keyModifierState(keyData)
                            property bool latched: modState === "latched"
                            property bool locked: modState === "locked"
                            property bool toggleOn: modState === "on"
                            property bool isDual: root.isDualKey(keyData)
                            // Whether this cap types, which is the same test
                            // `onPressed` makes: a character, or a keysym with
                            // a position behind it. The modifiers and the
                            // command caps are neither. Caps acts on press;
                            // the remaining commands act on click.
                            property bool types: !keyData.key
                                || !!Layout.positionForKeysym(keyData.key)

                            color: (locked || toggleOn) ? root.lockedFill
                                : latched ? root.latchedFill
                                : mouseArea.pressed ? root.keyActiveBg
                                : mouseArea.containsMouse ? root.keyHoverBg
                                : root.keyBg
                            border.color: (latched || locked || toggleOn) ? root.theme.accent
                                : root.keyBorderColor
                            border.width: latched ? root.latchedBorderWidth : root.keyBorderWidth

                            Text {
                                visible: !keyRect.isDual
                                anchors.centerIn: parent
                                text: keyData.label
                                    ? keyData.label
                                    : root.resolvedTypedChar(keyData)
                                color: (keyRect.locked || keyRect.toggleOn)
                                    ? root.lockedText : root.textMain
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
                                // Deliberately larger than the cap it belongs
                                // to: negative margins push it out to the
                                // midpoint of each gap (and to the card's
                                // padding at the grid's edges), so the areas
                                // tile the grid while the drawn caps keep the
                                // spacing they have always had. Nothing here
                                // clips — neither the Rectangle, nor the
                                // delegate Item, nor the Row and Column
                                // positioners — so Qt still delivers presses
                                // that land outside the cap's own rectangle.
                                anchors.fill: parent
                                anchors.leftMargin: -keyDelegate.hitLeft
                                anchors.rightMargin: -keyDelegate.hitRight
                                anchors.topMargin: -rowItem.hitTop
                                anchors.bottomMargin: -rowItem.hitBottom
                                hoverEnabled: true

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
                                //
                                // The modifiers are here too now (issue 17).
                                // They used to wait for the click and then a
                                // further 250 ms, in case a second click was
                                // coming that would make it a lock — which the
                                // owner felt, correctly, as a quarter-second
                                // of lag on every Shift. They latch on the way
                                // down instead and the lock upgrades them,
                                // which costs nothing and waits for nothing.
                                // What makes that safe is the measured order
                                // of the signals: for two fast taps a real
                                // MouseArea emits
                                //
                                //   pressed, released, clicked,
                                //   pressed, doubleClicked, released
                                //
                                // so `doubleClicked` arrives on the way *down*
                                // of the second press, before its own
                                // `released`. The second press is therefore
                                // seen first as a click on a latched modifier
                                // — which §5 says returns it to idle, never to
                                // locked — and the reducer rolls that back
                                // when the lock lands a moment later.
                                //
                                // The window in which the cap holds that
                                // intermediate idle is one event delivery, not
                                // a timer, so the worst it can cost is a
                                // single frame of the idle fill during a
                                // double click. That it is *zero* frames was
                                // not established: QTest injects the whole
                                // sequence in one pass and so cannot measure
                                // what the compositor's own delivery does.
                                // The bound is what is claimed here, and it is
                                // the residual the by-hand retest looks for.
                                onPressed: {
                                    if (!keyData.key) {
                                        root.pressChar(keyData)
                                        return
                                    }
                                    if (Layout.positionForKeysym(keyData.key)
                                            || Modifiers.isModifier(keyData.key)
                                            || keyData.key === "caps"
                                            || keyData.key === "fn"
                                            || keyData.key === "page") {
                                        root.pressSpecial(keyData, false)
                                    }
                                }

                                // The key is held for as long as the button
                                // is, so the compositor repeats it at the
                                // user's own repeat_delay and repeat_rate
                                // (spec-v1 §6) and the panel runs no repeat
                                // timer of its own. `canceled` matters as much
                                // as `released`: a grab lost to a popup or to
                                // the panel closing has to lift the key too,
                                // or it repeats into the focused window until
                                // the helper's cap notices.
                                onReleased: if (keyRect.types) root.releaseKey()
                                onCanceled: if (keyRect.types) root.releaseKey()

                                // What is left on the click is only the
                                // command caps that would tear something out
                                // from under the button still held — close,
                                // emoji. They are deliberately not swept into
                                // the press path with the modifiers. They also
                                // pay Qt's second-press suppression (issue 13)
                                // for it, which is survivable here because
                                // nobody double-clicks Close to close twice.
                                //
                                // The page control is no longer one of them
                                // (spec-v1.1 §3): waiting for `clicked` lost
                                // every second press of a rapid pair to the
                                // same suppression, and unlike close it tears
                                // nothing out from under the pointer — the
                                // grid rebuilds in place under the button,
                                // the command row keeps its place, and the
                                // next press lands on the same spot. So it
                                // acts on the way down, one press per press.
                                onClicked: {
                                    if (!keyData.key) return
                                    if (Layout.positionForKeysym(keyData.key)) return
                                    if (Modifiers.isModifier(keyData.key)) return
                                    if (keyData.key === "caps") return
                                    if (keyData.key === "fn") return
                                    if (keyData.key === "page") return
                                    root.pressSpecial(keyData, false)
                                }

                                onDoubleClicked: {
                                    if (!keyData.key || !Modifiers.isModifier(keyData.key)) return
                                    root.pressSpecial(keyData, true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
