import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "KeyboardLayout.js" as Layout
import "ModifierReducer.js" as Modifiers
import "KeyboardSession.js" as Session
import "Config.js" as ConfigFile
import "LayoutDevices.js" as LayoutDevices

Item {
    id: root
    implicitWidth: grid.implicitWidth
    // Pinned to the taller of the two pages rather than to whichever is on
    // screen. Docked mode reserves this height (§7), so letting it follow the
    // current page would shove every window on the output up and down each time
    // &123 is pressed. The grid is anchored to the bottom, so the command row —
    // modifiers, space, arrows, and the page key itself — stays under the
    // pointer across a switch and the slack appears at the top.
    readonly property int maxPageRows: Math.max(Layout.rows.length,
        Layout.symbolRows("").length)
    implicitHeight: maxPageRows * keyHeight + (maxPageRows - 1) * gapPx
    signal closeRequested()
    // Emitted for every keystroke-shaped press — letters, arrows, modifier
    // clicks, Caps Lock — and never for the panel's own UI actions. The panel
    // plays the key click sound on it (spec-v1 §10).
    signal keyPressed()
    // The ☺ cap's PATH probe succeeded (spec-v1.1 §1). The panel owns the
    // session: Emote is toggled (closewindow of the identified appearance,
    // never a second exec); other apps still launch. Arm happens before
    // execDetached so a fast map cannot arrive against a null session.
    signal emojiCapActivated(string app)

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
    // Key radius is the facade's resolved 0–24 value at medium, scaled by
    // the size preset so 24 stays a circle at L/XL (spec-v1.1 §4). Panel
    // radius is a separate pixel control and does not use this.
    readonly property real keyRadius: ConfigFile.effectiveKeyRadius(
        root.theme.keyRadius, uiScale)
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

    // The three key fills are the facade's resolved tokens: an explicit key
    // background override pins the resting fill, and hover/press are a
    // modest mix of that resting cap toward the theme foreground either
    // way (Theme.qml owns that derivation and the precedence).
    readonly property color keyBg: root.theme.keyFill
    readonly property color keyHoverBg: root.theme.keyHoverFill
    readonly property color keyActiveBg: root.theme.keyActiveFill
    readonly property color keyBorderColor: Util.alpha(root.theme.foreground, root.theme.pressedFillAlpha)
    readonly property color accentColor: Util.alpha(root.theme.accent, root.theme.pressedFillAlpha)
    // The three modifier states, told apart by fill weight rather than by two
    // shades of one colour (spec-v1 §5): idle is the ordinary key, latched is
    // an accent tint under a thick accent outline, locked is solid accent with
    // the label knocked out.
    readonly property color latchedFill: root.theme.selectedAccentFill
    readonly property color lockedFill: root.theme.accent
    readonly property color lockedText: root.theme.background
    // Glyph colour: the facade's resolved text token (override, else the
    // theme's foreground). The theme's muted stays the secondary text colour —
    // "dim" is a relation to the theme's palette, not to a pinned colour.
    readonly property color textMain: root.theme.textColor
    readonly property color textDim: root.theme.muted
    readonly property color textHighlightColor: root.theme.textColor
    readonly property string keyboardFont: root.theme.fontFamily
    readonly property int keyBorderWidth: root.theme.normalBorderWidth
    // Doubled rather than taken straight from focusBorderWidth, which falls
    // back to the normal width on themes that do not set it — a latched
    // outline the same thickness as an idle one is not a distinguishable state.
    readonly property int latchedBorderWidth: Math.max(2 * keyBorderWidth, root.theme.focusBorderWidth)
    readonly property int keyFontSize: Math.max(1, Math.round(root.theme.fontBody * uiScale))
    readonly property int keySmallFontSize: Math.max(1, Math.round(root.theme.fontBodySmall * uiScale))
    // Super's compact mark (spec-v1.1 §1): U+E900 / family `omarchy`, the
    // same request the bar menu launcher makes. Qt.fontFamilies(),
    // FontLoader, fontInfo.family, and a zero-width paint miss or
    // substitute this private family, so the packaged TTF path is the
    // gate: an absent file never requests U+E900 and the Super label
    // stays readable. Sized to the cap so it stays recognizable at M/L/XL.
    FileView {
        id: omarchyIconFontFile
        path: "/usr/share/fonts/omarchy/omarchy.ttf"
        preload: true
        blockLoading: true
        printErrors: false
        property bool present: false
        onLoaded: present = true
        onLoadFailed: function (error) {
            present = error !== FileViewError.FileNotFound
        }
    }
    readonly property bool omarchyFontPresent: omarchyIconFontFile.present
    readonly property int superLogoSize: Math.max(root.keyFontSize,
        Math.round(root.keyHeight * 0.5))

    // Every modifier's idle/latched state, Shift's additional locked state,
    // and Caps' dedicated boolean state, owned by the reducer (spec-v1 §15,
    // seam 2). The panel draws it; transitions and lines are the module's.
    property var modifierState: Modifiers.initialState()
    property string currentLayout: "us"
    property var languageCycle: ["us"]
    // The active GROUP index, taken from the compositor's own
    // active_layout_index (spec-v1 §9's "compositor decides"). Selects the
    // variant and kb_file group the keycap compile answers with; a repeated
    // layout code (`us,us` with distinct variants) makes code-position
    // guessing wrong, so nothing here derives the group from the code.
    property int layoutCycleIndex: 0
    property var layoutNameMap: ({})
    // The keyboard the switch is applied to. Switching "all" moves every device
    // on the seat, including pseudo-keyboards that never advance on their own,
    // which is how they end up sitting on different layouts from each other.
    property string typedKeyboardName: ""
    // Every device carrying the same layout list. A language-button click
    // moves this set to one absolute group, matching the shell's layout
    // widget and converging a seat whose per-device groups drifted apart.
    property var switchKeyboards: []
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
    // Configure transaction bookkeeping for the device-held-modifier
    // handshake. The helper drains every key it holds for us when — and only
    // when — a configure CHANGES the keymap (its same-keymap short-circuit
    // keeps holds alive across a group-only or byte-identical reconfigure),
    // and the panel must mirror that: keep the lock across a same-keymap
    // configure, drop it without re-sending releases across a changed one.
    //
    // The socket is ordered, so a reply always settles the OLDEST
    // outstanding configure — configures pipeline (an event storm around a
    // reload refreshes layouts faster than replies come back), so pairing
    // a reply with the newest sent payload attributed the wrong identity
    // whenever two were in flight. This object owns the whole ledger so the
    // enqueue/settle/rebase/readiness rules have exactly one home:
    //
    // `queue` — {payload, identity, changed, seq}, one per configure
    //   written, oldest first. A `configured` reply pops the oldest and
    //   applies THAT entry's consequences; a configure's own failure
    //   (`err cannot configure keymap` — the only err a well-formed
    //   configure can earn) drops its own entry and rebases the survivors
    //   against the keymap the helper still has installed.
    // `acked` — the keymap identity the helper last acknowledged. The drain
    //   question is relative to what the helper has INSTALLED: the last
    //   acked identity when the queue is empty, otherwise the newest
    //   queued entry's identity.
    // `sends` — a monotonic send counter, incremented when the configure is
    //   WRITTEN. Chords are stamped with it at press (the pending record
    //   carries it), so an equal stamp means the configure was sent before
    //   the press — the helper drains it ahead of the press lines — and a
    //   press stamped later happened after the send. This is also the
    //   readiness answer: typing stays gated until the queue is fully
    //   settled, because an outstanding configure may still be compiling
    //   the keymap a press would land in.
    // The keyboard session (KeyboardSession.js, ticket 04): connection
    // handshake, configure transactions, and the keymap-generation
    // correlation for the keycap facts. Reassigned wholesale on every
    // transition, so every binding that reads it re-fires. The invariants
    // the queue carries are unchanged:
    //
    // The socket is ordered, so a reply always settles the OLDEST
    // outstanding configure — configures pipeline (an event storm around a
    // reload refreshes layouts faster than replies come back), so pairing
    // a reply with the newest sent payload attributed the wrong identity
    // whenever two were in flight.
    //
    // `sends` — a monotonic send counter, incremented when the configure is
    //   WRITTEN. Chords are stamped with it at press (the pending record
    //   carries it), so an equal stamp means the configure was sent before
    //   the press — the helper drains it ahead of the press lines — and a
    //   press stamped later happened after the send.
    //
    // Version 4 adds the generation: every `configured` reply names the
    // keymap install it produced and every `caps` reply names the install
    // its facts were computed from (decisions §23). The session accepts
    // facts only when generation AND group match the acknowledged world,
    // which is what makes a superseded reply discardable and keeps the
    // drawn caps from ever describing a keymap the helper no longer has.
    property var session: Session.initial()
    // Every drawn cap's facts (decisions §23). Since ticket 18 there is no
    // second source: the §11 xkbcli pipeline that used to supply the curated
    // page was removed once every cap became a glyph cap, so nothing spawns a
    // compile per layout change and nothing can report a keymap unavailable
    // for a map no cap draws from. Null while the acknowledged world has no
    // facts — the built-in table then draws as the gated last-resort fallback,
    // silently (the status line owns saying why).
    readonly property var capsFacts: Session.capsMap(session)
    // Set when a caps request went unanswered in a way that proves
    // disagreement (an unreadable reply, `err bad group`), and cleared only
    // by accepted facts. Panel-hint state: an honest keymap-wide unavailable,
    // never per-cap.
    property bool capsFactsFailed: false
    // Every positioned cap the panel can draw, in declaration order — the
    // position list a caps request carries. Built once from the page
    // declarations: the helper resolves what the panel actually shows, not
    // every key the keymap happens to define.
    readonly property string capsPositions: {
        var seen = {}
        var out = []
        var pages = [Layout.rows, Layout.symbolRows("")]
        for (var p = 0; p < pages.length; p++) {
            for (var r = 0; r < pages[p].length; r++) {
                for (var c = 0; c < pages[p][r].length; c++) {
                    var pos = pages[p][r][c].k
                    if (pos && !seen[pos]) {
                        seen[pos] = true
                        out.push(pos)
                    }
                }
            }
        }
        if (!seen.RALT) out.push("RALT")
        // The reserved block's positions (ticket 18). They appear in no page
        // declaration — a glyph cap names a character and lets the keymap say
        // which position carries it — so they are asked for by name here.
        for (var i = 0; i < Layout.reservedPositions.length; i++) {
            var reserved = Layout.reservedPositions[i]
            if (!seen[reserved]) {
                seen[reserved] = true
                out.push(reserved)
            }
        }
        return out.join(" ")
    }

    /// The caps request for one group: the group, then the declared
    /// positions. The helper answers per level from the keymap it installed,
    /// tagged with that install's generation.
    function capsRequestLine(group) {
        return "caps " + group + (capsPositions !== "" ? " " + capsPositions : "")
    }

    // How many groups the configured keymap carries — one per layout in the
    // RMLVO list, which is how libxkbcommon builds it and how the helper
    // counts the groups it pre-resolves. Clamped to xkbcommon's own maximum
    // so an over-long layout list cannot make the panel ask for a group the
    // compiled keymap does not have.
    readonly property int groupCount: {
        var listed = String(xkbLayouts || "").split(",").filter(function (code) {
            return code.trim().length > 0
        }).length
        return Math.max(1, Math.min(listed, 4))
    }
    // The emoji cap's spawn answer (spec-v1.1 §1), raised when the configured
    // picker cannot be found on PATH at click time. Same swap the keymap
    // failure uses — the panel's one hint line names this failure in the
    // accent colour and hands the hint back on recovery (a successful probe,
    // or the auto-clear below). Transient by design: it answers the click
    // just made, then gets out of the way; typing and panel readiness never
    // consult it.
    property bool emojiFailed: false
    // The app the ☺ cap execs — the panel's resolved override-over-default
    // (spec-v1.1 §1). Bare PATH name; the probe and the hint both name it.
    property string emojiAppName: "omarchy-menu-emoji"
    // Which page is drawn: main or symbols. A page is not a mode and not a
    // modifier: it changes what can be seen and nothing else — not the
    // keymap, not the group, not what any modifier is holding.
    property string page: "main"
    property var layoutRows: Layout.applyLanguage(pageRows(), currentLayout, capsFacts)
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

    // The page key's label names where the next press goes.
    function pageLabel() {
        return page === "main" ? "&123" : "ABC"
    }

    function pageRows() {
        var rows = page === "symbols" ? Layout.symbolRows(pageLabel()) : Layout.rows
        if (!modifierState.fn) return rows
        if (page === "symbols") return Layout.symbolFunctionRows(pageLabel())
        var replaced = rows.slice()
        replaced[0] = Layout.functionRow
        return replaced
    }

    // `layoutRows` is the Repeater's model, and reassigning it destroys and
    // rebuilds every row and every cap delegate under it — a few hundred QML
    // objects, enough main-thread work to be seen. A language switch used to
    // do that four times over: once for the load, once when the facts were
    // invalidated, once when they came back, once when the symbol pipeline
    // exited. Most of those rebuilds produced rows identical to the ones
    // already on screen, so compare first and only reassign when the caps
    // actually differ. The caps are flat objects of primitives built from the
    // same declarations in the same order, so serialising is a sound identity
    // test and costs far less than the rebuild it avoids.
    function updateLayoutRows() {
        if (page !== "main" && page !== "symbols")
            page = "main"
        var next = Layout.applyLanguage(pageRows(), currentLayout, capsFacts)
        if (JSON.stringify(next) === JSON.stringify(layoutRows)) return
        layoutRows = next
    }

    // Keycap facts arrive after the configure acknowledgement. `layoutRows`
    // is assigned imperatively so identical rows can avoid rebuilding the
    // delegates; refresh it when the facts it draws from change.
    onCapsFactsChanged: updateLayoutRows()

    /// The one key in and the same key out. The reducer is told, so that what
    /// the modifiers do across a switch is decided in the one place the seam
    /// covers rather than here; it holds everything where it was, which is why
    /// locked Shift is still locked and still drawn locked on the far side.
    /// Cycle: main → symbols → main. The label names the destination.
    function togglePage() {
        page = page === "main" ? "symbols" : "main"
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

    /// Queues and writes one configure transaction. The session assigns the
    /// transaction's seq BEFORE the write, so a chord stamped sends ===
    /// entry.seq was pressed at or after the send — the ordering the drain
    /// decision below rests on.
    function sendConfigure(configure) {
        session = Session.reduce(session, { type: "configureSent", payload: configure })
        sendCommandUnchecked(configure)
    }

    /// Applies a `configured` reply to the oldest outstanding configure
    /// transaction. A changed-keymap entry settles the device world as
    /// authoritative (configureDrain — the reducer's device-held modifiers
    /// reset without emitting); a same-keymap entry leaves holds and
    /// reducer state exactly as they are. The reply's generation becomes
    /// the acknowledged one, which is also what instantly invalidates any
    /// keycap facts computed from the superseded install (decisions §23).
    function settleConfigureReply(gen) {
        // The FIFO head is the transaction this reply settles; the session
        // pops the same entry, so capture its facts first.
        var entry = session.queue.length > 0 ? session.queue[0] : null
        session = Session.reduce(session, { type: "configureAck", gen: gen })
        if (!entry) return
        if (!entry.changed) return
        modifierState = Modifiers.reduce(modifierState,
            { type: "configureDrain", stamp: entry.seq }).state
    }

    // The file the helper publishes its installed keymap to, and the
    // generation this panel last pointed the compositor at.
    //
    // One keymap on the seat or two: with two, the compositor hands a focused
    // client whichever keyboard is active and the client's group resets on
    // every swap, so applications that do not re-read it type the previous
    // alphabet until any modifier key arrives (decisions §35). Pointing
    // `input:kb_file` at what the helper installed makes the compositor
    // compile the same keymap for every physical keyboard, and the swap has
    // nothing left to swap between.
    readonly property string publishedKeymap: "/omarchy-osk/keymap.xkb"
    property int sharedKeymapGen: 0
    // The `kb_file` the USER configured, remembered across the moment this
    // panel replaces it with the published one. Without it the compositor's
    // own setting is the only record of it, and pointing `kb_file` at the
    // published keymap erases that record: the next refresh reads our path,
    // has nothing to fall back to, and the helper rebuilds from `kb_layout`
    // alone — the user's custom keymap silently dropped for the rest of the
    // session.
    property string userKeymapFile: ""
    function shareKeymapWithCompositor() {
        if (session.ackedGen === 0 || sharedKeymapGen === session.ackedGen) return
        shareProcess.wanted = session.ackedGen
        if (!shareProcess.running) shareProcess.running = true
        // Cleared and set rather than set: assigning the same path again is a
        // no-op, and a republished file under the same name has to be re-read
        // or the compositor keeps compiling the keymap before this one.
        //
        // `hyprctl eval`, not `hyprctl keyword`: the Lua config parser refuses
        // keyword outright ("keyword can't work with non-legacy parsers").
    }

    /// Points the compositor at the published keymap, and only records the
    /// generation as shared when it actually landed.
    ///
    /// The first version marked the generation before running and threw every
    /// error away: a file not yet published, an `hyprctl eval` a compositor
    /// refused, anything at all, and the panel would never try that generation
    /// again and never say so. The seat then carries two keymaps for the rest
    /// of the session, which is the defect §35 exists to end.
    Process {
        id: shareProcess
        property int wanted: 0
        property int attempts: 0
        command: ["bash", "-c",
            "path=\"$XDG_RUNTIME_DIR" + root.publishedKeymap + "\"; "
            + "[[ -s \"$path\" ]] || exit 3; "
            + "hyprctl eval \"hl.config({input = {kb_file = ''}})\" >/dev/null || exit 4; "
            + "hyprctl eval \"hl.config({input = {kb_file = '$path'}})\" >/dev/null || exit 4; "
            // Read back rather than trust: `eval` answers `ok` for a config
            // call the parser accepted, which is not the same as the value
            // being in place.
            + "[[ \"$(hyprctl getoption input:kb_file -j | jq -r .str)\" == \"$path\" ]]"]
        onExited: function (code, status) {
            if (code === 0 && status === 0) {
                root.sharedKeymapGen = wanted
                attempts = 0
                return
            }
            // Exit 3 is "the helper has not written the file yet", which is
            // an ordinary race at startup: the configure is acknowledged
            // before the publish lands. Retrying is the answer, not a line in
            // the journal. Everything else gets retried too and then said out
            // loud, because a seat left with two keymaps is a defect the user
            // will otherwise report as the layout switch being broken.
            attempts += 1
            if (attempts <= 5) {
                shareRetry.restart()
                return
            }
            attempts = 0
            console.error("[osk] could not give the compositor the published"
                + " keymap (exit " + code + ", five attempts): the seat is"
                + " carrying two keymaps and a client's layout group will"
                + " reset on every focus change (decisions §35).")
        }
    }

    Timer {
        id: shareRetry
        interval: 400
        repeat: false
        onTriggered: if (!shareProcess.running) shareProcess.running = true
    }

    // Whatever the compositor had before this panel pointed it at the
    // published keymap. A session that ends with the OSK closed must not be
    // left compiling every physical keyboard from a file no running process
    // owns — §35's claim that a stale `kb_file` cannot outlive the thing that
    // set it is only true if something puts it back.
    Component.onDestruction: {
        if (sharedKeymapGen === 0) return
        Quickshell.execDetached(["bash", "-c",
            "hyprctl eval \"hl.config({input = {kb_file = '$1'}})\" >/dev/null 2>&1",
            "onscreen-keyboard-restore", userKeymapFile])
    }

    function parseHyprLayoutOutput(text) {
        var devices = []
        var kbFile = ""
        var names = ({})

        tabRecords(text).forEach(function (parts) {
            if (parts.length < 2) return
            if (parts[0] === "DEVICES") {
                try { devices = JSON.parse(parts[1]) } catch (error) { devices = [] }
                return
            }
            if (parts[0] === "KBFILE") {
                kbFile = parts[1] === "[[EMPTY]]" ? "" : String(parts[1] || "")
                return
            }
            if (parts[0] === "NAME" && parts.length >= 3) {
                names[String(parts[1] || "").trim()] = String(parts[2] || "").trim()
            }
        })

        // Merge any newly discovered names into the map. Done before the
        // selection can bail out: the names are a property of the machine's
        // xkb rules, not of which keyboard answers today.
        var merged = ({})
        for (var k in layoutNameMap) merged[k] = layoutNameMap[k]
        for (var k in names) merged[k] = names[k]
        layoutNameMap = merged

        var picked = LayoutDevices.select(devices, typedKeyboardName, startupKeyboards)
        // Cleared unconditionally: a refresh that finds no safe target must
        // not leave the language button aiming at a device that has gone
        // missing or was never safe to advance.
        switchKeyboards = picked.switchSet
        // Sticky, and only from the seat's own flag. The flag lands on the
        // helper's virtual keyboard for a moment after every OSK keystroke,
        // so "no answer" has to mean "keep what we knew", not "forget".
        if (picked.typing) typedKeyboardName = picked.typing
        if (!picked.reading) return

        var reading = picked.reading
        var detected = String(reading.layout || "us").split(",")
            .map(function (code) { return String(code || "").trim() })
            .filter(function (code) { return code.length > 0 })
        if (detected.length > 0) {
            languageCycle = detected
        }
        var active = LayoutDevices.activeLayout(reading)
        var configGroup = reading.active_layout_index || 0
        xkbRules = String(reading.rules || "")
        xkbModel = String(reading.model || "")
        xkbLayouts = String(reading.layout || "")
        xkbVariants = String(reading.variant || "")
        xkbOptions = String(reading.options || "")
        // A kb_file that is the helper's own published keymap is not an input
        // to the helper: feeding it back would compile our own output and
        // freeze the layout list, so the compositor's configured RMLVO stays
        // the source and the published file stays the compositor's copy of
        // the result. A kb_file the USER set is a real input and is passed on.
        // Ours or the user's. When the compositor is on the published keymap
        // the helper is fed whatever the user had configured — remembered
        // above — so `kb_layout` edits and a custom keymap both keep working.
        // When it is NOT on the published keymap, something dropped it: a
        // `hyprctl reload` for a theme change resets a runtime `kb_file` to
        // whatever the config file says, and the configure that follows is
        // byte-identical, so the helper's generation never moves and the
        // once-per-generation guard would never fire again. Re-arm instead.
        if (kbFile.indexOf(publishedKeymap) !== -1) {
            xkbFile = userKeymapFile
        } else {
            userKeymapFile = kbFile
            xkbFile = kbFile
            if (sharedKeymapGen !== 0) {
                sharedKeymapGen = 0
                shareKeymapWithCompositor()
            }
        }

        // Always follow the system. The old code adopted the layout once and
        // then froze, so a switch made with Caps Lock or the bar indicator left
        // the caps showing the previous alphabet while the compositor produced
        // the new one — the two looked swapped.
        var selected = active
        if (!selected && detected.length > 0) selected = detected[0]
        if (selected) {
            // The compositor is authoritative for both the group and its
            // human-facing layout code. The old keycap loader used to assign
            // this as a side effect; after that pipeline was removed the
            // header stayed on the initial "us" forever.
            currentLayout = selected
            // The group index is the compositor's own `active_layout_index`,
            // not the position of the active layout code in the list. The
            // two differ exactly when a code repeats — `us,us` with distinct
            // variants is the ordinary case — and `indexOf` there always
            // found the first twin, so the keycap compile below kept
            // answering group 0's variant while typing used the active
            // group. The index is authoritative; the code is a label.
            layoutCycleIndex = configGroup
            var configure = "configure\t" + xkbRules + "\t" + xkbModel
                + "\t" + xkbLayouts + "\t" + xkbVariants + "\t" + xkbOptions
                + "\t" + xkbFile + "\t" + configGroup
            // Only a configure that will CHANGE the keymap closes the typing
            // gate up front. The helper compiles and installs for that one,
            // draining every key it holds on the way in, and a press that
            // straddled it would land in a keymap neither side has agreed on.
            // A group-only configure — every ordinary language switch — does
            // none of that: the same-keymap short-circuit moves the group, the
            // socket is ordered so the move lands ahead of anything written
            // after it, and the facts for the destination group are already in
            // hand. Dropping readiness for it dimmed the whole keyboard and
            // raised the service-starting notice for the length of the round
            // trip, which is the flicker the user sees on every switch.
            if (Session.identityOf(configure) !== Session.installed(session)) {
                inputReady = false
                inputStatus = "configuring"
            }
            sendConfigure(configure)
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
        // The shell only fetches. Which device answers for the layout, and
        // which ones the language button moves, is decided in
        // LayoutDevices.js — where it can be tested. It used to be a jq
        // program inside this string, and it broke three times without a
        // single suite noticing (tests/layout-devices.qml carries the zoo).
        //
        // Layout names are looked up for every code any keyboard carries,
        // not just the chosen device's, so the selection can happen after
        // this process has already exited.
        layoutDetectProcess.command = ["bash", "-c",
            "devices=$(hyprctl devices -j 2>/dev/null); "
            + "[[ -n \"$devices\" ]] || exit 1; "
            + "compact=$(printf '%s' \"$devices\" | jq -c "
            + "'[.keyboards[] | {name, main, active_layout_index, layout, rules, model, variant, options}]' 2>/dev/null); "
            + "[[ -n \"$compact\" ]] || exit 1; "
            + "printf 'DEVICES\\t%s\\n' \"$compact\"; "
            + "kb_file=$(hyprctl getoption input:kb_file -j 2>/dev/null | jq -r '.str // \"\"'); "
            + "printf 'KBFILE\\t%s\\n' \"${kb_file:-[[EMPTY]]}\"; "
            + "printf '%s' \"$compact\" | jq -r '[.[].layout // \"\"] | join(\",\")' "
            + "| tr ',' '\\n' | sed '/^$/d' | sort -u | while read code; do "
            + "  name=$(awk -v c=\"$code\" 'BEGIN{s=0} /^! layout/{s=1;next} /^!/{if(s) exit} s && NF>=2 && $1==c { $1=\"\"; sub(/^ +/,\"\",$0); print $0; exit }' /usr/share/X11/xkb/rules/base.lst 2>/dev/null); "
            + "  [[ -n \"$name\" ]] && printf 'NAME\\t%s\\t%s\\n' \"$code\" \"$name\"; "
            + "done", "onscreen-keyboard"]
        layoutDetectProcess.running = true
    }

    function cycleLanguage() {
        if (languageCycle.length < 2 || switchKeyboards.length === 0) return
        var next = (layoutCycleIndex + 1) % languageCycle.length
        // Hyprland stores the group per device. Move every device with this
        // layout list to one absolute index; switching one guessed physical
        // keyboard changed the panel while another keyboard kept typing the
        // previous group. One shell process keeps the operations ordered.
        var command = ["bash", "-c",
            "next=$1; shift; for keyboard in \"$@\"; do "
                + "hyprctl switchxkblayout \"$keyboard\" \"$next\" >/dev/null 2>&1 || true; "
                + "done",
            "onscreen-keyboard-switch", String(next)]
        for (var i = 0; i < switchKeyboards.length; i++)
            command.push(String(switchKeyboards[i]))
        Quickshell.execDetached(command)
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
            // Deliberately NOT where the typing keyboard is learned. Every
            // `switchxkblayout` this panel issues emits `activelayout` naming
            // the device it moved, so adopting the event's device made the
            // anchor point at whatever the panel itself touched last. The
            // panel then read its own echo, rearranged the seat around it,
            // and could drag the user's keyboard back out of the group they
            // had just switched it into. The seat's own `main` flag is the
            // evidence; see the refresh.
            //
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
    /// The readiness gate lives at the EVENT level, never at the line level.
    /// Press-type events are refused while the helper is not ready, rather
    /// than advancing state over writes that go nowhere: a lock whose `down`
    /// was dropped would leave the cap showing a modifier the compositor
    /// never received. Caps and Fn are exceptions because they are local
    /// semantic controls and emit no protocol line; reconnecting must not
    /// delay them. Release and releaseAll events stay live for the same
    /// reason a cap's release is never gated: a key down at the device must
    /// be lifted no matter what state the panel thinks it is in, or the
    /// compositor repeats it forever.
    ///
    /// Every line the reducer emits for an ALLOWED event is then written
    /// whenever the socket exists — including the restorative `down` that
    /// puts a locked Shift back after a release lifted it around the chord.
    /// That line is press-shaped text and still rides an allowed event;
    /// classifying lines by prefix would drop it and desynchronise the lock.
    /// The invariant: the reducer decides what changes, and the transport
    /// never second-guesses a line it is handed — with the one exception the
    /// reducer is TOLD about here: a release in front of an outstanding
    /// changed configure cannot trust its restore plan. The helper processes
    /// that configure (and its drain) before these lines, so a restorative
    /// `down` would re-press a modifier after the device world lost it —
    /// locked Shift held at the device while the panel, settling the drain
    /// reply a moment later, draws idle. The chord's `up` lines still go out
    /// (a release is never dropped, and an `up` for a drained key is
    /// forwarded and dropped by the compositor); only the re-press is
    /// withheld. The reducer state itself does NOT settle here: the reply
    /// owns the settle, because the outstanding configure can still turn
    /// out to be refused — a release that erases the lock speculatively
    /// would leave the refusal nothing to lift while the helper, having
    /// never drained, re-asserts the modifier. When the socket is gone
    /// there is nothing to write and nothing is owed — the helper's
    /// disconnect release has already lifted every claim the connection
    /// held.
    function applyModifierEvent(event) {
        var alwaysLive = event && (event.type === "capsClick"
            || event.type === "fnClick"
            || event.type === "release"
            || event.type === "releaseAll")
        if (!inputReady && !alwaysLive) return
        var dropRestore = event.type === "release" && Session.hasDrainAhead(session)
        // No speculative settle here, deliberately: a release that runs
        // before the outstanding configure's reply must leave the reducer
        // state as the release made it, because the reply decides what the
        // device world became. A `configured` settles the drain (the
        // changed configure really lifted the holds); a refusal lands in
        // the err branch, which reads the still-live locked modifiers and
        // lifts them for real. Settling speculatively here would erase the
        // lock before the refusal could name it, and the helper's held set
        // would re-assert the modifier after `mods 0`.
        var outcome = Modifiers.reduce(modifierState, dropRestore
            ? { type: "release", dropRestore: true } : event)
        modifierState = outcome.state
        for (var i = 0; i < outcome.lines.length; i++) {
            sendCommandUnchecked(outcome.lines[i])
        }
    }

    /// Current-content paste (spec-v1.1 §1): an exact chord through the
    /// reducer, never a held cap and never mixed with latched Ctrl/Alt/Super.
    /// `wmClass` selects the CLIPBOARD chord (terminals: Ctrl+Shift+V; else
    /// Shift+Insert). Empty class uses the terminal chord so PRIMARY is not
    /// sent into a terminal the lookup failed to name.
    function pasteCurrent(wmClass) {
        var chord = Modifiers.pasteChordForClass(wmClass)
        applyModifierEvent({
            type: "paste",
            ctrl: chord.ctrl === true,
            shift: chord.shift === true,
            position: chord.position
        })
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

    function isSymbolShiftActive() {
        return shiftActive()
    }

    // A letter key is one whose shifted symbol is simply the capital of its
    // base. The rule lives in KeyboardLayout.js beside the keycap pipeline it
    // serves (and is tested at the pure seam with it); the wrapper keeps this
    // file's call sites — the reducer's `letter` fact and the dual-cap test —
    // reading exactly as they always have.
    function isLetterKey(keyData) {
        return Layout.isLetterKey(keyData)
    }

    // What this cap says it types, under the reducer's current Caps and Shift.
    // The rule is Layout.resolvedTypedChar's: an exact cap (the curated page's)
    // answers only to the level it carries — never redrawing as another symbol
    // because Shift is active, which is the agreement between what a cap shows
    // and what its exact press types (review finding R3) — letters swap on
    // Caps XOR Shift, and other paired caps shift with Shift alone.
    function resolvedTypedChar(keyData) {
        return Layout.resolvedTypedChar(keyData, modifierState.caps,
            Modifiers.isActive(modifierState, "shift"))
    }

    // Punctuation/number keys show both symbols stacked (like the
    // reference's `.key.dual`); plain letter keys just swap case. The
    // symbols page's dual caps (2026-09-05, symbols v2) carry the explicit
    // `dual` flag and are dual here even when their shifted level resolved
    // to nothing — a valid base-only cap still renders the stacked pair
    // with an empty shifted slot, never a centered impostor. Main-page caps
    // without the flag stay dual the old way: both levels resolved, and not
    // a letter.
    function isDualKey(keyData) {
        return keyData.dual === true
            || (!!keyData.s && !isLetterKey(keyData))
    }

    // Input goes to the helper over a unix socket; the panel never
    // takes keyboard focus (`keyboardFocus: None` in Panel.qml), so the
    // window being typed into keeps it and the helper's keystrokes land
    // there. Nothing here spawns a process: the plugin runs inside the
    // long-lived shell, and the Omarchy guide asks plugins not to launch
    // shell processes. The first version spawned `wtype` per keystroke, and
    // could never have worked well even had it been allowed — a fresh
    // `wtype` per key uploads a synthetic keymap that XWayland ignores, so
    // keys never reached Proton games or Electron apps, and each spawn cost
    // tens of milliseconds.
    property bool inputReady: false
    property string inputStatus: "connecting"
    // Panel-status facts over the socket client's own states (spec-v1.1 §6),
    // read by the panel's hint line. `serviceConnected` mirrors the live
    // socket: false before the first dial, while the loader rebuilds it, and
    // after a drop — the "not running" state, whatever the reason.
    // `serviceIncompatible` is a hello answered in another protocol version
    // (or the helper's err naming the version it needs): a fact about the
    // installed helper, so it stays until a good handshake replaces it —
    // clearing it on disconnect would flicker the state on every rebuild
    // tick and would claim an outdated install fixed because the service
    // stopped.
    readonly property bool serviceConnected: daemonSocket ? daemonSocket.connected : false
    property bool serviceIncompatible: false
    // spec-v1.1 §6 + decisions §23: the header's helper/keymap kind. A
    // connected caps mismatch is unavailable, never the starting notice.
    readonly property string lifecycleKind: Session.lifecycleKind({
        inputReady: inputReady,
        serviceConnected: serviceConnected,
        serviceIncompatible: serviceIncompatible,
        capsFactsFailed: capsFactsFailed
    })
    // Set when the socket reaches `connected`, consumed by the hello reply:
    // only a genuinely new connection may reset device-held modifier state,
    // never the repair timer's re-hello of a live one. See the hello handler.
    property bool socketReconnected: false
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
    // the helper has not answered hello yet. A helper that dies later needs
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
                    // helper accepts commands before the compositor keymap has
                    // been forwarded to its virtual keyboard, and would drop
                    // every key. hello therefore goes out on a short delay
                    // after the flip — inline writes were observed landing on
                    // a closed device during the VM dogfooding. The flip is
                    // also what the hello reply's reset keys off: only a
                    // genuinely new connection released the old one's holds.
                    root.socketReconnected = true
                    helloTimer.restart()
                } else {
                    root.inputReady = false
                    root.inputStatus = "reconnecting"
                    // The handshake no longer holds on this dead socket; the
                    // queue and facts stay until a new connection's fresh
                    // hello restarts them (a live helper may still answer for
                    // the transaction a reconnect is racing).
                    root.session = Session.reduce(root.session, { type: "connectionDown" })
                    // A restarted helper counts its installs from one again,
                    // so the generation this panel last shared can come round
                    // a second time and the once-per-generation guard would
                    // skip a keymap the compositor has never seen. The path
                    // does not change, so nothing would make it re-read the
                    // file either: two keymaps on the seat, silently.
                    root.sharedKeymapGen = 0
                }
            }

            parser: SplitParser {
                onRead: function (line) {
                    var reply = String(line).trim()
                    if (reply === "hello " + Session.PROTOCOL_VERSION) {
                        root.serviceIncompatible = false
                        root.inputReady = false
                        root.inputStatus = "configuring"
                        // On a genuinely NEW connection the helper released
                        // everything the old one held when that socket
                        // closed, so a locked modifier did not survive the
                        // reconnect however the indicator looked. Reset to
                        // match, and do it without emitting the releases —
                        // sending `up` for a code nobody holds is a lie in
                        // the other direction.
                        // Caps is a semantic panel control, not a held key on
                        // this connection, so a helper restart does not turn
                        // it off. Only the real device-held modifiers reset.
                        //
                        // The gate matters: the repair timer re-hellos an
                        // open-but-unready socket (a configure refused, a
                        // helper still starting) WITHOUT the connection ever
                        // dropping. That helper still holds whatever the
                        // panel asked it to hold, so neither the state reset
                        // nor the `mods 0` may fire here — resetting the
                        // reducer over a live hold would leave the device
                        // Shift down under an idle panel.
                        if (root.socketReconnected) {
                            root.socketReconnected = false
                            root.capsFactsFailed = false
                            root.modifierState = Modifiers.reduce(
                                root.modifierState, { type: "releaseAll" }).state
                            // Session bookkeeping starts over with the
                            // connection: the next configure's identity must
                            // be compared against what THIS helper instance
                            // has acknowledged, and no reply can still arrive
                            // for a transaction a predecessor was holding.
                            root.session = Session.reduce(root.session,
                                { type: "helloAcked", fresh: true })
                            daemon.write("mods 0\n")
                        } else {
                            // The repair timer's re-hello of a live socket:
                            // the handshake holds, nothing resets.
                            root.session = Session.reduce(root.session,
                                { type: "helloAcked", fresh: false })
                        }
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
                    } else if (reply.indexOf("configured") === 0) {
                        // Mirror the helper's own configure behaviour, for
                        // THE ENTRY THIS REPLY SETTLES — the oldest
                        // outstanding transaction, not the newest sent
                        // (FIFO; see the queue above). A configure that
                        // changed the keymap drained every key it held for
                        // us on its way in (install_config lifts each held
                        // code and zeroes the modifiers); one that kept the
                        // keymap — a group move, a byte-identical refresh —
                        // deliberately kept them. The panel follows both,
                        // the way the hello path already resets over a
                        // connection the helper released: on a keymap
                        // change, drop the device-held modifier state
                        // WITHOUT emitting — an `up` for a code the device
                        // no longer holds would be a lie in the other
                        // direction — while Caps and Fn stay, being
                        // semantic panel controls and never held at the
                        // device. On a same-keymap configure the lock
                        // stays held at the device and drawn locked, and
                        // typing agrees (the gate in applyModifierEvent
                        // writes whatever the reducer emits, restorative
                        // downs included — except across a drain, where
                        // the reducer itself withholds the restore).
                        // The reply names the keymap generation it installed
                        // (protocol 4, decisions §23). A reply without one is
                        // not a helper this panel can reason about: the shapes
                        // moved together with the version, so this is an
                        // installation mismatch, not a recoverable error.
                        var gen = parseInt(reply.split("\t")[1])
                        if (!isFinite(gen) || gen <= 0) {
                            root.serviceIncompatible = true
                            root.inputReady = false
                            root.inputStatus = "configured without a keymap generation"
                        } else {
                            root.settleConfigureReply(gen)
                            // Readiness waits for the WHOLE queue: an older
                            // reply does not make typing safe while a pipelined
                            // configure is still compiling the keymap a press
                            // would land in — a chord allowed through now would
                            // straddle that drain and lose its release. It also
                            // waits for keycap facts that answer the generation
                            // this reply just installed (decisions §23): request
                            // them the moment the queue is settled and anything
                            // current has been invalidated.
                            if (Session.settled(root.session)) {
                                // Every group of this install, not just the
                                // one being drawn. The helper resolved them
                                // all when it installed the keymap, so asking
                                // for the rest now costs one extra reply each
                                // and makes the next language switch a lookup
                                // instead of a round trip through an
                                // invalidated, gated, dimmed keyboard.
                                var missing = Session.missingCapGroups(
                                    root.session, root.groupCount)
                                if (missing.length > 0)
                                    console.log("[osk] caps requested for group(s)",
                                        missing.join(","), "of", root.groupCount)
                                for (var mg = 0; mg < missing.length; mg++)
                                    sendCommandUnchecked(capsRequestLine(missing[mg]))
                            }
                            root.inputReady = Session.typingReady(root.session)
                            root.inputStatus = root.inputReady ? "ready" : "configuring"
                        }
                    } else if (reply.indexOf("caps\t") === 0) {
                        // The helper's keycap facts for the world it has
                        // installed (decisions §23). The session refuses any
                        // reply whose generation or group no longer matches
                        // the acknowledged one — a superseded answer computed
                        // from a keymap the helper no longer has can never
                        // enable caps, and while nothing current exists the
                        // typing gate stays shut.
                        var parsed = Session.parseCapsReply(reply)
                        if (!parsed) {
                            // A reply the parser refuses is protocol drift,
                            // not an empty keymap: refuse the world rather
                            // than draw a guessed level.
                            console.error("[osk] unreadable keycap facts reply")
                            root.capsFactsFailed = true
                            root.inputReady = false
                            root.inputStatus = "unreadable keycap facts"
                        } else {
                            var applied = Session.applyCapsReply(root.session, parsed)
                            root.session = applied.state
                            if (applied.accepted) {
                                root.capsFactsFailed = false
                                root.shareKeymapWithCompositor()
                                if (Session.typingReady(root.session)) {
                                    root.inputReady = true
                                    root.inputStatus = "ready"
                                }
                            }
                        }
                    } else if (reply.indexOf("err") === 0) {
                        if (reply.indexOf("err protocol") === 0) {
                            // The helper answered hello with the version it
                            // speaks, and it is not ours: the installed
                            // binary predates (or postdates) this panel.
                            // That is the incompatible state — the panel
                            // never installs anything on its own (spec-v1.1
                            // §6); the offer is the copied install command.
                            root.serviceIncompatible = true
                            root.inputReady = false
                            root.inputStatus = reply
                        } else if (reply === "err not ready") {
                            // A helper fresh out of systemd start answers err
                            // until its default keymap is installed; it cannot
                            // become ready without a configure, and nothing
                            // else sends one — so ask the compositor now
                            // instead of waiting out the repair timer.
                            root.refreshLayoutsFromHypr()
                        } else if (reply === "err key held" || reply === "err not holding") {
                            // Ownership refusals mean the helper's hold state
                            // is ahead of ours; the device is fine and typing
                            // stays enabled. The panel's chords never produce
                            // them, so one appearing is a client bug worth
                            // surfacing in the status without bricking the
                            // keyboard.
                            root.inputStatus = reply
                        } else if (reply === "err bad group") {
                            // Only a caps request can earn this: the helper
                            // refused to answer facts for a group its keymap
                            // does not carry. For the group being DRAWN that
                            // is keymap-wide disagreement about the world, and
                            // the hint says so instead of letting the built-in
                            // table pass for it. For one of the other groups
                            // the panel pre-fetches it is not: the drawn group
                            // still has current facts, typing is still
                            // answering the installed keymap, and the only
                            // consequence is that switching INTO that group
                            // will go the slow way. Refusing the whole world
                            // over it would gate a keyboard that is working.
                            root.capsFactsFailed = !Session.capsCurrent(root.session)
                            if (root.capsFactsFailed) {
                                root.inputReady = false
                                root.inputStatus = reply
                            } else {
                                console.error("[osk] helper has no facts for a"
                                    + " pre-fetched group; that group will"
                                    + " resolve on switch")
                            }
                        } else if (reply === "err cannot configure keymap") {
                            // A FAILED configure is authoritative about the
                            // device world in a way the error text cannot
                            // qualify: a compile or rate-limit refusal
                            // happens BEFORE install_config drains anything
                            // (the helper still holds whatever the panel
                            // had down), while an upload failure happens
                            // AFTER the drain (the helper holds nothing) —
                            // and both answer with this same err. The panel
                            // therefore settles to the drained world
                            // UNCONDITIONALLY, exactly as a changed-keymap
                            // success does, and then makes the device
                            // agree: an explicit `up` for every modifier
                            // the panel had locked — a real lift when the
                            // helper never drained, a forwarded no-op when
                            // it already did — plus `mods 0`, so the
                            // compositor's mask cannot keep the stale
                            // modifier alive (the helper re-asserts its
                            // mask from its held set on the next key event,
                            // so `mods 0` alone would not survive). Panel
                            // and device agree either way, and a later
                            // close emits nothing because nothing is held.
                            // A pending chord survives untouched: its own
                            // key hold is real in the never-drained case,
                            // and in the drained case its mouse-up is a
                            // forwarded no-op. This also covers the
                            // release-before-refusal ordering: a release
                            // that ran while this configure was outstanding
                            // left the lock standing here on purpose (the
                            // reply owns the settle), so the capture above
                            // still sees the modifiers it must lift.
                            root.session = Session.reduce(root.session,
                                { type: "configureFailed" })
                            var lockedPositions = []
                            for (var m = 0; m < Modifiers.ORDER.length; m++) {
                                if (modifierState[Modifiers.ORDER[m]] === "locked")
                                    lockedPositions.push(
                                        Modifiers.positionFor(Modifiers.ORDER[m]))
                            }
                            modifierState = Modifiers.reduce(modifierState,
                                // stamp -1: a failed configure drained
                                // nothing a pending chord depends on for
                                // certain, so every pending record survives
                                // (minus its restore plan, which would
                                // re-press a lock the panel just dropped).
                                { type: "configureDrain", stamp: -1 }).state
                            for (var u = 0; u < lockedPositions.length; u++)
                                sendCommandUnchecked("up " + lockedPositions[u])
                            sendCommandUnchecked("mods 0")
                            root.inputReady = false
                            root.inputStatus = reply
                        } else {
                            root.inputReady = false
                            root.inputStatus = reply
                        }
                    } else if (reply.indexOf("hello ") === 0) {
                        // A hello naming another version than the one this
                        // panel asked for is the same incompatibility in a
                        // different shape. Defensive: the current helper
                        // errs instead of greeting across versions.
                        root.serviceIncompatible = true
                        root.inputReady = false
                        root.inputStatus = reply
                    }
                }
            }

            // A quickshell 0.3.1 peer close can log "Socket error for …"
            // without ever flipping `connected` (observed live: the property
            // still read true minutes after QLocalSocket::PeerClosedError),
            // which leaves inputReady stuck at true — a ready-looking
            // keyboard that cannot type, the exact silent failure §6
            // forbids. An error arriving on a socket that still reads
            // connected is therefore treated as the drop the state change
            // failed to report: enter the disconnected state and rebuild
            // the socket object, the same reset socketPathCheck uses, so
            // the gated repair timer owns the redial and the next good
            // handshake clears the notice. A failed dial reports with
            // connected false and no-ops here, so this cannot loop.
            onError: {
                if (!connected) return
                root.inputReady = false
                root.inputStatus = "reconnecting"
                Qt.callLater(function () {
                    daemonLoader.active = false
                    daemonLoader.active = true
                })
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
                // The version the session negotiates, never a literal: the
                // reply matcher above compares against the same constant, and
                // a stale literal here reads as an installation mismatch
                // against a helper this panel is actually compatible with.
                root.daemonSocket.write("hello " + Session.PROTOCOL_VERSION + "\n")
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

    // The emoji cap's PATH probe (spec-v1.1 §1). The configured app by bare
    // PATH name, never an absolute path. execDetached is the panel's: Emote
    // is a managed session (ticket 09) and a second exec would recreate the
    // picker rather than dismiss it. The probe still answers "not on PATH"
    // before anything is launched.
    Process {
        id: emojiProbe
        command: ["sh", "-c", "command -v \"$1\" >/dev/null", "osk-emoji-probe",
            root.emojiAppName]
        onExited: function(exitCode, exitStatus) {
            emojiFailTimer.stop()
            if (exitCode === 0) {
                root.emojiFailed = false
                root.emojiCapActivated(root.emojiAppName)
                return
            }
            root.emojiFailed = true
            emojiFailTimer.restart()
        }
    }

    Timer {
        id: emojiFailTimer
        // A few seconds of "<app> not found on PATH", then the hint line
        // returns to its mode text without another event being needed.
        interval: 4000
        repeat: false
        onTriggered: root.emojiFailed = false
    }

    Timer {
        id: reconnectTimer
        interval: 2000
        repeat: true
        // Also while a configure is outstanding. Readiness alone stopped being
        // enough once a group-only configure no longer lowers `inputReady`
        // (ticket 16): a socket that stays `connected` but never answers
        // `configured` would leave the panel ready-looking, drawing the acked
        // group while the helper types the queued one, with no tick to notice.
        // A configure is answered in well under this interval — the helper
        // replies before it compiles anything — so an entry still outstanding
        // when this fires is a lost reply, not a slow one.
        running: !root.inputReady || !Session.settled(root.session)
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

    /// The one writer for reducer output and panel-originated protocol lines
    /// (configure, keyboards). The readiness gate is `applyModifierEvent`'s
    /// event-level decision, not a property of the text: whatever reaches
    /// here is written while the socket exists, and only the missing socket
    /// (nothing owed — the helper released on disconnect) or the absent
    /// loader object makes the write a no-op.
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
        // The ten symbol/digit caps use Shift to pick the digit chord. The
        // latch already selected the layer, so the reducer receives an exact
        // chord and temporarily lifts Shift to type the digit's level 1.
        // `sk` alone: a cap either carries a resolved Shift half or it does
        // not. The old `|| keyData.shiftToken` arm outlived the token caps
        // that used it, and its guard below could only ever have swallowed a
        // press in silence.
        var wantShiftLayer = !!keyData.s && shiftActive() && !!keyData.sk
        var position = wantShiftLayer ? keyData.sk : keyData.k
        if (!position) return
        var level = wantShiftLayer
            ? (keyData.slvl || 1)
            : (keyData.baseLvl !== undefined ? keyData.baseLvl : 1)
        root.keyPressed()
        applyModifierEvent({
            type: "press",
            position: position,
            letter: isLetterKey(keyData),
            // A level cap draws one level and has to type that level. Same
            // treatment as Caps Lock: real modifier presses around the key,
            // never a character the panel picked for itself — Shift for
            // level 2, AltGr (with Shift) for the curated page's levels 3
            // and 4 (spec-v1.1 §3). The reducer decides how those presses
            // wrap around the key and what a lock does to them. Curated
            // caps are `exact`: a latched Shift or AltGr is never APPLIED
            // by one — the chord is the level's, not the latch's — but it
            // is always CONSUMED by one, as §2 spends any non-modifier
            // key's latches. Pair caps wrap AltGr intrinsically and apply
            // a latched or locked Shift; they are not exact. The symbol/digit
            // caps on &123 are exact too: the latch already chose the layer.
            shift: Layout.levelChord(level).shift,
            altgr: Layout.levelChord(level).level3,
            // Levels five to eight are the reserved block's own (decisions
            // §33): <LVL5> opens them and Shift and <LVL3> choose among the
            // four, so a glyph resolved up there presses one more real
            // modifier than one resolved below and nothing else changes.
            level5: Layout.levelChord(level).level5,
            // Which key carries AltGr for THIS chord. A glyph cap resolved at
            // level 3 or 4 (ticket 18) needs ISO_Level3_Shift, and RALT is
            // only that on some layouts — `us` makes it Alt_R, which is the
            // layout dependence the reserved block exists to remove. <LVL3>
            // is ISO_Level3_Shift in every group of every compiled keymap.
            // A dual glyph cap resolves its two halves independently, so the
            // half being typed is what decides — the base can sit at level 1
            // of one position while the Shift glyph sits at level 3 of
            // another.
            level3Position: (wantShiftLayer ? keyData.shiftLevel3 : keyData.level3) === true
                ? "LVL3" : "",
            exact: keyData.exact === true || keyData.baseLvl !== undefined,
            // Where this chord sits in the configure-send sequence. A
            // configure queued after it drains at the helper ahead of the
            // chord's release, and the stamp is how the reply and the
            // release each tell that apart — see the queue above.
            configureStamp: session.sends
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
        // The ☺ cap (spec-v1.1 §1) probes PATH for the configured picker.
        // The panel decides launch vs dismiss. A second click while the
        // probe is already running needs no queue: the pending probe's
        // exit resolves for both.
        case "emoji":
            if (!emojiProbe.running) emojiProbe.running = true
            return
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
        applyModifierEvent({
            type: "press", position: position,
            configureStamp: session.sends
        })
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
                            // A declared spacer slot (`spacer: true` — the
                            // curated page's unfilled slots and its free
                            // row's pad) draws nothing: the page never shows
                            // a blank cap. An invisible item takes no mouse
                            // events either, so a dead slot stays dead while
                            // its neighbours' hit areas keep meeting at its
                            // midpoints.
                            visible: !keyData.spacer
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
                            // Whether the cap produces input at all: typing,
                            // or a modifier latch (its click sends real down/
                            // up lines). Caps and Fn are semantic panel
                            // controls, page, emoji and Close are commands
                            // — none of them reach the protocol, so all stay
                            // live while the helper is not ready (spec-v1.1
                            // §6).
                            //
                            // `inputGated` is the one named arm for that gate,
                            // used identically at press and release: a gated
                            // cap draws and answers disabled, in the language
                            // switch's idle shades, and its press path never
                            // starts — so it emits no keyPressed and no click
                            // sound plays for a key that goes nowhere. The
                            // deep defence stays in applyModifierEvent, which
                            // still refuses protocol-bearing events.
                            //
                            // `unavailable` is the other arm of the same
                            // treatment (spec-v1.1 §3): a level cap whose
                            // position resolved to nothing in the active
                            // keymap — a valid partial keymap's hole — must
                            // never sit there blank and clickable. It draws
                            // dim like a gated cap, refuses the press, and
                            // emits nothing; the §11 miss report is the
                            // record of why. Fixed-label caps and spacers
                            // are never marked unavailable: their labels are
                            // the panel's own.
                            property bool producesInput: types
                                || Modifiers.isModifier(keyData.key)
                            property bool unavailable: keyData.unavailable === true
                            property bool inputGated: !root.inputReady
                                && producesInput
                            property bool disabled: unavailable || inputGated
                            property bool isSuper: keyData.key === "logo"

                            color: disabled ? root.keyBg
                                : (locked || toggleOn) ? root.lockedFill
                                : latched ? root.latchedFill
                                : mouseArea.pressed ? root.keyActiveBg
                                : mouseArea.containsMouse ? root.keyHoverBg
                                : root.keyBg
                            border.color: (latched || locked || toggleOn) ? root.theme.accent
                                : root.keyBorderColor
                            border.width: latched ? root.latchedBorderWidth : root.keyBorderWidth

                            Text {
                                id: superLogo
                                // Same request as the bar launcher, but only
                                // after the packaged TTF is present so Qt
                                // cannot substitute another family's U+E900.
                                visible: !keyRect.isDual && keyRect.isSuper
                                    && root.omarchyFontPresent
                                anchors.centerIn: parent
                                text: root.omarchyFontPresent ? "\ue900" : ""
                                textFormat: Text.PlainText
                                renderType: Text.NativeRendering
                                color: keyRect.disabled ? root.textDim
                                    : (keyRect.locked || keyRect.toggleOn)
                                    ? root.lockedText : root.textMain
                                font.family: "omarchy"
                                font.pixelSize: root.superLogoSize
                                Accessible.name: "Super"
                            }

                            Text {
                                visible: !keyRect.isDual
                                    && (!keyRect.isSuper || !root.omarchyFontPresent)
                                anchors.centerIn: parent
                                text: keyData.label
                                    ? keyData.label
                                    : root.resolvedTypedChar(keyData)
                                color: keyRect.disabled ? root.textDim
                                    : (keyRect.locked || keyRect.toggleOn)
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
                                // The `|| ""` guards the symbols-page dual
                                // caps, whose levels come from the keymap:
                                // a level that did not resolve is a §11 miss
                                // and an empty slot, never the string
                                // "undefined" drawn on a cap.
                                text: keyData.s || ""
                                anchors.top: parent.top
                                anchors.topMargin: root.gapPx
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: keyRect.disabled ? root.textDim
                                    : root.isSymbolShiftActive() ? root.textHighlightColor : root.textDim
                                font.bold: root.isSymbolShiftActive()
                                font.family: root.keyboardFont
                                font.pixelSize: root.keySmallFontSize
                            }

                            Text {
                                visible: keyRect.isDual
                                text: keyData.t || ""
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: root.gapPx
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: keyRect.disabled ? root.textDim
                                    : root.isSymbolShiftActive() ? root.textDim : root.textMain
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
                                    // Not-ready gating (spec-v1.1 §6) and the
                                    // unavailable mark (§3) are properties of
                                    // the cap, so the whole press path —
                                    // including the click sound and the
                                    // pressed fill — never starts for a cap
                                    // that could not type.
                                    if (keyRect.disabled) return
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
                                // The release of a held key is never gated: a
                                // cap pressed before a state change must lift
                                // even if the panel went not-ready mid-press,
                                // or the compositor repeats it forever.
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
                                    // A locked upgrade is protocol-bearing
                                    // like any latch — refused while gated.
                                    if (keyRect.inputGated) return
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
