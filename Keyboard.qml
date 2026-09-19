import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "KeyboardLayout.js" as Layout
import "ModifierReducer.js" as Modifiers
import "HoldColumn.js" as HoldColumn
import "Dwell.js" as Dwell
import "InputProfile.js" as InputProfile
import "KeyboardSession.js" as Session
import "Config.js" as ConfigFile
import "LayoutDevices.js" as LayoutDevices
import "SettleGuard.js" as SettleGuard
import "SocketWatch.js" as SocketWatch
import "ClipboardPaste.js" as ClipboardPaste
import "ChordAcks.js" as ChordAcks
import "LanguageControl.js" as LanguageControl

Item {
    id: root
    implicitWidth: grid.implicitWidth + 0
    // Pinned to the taller of the two pages rather than to whichever is on
    // screen. Docked mode reserves this height (§7), so letting it follow the
    // current page would shove every window on the output up and down each time
    // &123 is pressed. The grid is anchored to the bottom, so the command row —
    // modifiers, space, arrows, and the page key itself — stays under the
    // pointer across a switch and the slack appears at the top.
    readonly property int maxPageRows: Math.max(Layout.rows.length,
        Layout.symbolRows("").length)
    implicitHeight: maxPageRows * capRowHeight + (maxPageRows - 1) * cellGap
    signal dismissalAsked()
    // Emitted for every keystroke-shaped press — letters, arrows, modifier
    // clicks, Caps Lock — and never for the panel's own UI actions. The panel
    // plays the key click sound on it (spec-v1 §10).
    signal keyPressed()
    // The ☺ cap was pressed. The panel answers by toggling its own emoji
    // page — the only picker there is; the external-picker machinery this
    // signal once armed is gone (ticket 24 step 5, decisions §24).
    signal emojiCapActivated()

    // While the emoji page stands (searchMode, wired from the panel's
    // emojiOpen), the keys feed its search instead of typing to the focused
    // client: one intercepted press arrives here as an action — "char" with
    // the character the cap drew (Layout.charUnderModifiers, so what you see
    // is what the search gets, in every configured layout and group),
    // "backspace", "space", or "escape" from the Esc cap. The panel applies
    // it to the page's query; Escape closes the page. The helper receives
    // nothing for an intercepted press (ticket 24, step 3).
    signal searchInput(string action, string text)
    // The panel's emoji-page state, mirrored. Binding, not assignment: the
    // page closing by any route — cap, Escape, leftover click, gear, the
    // panel itself — ends the interception with it.
    property bool searchMode: false
    onSearchModeChanged: {
        // The search arm of typeCap is immediate by contract (ticket 37):
        // a hold that began before the page opened must not grow a menu
        // over it, and its release can only lift what its press sent —
        // which for a deferred hold is nothing. A dwell dies with it:
        // the emoji page is excluded chrome (Dwell.eligible), so a rest
        // standing when the page opened never fires into the query.
        if (searchMode) {
            clearCapHold()
            closeHoldMenu()
            dwellReset()
        }
    }
    property var pendingTextReplies: []

    // ---- the hold column (ticket 37) ----
    //
    // A character cap whose keymap position carries extra levels (3-4)
    // defers its typing from mouse-press to mouse-release. The press
    // starts a hold timer and sends NOTHING — no stray character, and no
    // compositor repeat can start, because repeat belongs to a key that
    // went down (spec-v1 §6) and a deferred cap never sends a press line
    // before the threshold. A release before the threshold sends the
    // usual press+release pair (one character, today's chord rules,
    // current latches); the threshold firing opens the column menu, and
    // the release after it is spent — nothing was ever down. Caps
    // without a column never enter this state at all. The pure decisions
    // (which levels a position offers, which caps defer) live in
    // HoldColumn.js with their tests; this is the state and the chrome.
    //
    // `holdCap`/`holdDelegate` stand while the hold is pending (timer
    // running); the menu carries its own baked copies, because the grid
    // the delegate lives in can rebuild under a standing menu and the
    // menu's pick must still name the position that was held.
    property var holdCap: null
    property Item holdDelegate: null
    property bool holdMenuOpen: false
    property var holdMenuCap: null
    property Item holdMenuDelegate: null
    property var holdMenuEntries: []
    // The held cap's geometry in root coordinates, mapped once at open:
    // the menu positions itself from these, not from a delegate that a
    // row rebuild may have destroyed.
    property real holdMenuCapX: 0
    property real holdMenuCapTop: 0
    property real holdMenuCapBottom: 0

    // ---- dwell-to-type (ticket 50) ----
    //
    // Hover a cap for the configured delay and it types — press+release
    // as one click, exactly the pair a physical press and release of that
    // cap send — and resting PAST the type on a cap whose position
    // carries a hold column opens ticket 37's menu: the menu deadline is
    // the delay plus 37's own hold window, one vocabulary. The pure
    // machine (thresholds, cancellation, which caps dwell at all — the
    // chrome exclusions) is Dwell.js with tests/dwell.qml; this is the
    // state and the chrome: hover events in, one deadline timer, the
    // returned action mapped onto the press paths that already exist.
    //
    // Off by default; the panel resolves the setting pair over the
    // maintained defaults and hands both down. A rest in progress dies
    // when either changes — the next hover re-arms with the new value.
    property bool dwellEnabled: false
    property int dwellDelayMs: 800
    onDwellEnabledChanged: if (!dwellEnabled) dwellReset()
    onDwellDelayMsChanged: dwellReset()
    property var dwellState: null
    property var dwellCap: null
    property Item dwellDelegate: null
    // Slice two: the hold menu's entry the rest is deciding on. An
    // entry rest and a cap rest share the machine, the timer and the
    // delegate bookkeeping; this field is the discriminator the fire
    // path reads — null for a cap rest, the entry for an entry rest.
    property var dwellEntry: null

    // ---- the input profile (ticket 58) ----
    //
    // Which pointer world this keyboard answers as. The panel resolves
    // the setting over the OBSERVATION (InputProfile.resolve — auto flips
    // to touch at the first synthesized press anywhere on the panel, per
    // summon: a hidden panel forgets, dwell enabled guards it off) and
    // hands the effective profile down; the
    // caps report their presses' `source` back so the fact is panel-wide.
    // Everything the profile switches is InputProfile.js's pure table
    // (tests/input-profile.qml): in mouse every value is byte-today; in
    // touch every character cap types on RELEASE with slide-off cancel
    // (37's machinery generalized), dwell never arms, and a sliding
    // finger is never stolen by our own surfaces.
    property string effectiveInputProfile: "mouse"
    signal pointerSourceObserved(var source)
    readonly property var profileAfford: InputProfile.affordances(
        effectiveInputProfile)
    // The dwell veto the profile owns: the user's setting AND a profile
    // with hover. In touch this is simply false — a finger cannot rest
    // without pressing, and a synthesized press supersedes a rest anyway.
    readonly property bool dwellActive: InputProfile.dwellArms(
        effectiveInputProfile, dwellEnabled)
    onEffectiveInputProfileChanged: dwellReset()

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
    readonly property real cellGap: Math.max(1, Math.round(root.theme.spacingMd * uiScale))
    readonly property real capRowHeight: root.theme.space(42) * uiScale
    // Key radius is the facade's resolved 0–24 value at medium, scaled by
    // the size preset so 24 stays a circle at L/XL (spec-v1.1 §4). Panel
    // radius is a separate pixel control and does not use this.
    readonly property real capCorner: ConfigFile.effectiveKeyRadius(
        root.theme.capCorner, uiScale)
    readonly property real containerMaxWidth: availableWidth > 0
        ? Math.min(root.theme.space(820) * uiScale, availableWidth)
        : root.theme.space(820) * uiScale
    // Rows fill the same total width as the container minus its own
    // padding (which equals the gap), exactly like the CSS container's
    // `padding: var(--gap)` around `.keyboard-grid`.
    readonly property real gridWidthUnits: containerMaxWidth - 2 * cellGap

    // ---- Shared grid pitch (ticket 03, owner round 3) ----
    //
    // Every row is laid out on one cell size: a cap spans `w` cells, each
    // `cellPitch` wide including one gap, so its drawn width is
    // `w * cellPitch - cellGap`. This replaces the per-row proportional flex
    // that row sums of 13.95–17.25 units fed, and which rendered command-row
    // keys and arrows about 20% narrower than the letters above them. With
    // every row declared to the same gridUnits — the tables in
    // KeyboardLayout.js, guarded below — columns align across rows by
    // construction, all rows end flush at both edges
    // (`gridUnits * cellPitch - cellGap == gridWidthUnits`), key sizes are
    // uniform between rows the way the Windows 11 touch keyboard's are, and
    // every width being a multiple of 0.5 keeps all rows' vertical gap lines
    // on one half-unit lattice: adjacent rows' gap lines are offset by
    // exactly half a unit — the classic stagger of the owner's measured
    // Windows reference — so every gap lands mid-key of the neighbouring
    // rows instead of on top of one.
    readonly property real gridUnits: 15.5
    readonly property real cellPitch: (root.gridWidthUnits + root.cellGap) / root.gridUnits

    // ---- Hit geometry (ticket 15) ----
    //
    // The gaps are visual only. A cap is drawn at its own size, but the area
    // that answers the mouse reaches to the midpoint of the gap on every side
    // it shares with a neighbour, so the grid tiles and a click between two
    // caps lands on one of them instead of nowhere. This is a mouse-driven
    // keyboard; a miss costs a correction.
    //
    // Non-overlap is by construction, not by hope, and that is the whole of
    // the design. Neighbours in a row are exactly `cellGap` apart and each
    // claims `cellGap / 2` of it, so the two areas meet on a line and share no
    // area. Rows are `cellGap` apart in the Column and split it the same way,
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
    readonly property real halfGap: cellGap / 2
    // What the outermost caps claim on their outward side. The card's padding
    // around the grid equals the gap (see `gridWidthUnits` above), so this hands the
    // border strip to the caps against it and stops exactly where the card's
    // own chrome starts — the drag bar sits `cellGap` above the top row, so the
    // top row's area meets it rather than stealing from it.
    readonly property real edgeOutset: cellGap

    // The three key fills are the facade's resolved tokens: an explicit key
    // background override pins the resting fill, and hover/press are a
    // modest mix of that resting cap toward the theme foreground either
    // way (Theme.qml owns that derivation and the precedence).
    readonly property color keyBg: root.theme.keyFill
    readonly property color hoverFill: root.theme.keyHoverFill
    readonly property color pressFill: root.theme.keyActiveFill
    readonly property color capEdge: Util.alpha(root.theme.foreground, root.theme.pressedFillAlpha)
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
    readonly property color inkMain: root.theme.textColor
    readonly property color textDim: root.theme.muted
    readonly property color textHighlightColor: root.theme.textColor
    readonly property string glyphTypeface: root.theme.fontFamily
    readonly property int keyBorderWidth: root.theme.normalBorderWidth
    // Doubled rather than taken straight from focusBorderWidth, which falls
    // back to the normal width on themes that do not set it — a latched
    // outline the same thickness as an idle one is not a distinguishable state.
    readonly property int latchedBorderWidth: Math.max(2 * keyBorderWidth, root.theme.focusBorderWidth)
    readonly property int capGlyphSize: Math.max(1, Math.round(root.theme.fontBody * uiScale))
    readonly property int capGlyphSmall: Math.max(1, Math.round(root.theme.fontBodySmall * uiScale))
    // Super's mark (ticket 22, decisions §27 as amended): one arm of the
    // settings choice draws. `superMark` is the effective setting the panel
    // passes in; the pure choice in KeyboardLayout.js names the arm. The
    // Omarchy arm keeps §27's gate — U+E900 / family `omarchy`, the same
    // request the bar menu launcher makes, only after the packaged TTF is
    // present, because Qt.fontFamilies(), FontLoader, fontInfo.family and a
    // zero-width paint miss or substitute this private family. A missing
    // font, like an unknown setting string, lands on the word arm: a mark
    // the system cannot render is never a blank cap.
    property string superMark: "word"
    readonly property string superMarkArm: Layout.superMarkArm(
        root.superMark, root.omarchyFontPresent)
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
    readonly property int superLogoSize: Math.max(root.capGlyphSize,
        Math.round(root.capRowHeight * 0.5))

    // Every modifier's idle/latched state, Shift's additional locked state,
    // and Caps' dedicated boolean state, owned by the reducer (spec-v1 §15,
    // seam 2). The panel draws it; transitions and lines are the module's.
    property var modifierState: Modifiers.initialState()
    property string activeLayoutCode: "us"
    property var layoutCodes: ["us"]
    // The active GROUP index, taken from the compositor's own
    // active_layout_index (spec-v1 §9's "compositor decides"). Selects the
    // variant and kb_file group the keycap compile answers with; a repeated
    // layout code (`us,us` with distinct variants) makes code-position
    // guessing wrong, so nothing here derives the group from the code.
    property int groupCursor: 0
    property var layoutTitles: ({})
    // The keyboard the switch is applied to. Switching "all" moves every device
    // on the seat, including pseudo-keyboards that never advance on their own,
    // which is how they end up sitting on different layouts from each other.
    property string anchorKeyboardName: ""
    // The persisted identity of the keyboard the seat last typed on. Seeded
    // into anchorKeyboardName before the first refresh: a shell restart makes
    // Hyprland re-pick `main` by enumeration order (measured: at-translated,
    // group 0, while the owner's real keyboard sat on group 1) — the named
    // tier then reads the LIVE index of the REAL device instead of a
    // re-enumerated flag.
    property string rememberedLayoutDevice: ""
    signal layoutDeviceNamed(string name)
    // The keyboard the most recent compositor `activelayout` event named —
    // the device that just MOVED, whatever moved it (a deliberate toggle,
    // the panel's own switch loop, or the compositor flipping a group on
    // its own). Motion evidence only: it breaks a diverged seat open in
    // LayoutDevices.select and is never fed to the anchor.
    property string lastLayoutEventDevice: ""
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
    property string activeLayoutName:
        LanguageControl.displayName(activeLayoutCode,
            layoutTitles[activeLayoutCode])
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
    // The restart-settle guard's ledger (ticket 38): which group the panel
    // last FOLLOWED into a configure, what the click's own loop last
    // commanded, and the uncommanded flip currently held out. Everything
    // the reading path consults before following a group change; pure, in
    // SettleGuard.js with its tests. Reset by a genuinely new helper
    // connection (the fresh-hello arm below) — never by the repair
    // timer's re-hello of a live socket, whose world is intact.
    property var settleGuard: SettleGuard.initial()
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
    // position list a caps request carries. The helper resolves what the
    // panel actually shows, not every key the keymap happens to define.
    // The derivation lives in KeyboardLayout.js beside the declarations it
    // reads (ticket 39): this used to re-walk the pages here and read a
    // field the §43 rename had called something else, so the list degraded
    // to RALT alone and the built-in tables drew over twenty-six good
    // letters.
    readonly property string capsPositions: Layout.declaredPositions().join(" ")

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
    // Which page is drawn: main or symbols. A page is not a mode and not a
    // modifier: it changes what can be seen and nothing else — not the
    // keymap, not the group, not what any modifier is holding.
    property string page: "main"
    property var rowModel: Layout.applyLanguage(pageRows(), activeLayoutCode, capsFacts)
    // A row that misses gridUnits is a defect, not a style choice: under the
    // shared pitch a short row stops short of the card's right edge and a
    // long one runs past it. A width off the half-unit lattice — anything
    // that is not a multiple of 0.5 — sums fine but puts that cap's edges
    // between everyone else's gap lines, which is the stagger defect the
    // tables exist to avoid. One loud line per offending row at rebuild
    // time, in the same spirit as reportMisses in KeyboardLayout.js.
    onRowModelChanged: {
        // A rebuild destroys every cap delegate (page switch, language
        // change, facts refresh): a dwell pointing at one of them dies
        // with it — its underline died with the delegate — and never
        // fires into a cap that no longer exists.
        dwellReset()
        for (var i = 0; i < rowModel.length; i++) {
            var sum = 0
            for (var j = 0; j < rowModel[i].length; j++) {
                var w = rowModel[i][j].w || 1
                if ((w * 2) % 1 !== 0) {
                    console.error("[oskar] row " + i + " cap " + j + " width "
                        + w + " is not a multiple of half a unit")
                }
                sum += w
            }
            if (Math.abs(sum - gridUnits) > 0.01) {
                console.error("[oskar] row " + i + " widths sum to " + sum
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

    // `rowModel` is the Repeater's model, and reassigning it destroys and
    // rebuilds every row and every cap delegate under it — a few hundred QML
    // objects, enough main-thread work to be seen. A language switch used to
    // do that four times over: once for the load, once when the facts were
    // invalidated, once when they came back, once when the symbol pipeline
    // exited. Most of those rebuilds produced rows identical to the ones
    // already on screen, so compare first and only reassign when the caps
    // actually differ. The caps are flat objects of primitives built from the
    // same declarations in the same order, so serialising is a sound identity
    // test and costs far less than the rebuild it avoids.
    function rebuildRowModel() {
        if (page !== "main" && page !== "symbols")
            page = "main"
        var next = Layout.applyLanguage(pageRows(), activeLayoutCode, capsFacts)
        if (JSON.stringify(next) === JSON.stringify(rowModel)) return
        rowModel = next
    }

    // Keycap facts arrive after the configure acknowledgement. `rowModel`
    // is assigned imperatively so identical rows can avoid rebuilding the
    // delegates; refresh it when the facts it draws from change.
    onCapsFactsChanged: {
        rebuildRowModel()
        // A standing hold menu offers the OLD facts' levels (the entries
        // were baked at open). Fold it rather than let a pick type a
        // column the acknowledged keymap no longer carries. A hold still
        // pending needs nothing: the threshold re-derives its column, and
        // a release before then types the cap the user pressed. A dwell
        // armed its menu window against the old facts' column and dies
        // with them (the rebuild below would kill its delegate anyway).
        closeHoldMenu()
        dwellReset()
    }

    /// The one key in and the same key out. The reducer is told, so that what
    /// the modifiers do across a switch is decided in the one place the seam
    /// covers rather than here; it holds everything where it was, which is why
    /// locked Shift is still locked and still drawn locked on the far side.
    /// Cycle: main → symbols → main. The label names the destination.
    function togglePage() {
        page = page === "main" ? "symbols" : "main"
        rebuildRowModel()
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
        // The ack is the truthful moment the helper's world — group
        // included — matches the panel's; persist it for the restart
        // fallback (LayoutDevices).
        root.groupConfirmed(session.group)
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
    readonly property string publishedKeymap: "/oskar/keymap.xkb"
    property int sharedKeymapGen: 0
    // The `kb_file` the USER configured, remembered across the moment this
    // panel replaces it with the published one. Without it the compositor's
    // own setting is the only record of it, and pointing `kb_file` at the
    // published keymap erases that record: the next refresh reads our path,
    // has nothing to fall back to, and the helper rebuilds from `kb_layout`
    // alone — the user's custom keymap silently dropped for the rest of the
    // session.
    property string userKeymapFile: ""
    // Whether a snapshot has SEEN the compositor carry something other
    // than the published keymap — the user's own file, or an explicit
    // empty. Once observed, the panel's knowledge is authoritative for
    // the session and the recovery seed stays out: without this flag, a
    // cleared kb_file would be resurrected from the sidecar by the next
    // published-branch snapshot and the clear would never stick (the
    // seed's own record fighting the clear).
    property bool userKeymapObserved: false
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
            // The path comes from the same normalizing builder the
            // identity comparison uses (Session.publishedKeymapPath), so
            // what is SET and what is compared as "ours" can never drift
            // apart over an environment spelling (audit 06).
            // The published path rides as $1 (data, never spliced into
            // either quoting layer) and enters its Lua literal through
            // Session.luaQuote — the security audit's finding: an env
            // spelling must not be able to break out of the bash or the
            // Lua string. The read-back comparison stays against $1.
            "path=$1; lua=$2; "
            + "[[ -s \"$path\" ]] || exit 3; "
            + "hyprctl eval \"hl.config({input = {kb_file = ''}})\" >/dev/null || exit 4; "
            // $lua arrives pre-quoted by Session.luaQuote (single-quoted
            // Lua literal; its contents are data in BOTH the bash and the
            // Lua layer — a double quote would otherwise close the bash
            // string, so luaQuote escapes that byte too).
            + "hyprctl eval \"hl.config({input = {kb_file = $lua}})\" >/dev/null || exit 4; "
            // Read back rather than trust: `eval` answers `ok` for a config
            // call the parser accepted, which is not the same as the value
            // being in place.
            + "[[ \"$(hyprctl getoption input:kb_file -j | jq -r .str)\" == \"$path\" ]]",
            "oskar-share",
            Session.publishedKeymapPath(Quickshell.env("XDG_RUNTIME_DIR")),
            Session.luaQuote(Session.publishedKeymapPath(
                Quickshell.env("XDG_RUNTIME_DIR")))]
        onExited: (code, status) => {
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
            console.error("[oskar] could not give the compositor the published"
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

    // Ticket 06: the recovery read. The helper records the user's own
    // kb_file as a sibling of its runtime directory, before the panel ever
    // points the compositor at the published one; a shell that died
    // without its destruction hook (SIGKILL, crash) has nothing in memory,
    // so the fresh panel seeds the remembered source from that file. One
    // writer (the helper), one reader (this); an absent file is nothing to
    // recover, not an error. The read is taken synchronously AT THE
    // DECISION POINT (recoverUserKeymapSource below): blockLoading makes
    // text() block until the local file is loaded, so no snapshot can
    // build a configure before the seed has landed in memory.
    FileView {
        id: userSourceSeed
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "").replace(/\/+$/, "")
            + "/oskar/user-keymap-source"
        blockLoading: true
        watchChanges: false
        printErrors: false
    }

    // Ticket 57: the existence half of the recovery. What the sidecar
    // remembers may be GONE — the restart-settle leg's private runtime
    // dies with its keymap while the record survives, and adopting the
    // dead pointer wedged every later panel with the same two-second
    // "cannot compile" loop the wall's first run measured. The probe is
    // pointed at the remembered path and read once (blockLoading makes
    // text() a synchronous loadSync, so the decision point stays atomic);
    // the present idiom is omarchyIconFontFile's.
    FileView {
        id: rememberedKeymapProbe
        blockLoading: true
        watchChanges: false
        printErrors: false
        property bool present: false
        onLoaded: present = true
        onLoadFailed: function (error) {
            present = error !== FileViewError.FileNotFound
        }
    }

    // Idempotent: only ever fills an empty memory that has never observed
    // the compositor's own setting, so live knowledge always wins and the
    // file is only a recovery source for a shell that died before it could
    // observe anything. A remembered path that no longer exists is not a
    // user keymap (ticket 57): refusing it lets this configure compile
    // from the compositor's RMLVO, and the helper clears the stale record
    // on the next empty-kb_file configure — the seat heals itself instead
    // of wedging on a file nothing can compile.
    function recoverUserKeymapSource() {
        if (root.userKeymapFile !== "" || root.userKeymapObserved) return
        var remembered = String(userSourceSeed.text() || "").trim()
        if (remembered === "") return
        if (keymapSourceExists(remembered))
            root.userKeymapFile = remembered
    }

    // The one existence rule both keymap-source readers obey (ticket 57):
    // a path that names no file is not a keymap source, wherever it was
    // remembered from — the sidecar's record, or the compositor's own
    // setting observed live. The probe loads synchronously (blockLoading
    // makes text() a loadSync), so every caller stays atomic.
    function keymapSourceExists(path) {
        var target = String(path || "")
        if (target === "") return false
        rememberedKeymapProbe.present = false
        rememberedKeymapProbe.path = target
        // The blocking read: loads or fails synchronously, so `present`
        // already answers for this path when the next line runs.
        rememberedKeymapProbe.text()
        return rememberedKeymapProbe.present
    }

    // Whatever the compositor had before this panel pointed it at the
    // published keymap. A session that ends with the OSK closed must not be
    // left compiling every physical keyboard from a file no running process
    // owns — §35's claim that a stale `kb_file` cannot outlive the thing that
    // set it is only true if something puts it back.
    Component.onDestruction: {
        if (sharedKeymapGen === 0) return
        // The restore interpolates a USER-side path (the compositor's
        // kb_file, or the sidecar any same-user client can set) into a
        // single-quoted Lua literal — a quote in the path closed the
        // string and executed config-side Lua (both auditors; one proved
        // it in a stub). Session.luaQuote escapes every unsafe byte as
        // data for the Lua layer; bash never re-parses expansion results
        // (the cross-round's correction to an earlier note here), so the
        // positional argument is safe by construction at both layers.
        Quickshell.execDetached(["bash", "-c",
            "hyprctl eval \"hl.config({input = {kb_file = $1}})\" >/dev/null 2>&1",
            "onscreen-keyboard-restore", Session.luaQuote(userKeymapFile)])
    }

    function ingestLayoutSnapshot(text) {
        var devices = []
        var kbFile = ""
        var discoveredTitles = ({})

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
            // A layout-code -> human-name row from base.lst.
            if (parts[0] === "TITLE" && parts.length >= 3)
                discoveredTitles[parts[1].trim()] = parts[2].trim()
        })

        // Merge any newly discovered names into the map. Done before the
        // selection can bail out: the names are a property of the machine's
        // xkb rules, not of which keyboard answers today.
        layoutTitles = Object.assign({}, layoutTitles, discoveredTitles)

        var picked = LayoutDevices.select(devices, anchorKeyboardName,
            startupKeyboards, root.rememberedLayoutGroup,
            root.lastLayoutEventDevice)
        // Cleared unconditionally: a refresh that finds no safe target must
        // not leave the language button aiming at a device that has gone
        // missing or was never safe to advance.
        switchKeyboards = picked.switchSet
        // Sticky, and only from the seat's own flag. The flag lands on the
        // helper's virtual keyboard for a moment after every OSK keystroke,
        // so "no answer" has to mean "keep what we knew", not "forget".
        if (picked.typing) {
            if (picked.typing !== anchorKeyboardName)
                root.layoutDeviceNamed(picked.typing)
            anchorKeyboardName = picked.typing
        }
        if (!picked.reading) return

        var reading = picked.reading
        var detected = String(reading.layout || "us").split(",")
            .map(function (code) { return String(code || "").trim() })
            .filter(function (code) { return code.length > 0 })
        if (detected.length)
            layoutCodes = detected
        var configGroup = (typeof picked.group === "number" && picked.group >= 0)
            ? picked.group : (reading.active_layout_index || 0)
        console.log("[oskar] layout reading:", reading.name, "group:", configGroup,
            "named:", anchorKeyboardName || "(none)",
            "remembered:", root.rememberedLayoutGroup)
        // The restart-settle guard (ticket 38): for a short window after
        // the establishing configure that follows a daemon (re)connect, an
        // UNcommanded group flip is Hyprland's own keymap re-application
        // churn — a fresh vkb registration makes the compositor re-apply
        // keymaps, a devices read can return the reading keyboard at its
        // pre-churn group, and following that echo once split the seat
        // (ITE keyboards on the clicked group, at Translated back on 0)
        // while dragging `remembered` onto the churn. The click's own
        // hyprctl loop (switchToGroup) is never gated: only this FOLLOW is.
        // On hold, the panel keeps configuring the group it followed last
        // — so the vkb, the caps, the cursor and `remembered` (persisted
        // from configure acks) all stay on the clicked group, and one
        // re-read after the quiesce interval supplies the second agreeing
        // reading a genuine external switch deserves to be followed on.
        // The establishing configure itself is never held, which is what
        // keeps the §47 remembered tie-breaker answering on a cold start
        // exactly as before (SettleGuard.decide's first arm).
        var settle = SettleGuard.decide(root.settleGuard, configGroup,
            Date.now())
        root.settleGuard = settle.state
        if (!settle.follow) {
            console.log("[oskar] settle guard: holding group", settle.held,
                "— uncommanded reading", configGroup,
                "inside the post-reconnect window")
            configGroup = settle.held
            settleRecheck.restart()
        }
        var active = (configGroup !== (reading.active_layout_index || 0))
            ? LayoutDevices.activeLayoutForGroup(reading, configGroup)
            : LayoutDevices.activeLayout(reading)
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
        // above, or recovered from the helper's sidecar after a shell that
        // died without its destruction hook (ticket 06) — so `kb_layout`
        // edits and a custom keymap both keep working. When it is NOT on the
        // published keymap, something dropped it: a `hyprctl reload` for a
        // theme change resets a runtime `kb_file` to whatever the config
        // file says, and the configure that follows is byte-identical, so
        // the helper's generation never moves and the once-per-generation
        // guard would never fire again. Re-arm instead.
        //
        // Exact identity, never a substring: a user's own file under a
        // directory ending in our suffix is the user's, and the substring
        // test adopted it as ours (audit 06). The seed read happens HERE,
        // at the decision point, so no snapshot can build its configure
        // before the recovered source has landed in memory.
        recoverUserKeymapSource()
        if (Session.isPublishedKeymap(kbFile, Quickshell.env("XDG_RUNTIME_DIR"))) {
            xkbFile = userKeymapFile
        } else {
            // A live observation of the user's own setting — including an
            // explicit empty: from here the recovery seed stays silent.
            userKeymapObserved = true
            // The live arm of ticket 57's rule: a compositor setting that
            // names a file which does not exist — a foreign runtime's
            // published map, deleted with it while this panel watched —
            // is not a user keymap either, and adopting it wedges every
            // later configure exactly like the seed's dead path. Emptied,
            // this snapshot compiles from RMLVO and the share below
            // points the compositor back at the published keymap.
            if (kbFile !== "" && !keymapSourceExists(kbFile)) {
                console.warn("[oskar] the compositor's kb_file names a"
                    + " keymap that no longer exists; configuring from"
                    + " RMLVO instead:", kbFile)
                kbFile = ""
            }
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
        var codeShown = active || detected[0] || ""
        if (codeShown) {
            // The compositor is authoritative for both the group and its
            // human-facing layout code. The old keycap loader used to assign
            // this as a side effect; after that pipeline was removed the
            // header stayed on the initial "us" forever.
            activeLayoutCode = codeShown
            // The group index is the compositor's own `active_layout_index`,
            // not the position of the active layout code in the list. The
            // two differ exactly when a code repeats — `us,us` with distinct
            // variants is the ordinary case — and `indexOf` there always
            // found the first twin, so the keycap compile below kept
            // answering group 0's variant while typing used the active
            // group. The index is authoritative; the code is a label.
            groupCursor = configGroup
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
            }
            sendConfigure(configure)
        }
    }

    function pullLayoutsFromCompositor() {
        compositorQuery.running = false
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
        compositorQuery.command = ["bash", "-c",
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
            + "  name=$(sed -n \"/^! layout/,/^! /p\" /usr/share/X11/xkb/rules/base.lst 2>/dev/null "
            + "    | awk -v want=\"$code\" '$1==want { $1=\"\"; sub(/^ +/, \"\"); print; exit }'); "
            + "  [[ -n \"$name\" ]] && printf 'TITLE\\t%s\\t%s\\n' \"$code\" \"$name\"; "
            + "done", "onscreen-keyboard"]
        compositorQuery.running = true
    }

    // The one switch primitive both language-control shapes use: move every
    // device in the switch set to one ABSOLUTE group. The chooser passes the
    // picked index (ticket 35); stepLayout passes the two-layout cycle.
    function switchToGroup(next) {
        // The group index is the seat's truth — xkb lists can repeat a code
        // across variants, so a code is not an address. Bounded against the
        // list as it stands NOW: a pick a configure shrank out of range
        // while a chooser stood open becomes a no-op. (A pick still in range
        // after a REORDER lands on whatever code now owns that index — rare,
        // and the seat still converges on one group.)
        if (next < 0 || next >= layoutCodes.length) return
        if (switchKeyboards.length === 0) return
        // Ticket 38: the click is user intent. Told to the settle guard so
        // its echo reading is followed immediately inside the post-reconnect
        // window (a guard that held its own click would break language
        // switching for the window's length) and so any flip the guard was
        // holding dies when the user clicks through it. The loop below is
        // untouched — the guard only gates the panel's FOLLOW of what the
        // seat then reads.
        root.settleGuard = SettleGuard.commanded(root.settleGuard, next,
            Date.now())
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

    function stepLayout() {
        if (layoutCodes.length < 2 || switchKeyboards.length === 0) return
        switchToGroup((groupCursor + 1) % layoutCodes.length)
    }

    Component.onCompleted: {
        // The ticket-06 recovery seed runs before the first snapshot can
        // build a configure (and once more at the decision point itself):
        // blockLoading makes the local read synchronous.
        recoverUserKeymapSource()
        if (root.rememberedLayoutDevice !== "")
            root.anchorKeyboardName = root.rememberedLayoutDevice
        pullLayoutsFromCompositor()
    }

    Process {
        id: compositorQuery
        property string snapshotText: ""
        stdout: SplitParser {
            onRead: (data) => {
                compositorQuery.snapshotText += data + "\n"
            }
        }
        onRunningChanged: () => {
            if (running) snapshotText = ""
        }
        onExited: (code, status) => {
            // Quickshell's second argument is QProcess ExitStatus, where
            // 0 is the NORMAL exit — not a boolean success.
            if (code !== 0 || status !== 0) return
            root.ingestLayoutSnapshot(compositorQuery.snapshotText)
        }
    }

    // Ticket 38: one re-read per held reading. A held flip is one
    // observation; a genuine external switch persists, so a fresh snapshot
    // after the quiesce interval supplies the agreeing reading that lets
    // the guard follow it, while churn keeps re-anchoring the candidate's
    // clock and staying held. Each hold restarts this timer, and the
    // window's expiry is the ultimate bound on how long any of this runs.
    Timer {
        id: settleRecheck
        interval: SettleGuard.QUIESCE_MS + 100
        repeat: false
        onTriggered: root.pullLayoutsFromCompositor()
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
                if (name.indexOf("activelayout") !== -1) {
                    // "device >> layout": the first field names the keyboard
                    // the event is about. Recorded BEFORE the refresh it
                    // triggers, so the divergence arm sees who moved.
                    var fields = String(event.data || "").split(">>")
                        .map(function (field) { return field.trim() })
                        .filter(function (field) { return field !== "" })
                    if (fields.length > 0) root.lastLayoutEventDevice = fields[0]
                }
                root.pullLayoutsFromCompositor()
            }
        }
    }

    // Hyprland's IPC has no input-device hotplug event. udev does, so one
    // event stream requests fresh helper/compositor snapshots on add/remove.
    // It wakes for events only; there is no seat poll or heartbeat.
    Process {
        id: inputDeviceMonitor
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=input", "--property"]
        running: true  // awake for its whole lifetime, by design
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
    function applyModifierEvent(event, lineSink) {
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
        // lifts them for real. Settling speculatively here would erase
        // the lock before the refusal could name it, and the helper's held
        // set would re-assert the modifier after `mods 0`.
        var outcome = Modifiers.reduce(modifierState, dropRestore
            ? { type: "release", dropRestore: true } : event)
        modifierState = outcome.state
        for (var i = 0; i < outcome.lines.length; i++) {
            if (lineSink)
                lineSink(outcome.lines[i])
            else
                sendCommandUnchecked(outcome.lines[i])
        }
    }

    /// Current-content paste (spec-v1.1 §1): an exact chord through the
    /// reducer, never a held cap and never mixed with latched Ctrl/Alt/Super.
    /// `wmClass` selects the CLIPBOARD chord (terminals: Ctrl+Shift+V; else
    /// Shift+Insert). Empty class uses the terminal chord so PRIMARY is not
    /// sent into a terminal the lookup failed to name.
    // The wine chord's delivery: one line per tick, never a burst. Wine
    // polls its keyboard a frame at a time, and a chord whose lines all
    // land in the same instant can be sampled with V visible before Ctrl
    // — a manual Ctrl+V never has the problem, because hands have
    // latency. The state settles immediately (the reducer ran); only the
    // writes are paced, and a second paste while one is pacing is
    // refused rather than interleaved.
    //
    // Ticket 28's transaction contract (audit 2026-09-13): a paste is no
    // longer fire-and-forget. The optional `completed` callback fires
    // exactly once — after the final paced line is dispatched for a wine
    // chord, after every line is accepted by the socket writer for an
    // immediate one, and synchronously with false on any refusal (already
    // pacing, a held key, an unready input, a dead socket mid-pace). The
    // emoji page records usage only from a real completion; the paste
    // chip still calls without one, unchanged.
    property bool pastePacing: false
    property var pastePacedLines: []
    // The full chord and how much of it went out, so an abort can owe the
    // device exactly its unlifted presses.
    property var pastePaceAllLines: []
    property int pastePaceSent: 0
    property var pastePaceDone: null
    // The chord whose final line is out and whose helper acknowledgement
    // has not come back yet. Success is the ack of ITS OWN last command,
    // correlated through ChordAcks' outstanding-commands ledger — not the
    // first `ok` on the wire (which answers the chord's Ctrl press), and
    // not the panel's own socket write (the review's third and fourth
    // rounds: the next emoji's publication used to race a destination
    // that had not received the paste yet). The ack says the events
    // reached the compositor — nothing shorter is completion, and one
    // chord waits at a time (the transaction serializes them) behind a
    // guard timer a silent helper cannot wedge.
    property var chordAcks: ChordAcks.initial()
    // Which modifiers were locked when the chord computed its lines: a
    // mid-chord event that changes the held world (a configure draining
    // the device, a releaseAll) invalidates the remaining lines, and the
    // chord aborts instead of writing plans for a world that is gone.
    property var pastePaceLocks: []
    Timer {
        id: pastePacedTick
        interval: 35
        repeat: false
        onTriggered: () => {
            if (!root.pastePacing) return
            if (root.pastePacedLines.length === 0) {
                root.pastePacing = false
                return
            }
            if (!root.inputReady || !root.pasteChordAssumptionsHold()) {
                // The head line is neither consumed nor counted: nothing
                // was dispatched for it, so the sent prefix the abort
                // compensates is exactly what left the panel.
                root.abortPacedPaste()
                return
            }
            if (!sendCommandUnchecked(root.pastePacedLines.shift())) {
                // The write refused: the consumed line pressed nothing at
                // the device (nothing owed for it), and the socket being
                // gone means the compensations are forwarded no-ops —
                // the helper already released its claims on disconnect.
                root.abortPacedPaste()
                return
            }
            root.pastePaceSent++
            if (root.pastePacedLines.length > 0) restart()
            else root.finishPacedPaste(true)
        }
    }

    // The chord's assumptions still hold while no key press interleaved
    // and the locked-modifier set is exactly the one its lines planned
    // around. Pure comparison; the abort itself lives below.
    function pasteChordAssumptionsHold() {
        if (modifierState.pending) return false
        for (var i = 0; i < Modifiers.ORDER.length; i++) {
            var name = Modifiers.ORDER[i]
            var lockedNow = modifierState[name] === "locked"
            var lockedThen = root.pastePaceLocks.indexOf(name) !== -1
            if (lockedNow !== lockedThen) return false
        }
        return true
    }

    function finishPacedPaste(success) {
        root.pastePacing = false
        var done = root.pastePaceDone
        root.pastePaceDone = null
        if (done && success)
            settleChordThroughHelper(done)
        else if (done)
            done(false)
    }

    // Route a dispatched chord's success through the helper's ack of its
    // final line. Failure paths never wait: a refusal, an abort or a dead
    // socket is already a verdict.
    function settleChordThroughHelper(done) {
        if (!done) return
        root.chordAcks = ChordAcks.chordArmed(root.chordAcks, done)
        chordAckGuard.restart()
    }

    function chordAckSettled(success) {
        var done = root.chordAcks.chordDone
        root.chordAcks = ChordAcks.chordSettled(root.chordAcks)
        chordAckGuard.stop()
        if (done) done(success)
    }

    Timer {
        id: chordAckGuard
        interval: 5000
        repeat: false
        onTriggered: () => {
            if (root.chordAcks.chordDone) root.chordAckSettled(false)
        }
    }

    // A paced chord that cannot continue: lift what its sent prefix
    // pressed without pairing, converge the modifier state by lifting
    // (never re-press — the releaseAll that follows resets the panel's
    // locks to match a device that no longer holds them), and report the
    // cancellation. After a socket loss every write here is a forwarded
    // no-op: the helper released its claims on disconnect, and a dead
    // socket cannot owe anything (the disconnect path's own argument).
    function abortPacedPaste() {
        var owed = ClipboardPaste.compensatingReleases(root.pastePaceAllLines,
            root.pastePaceSent)
        for (var i = 0; i < owed.length; i++)
            sendCommandUnchecked(owed[i])
        root.pastePacedLines = []
        applyModifierEvent({ type: "releaseAll" })
        root.finishPacedPaste(false)
    }

    function pasteCurrent(wmClass, completed) {
        var done = completed || null
        var cls = String(wmClass || "")
        var chord = Modifiers.pasteChordForClass(cls)
        console.log("[oskar] paste chord for", cls === "" ? "(unknown class)" : cls,
            "->", (chord.ctrl ? "Ctrl+" : "") + (chord.shift ? "Shift+" : "")
            + chord.position)
        var event = {
            type: "paste",
            ctrl: chord.ctrl === true,
            shift: chord.shift === true,
            position: chord.position
        }
        if (Modifiers.usesWinePasteChord(cls.toLowerCase())) {
            // Refused while pacing, not fallen through to the instant
            // path: an immediate write here would interleave with the
            // draining queue (review finding).
            if (root.pastePacing) {
                if (done) done(false)
                return false
            }
            root.pastePacing = true
            root.pastePacedLines = []
            applyModifierEvent(event, function (line) {
                root.pastePacedLines.push(line)
            })
            if (root.pastePacedLines.length === 0) {
                // The reducer refused (a key press is pending) or input
                // is not ready: nothing was dispatched and nothing will
                // complete.
                root.pastePacing = false
                if (done) done(false)
                return false
            }
            root.pastePaceAllLines = root.pastePacedLines.slice()
            root.pastePaceSent = 0
            root.pastePaceDone = done
            root.pastePaceLocks = []
            for (var m = 0; m < Modifiers.ORDER.length; m++)
                if (modifierState[Modifiers.ORDER[m]] === "locked")
                    root.pastePaceLocks.push(Modifiers.ORDER[m])
            pastePacedTick.restart()
            return true
        }
        var sent = 0
        var wrote = true
        applyModifierEvent(event, function (line) {
            sent++
            if (!sendCommandUnchecked(line)) wrote = false
        })
        if (sent === 0 || !wrote) {
            if (done) done(false)
            return false
        }
        // Success is the helper's acknowledgement of the final line, not
        // the write returning (the review's third round): the next emoji
        // must not replace the clipboard before the paste events have at
        // least reached the compositor.
        settleChordThroughHelper(done)
        return true
    }

    /// One emoji's sequence to the focused client (ticket 24, step 4): the
    /// helper's `text`/`text-unicode` command over the same socket and the
    /// same unchecked write every command uses. Gated like a tap — with the
    /// helper not ready the caps draw gated and the send is a silent no-op,
    /// so an emoji click with the service down spends the page and nothing
    /// else. Protocol 5 gave text its own replies: `text-ok` settles the
    /// first queued callback with success, `text-err …` with failure, so
    /// usage and page-close wait for the helper's acknowledgement — and a
    /// refusal reaches the caller instead of passing unnoticed. None of
    /// them disturbs the configure ledger, which only `configured` and
    /// `err cannot configure keymap` can move.
    function sendText(s, completed, unicodeEntry) {
        if (!root.inputReady) return false
        var line = Session.textLine(s)
        if (line === "") return false
        if (unicodeEntry) line = "text-unicode " + s
        if (!sendCommandUnchecked(line)) return false
        var queue = root.pendingTextReplies.slice()
        queue.push(completed || null)
        root.pendingTextReplies = queue
        return true
    }

    /// Lifts locked Shift and returns every modifier to idle. The panel closing
    /// is not the compositor forgetting: locked Shift is really held at the
    /// device and must come up before the socket goes away. A paced chord
    /// still draining aborts first — its remaining lines were planned for a
    /// world this release is about to reset, and its tail (the Shift
    /// re-press) would re-hold what the close is lifting.
    function releaseModifiers() {
        if (root.pastePacing) root.abortPacedPaste()
        // The panel is closing (this runs from its close branch): a
        // pending hold can never reach its release and a standing menu
        // has no panel left to stand on — both fold here, before the
        // releaseAll, so the close leaves nothing of ticket 37 behind.
        // A dwell dies with the panel for the same reason: its timer
        // must not type into whatever the user opens next.
        clearCapHold()
        closeHoldMenu()
        dwellReset()
        applyModifierEvent({ type: "releaseAll" })
    }

    function shiftActive() {
        return Modifiers.isActive(modifierState, "shift")
    }

    function symbolLayerHeld() {
        return shiftActive()
    }

    // A letter key is one whose shifted symbol is simply the capital of its
    // base. The rule lives in KeyboardLayout.js beside the keycap pipeline it
    // serves (and is tested at the pure seam with it); the wrapper keeps this
    // file's call sites — the reducer's `letter` fact and the dual-cap test —
    // reading exactly as they always have.
    function isAlphabeticCap(capData) {
        return Layout.isLetterKey(capData)
    }

    // What this cap says it types, under the reducer's current Caps and Shift.
    // The rule is Layout.charUnderModifiers's: an exact cap (the curated page's)
    // answers only to the level it carries — never redrawing as another symbol
    // because Shift is active, which is the agreement between what a cap shows
    // and what its exact press types (review finding R3) — letters swap on
    // Caps XOR Shift, and other paired caps shift with Shift alone.
    function charUnderModifiers(capData) {
        return Layout.charUnderModifiers(capData, modifierState.caps,
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
    function isStackedPair(capData) {
        return capData.dual === true
            || (!!capData.chrShift && !isAlphabeticCap(capData))
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
    // The panel's remembered layout group (LayoutDevices' restart
    // fallback): bound from the persisted state by the panel, so a shell
    // restart with no live device evidence does not fall to a majority of
    // sleeping keyboards. Confirmed groups are reported back for
    // persistence through groupConfirmed.
    property int rememberedLayoutGroup: 0
    signal groupConfirmed(int group)
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
    // The hello watchdog's ledger (ticket 47): a hello was written and
    // nothing has arrived from the helper since. `connected` alone cannot
    // be trusted to say the pipe is alive — a peer-closed quickshell
    // Socket can keep reporting true (observed live twice: the owner's
    // original note in the error handler below, and the install-from-zero
    // stranger's whole session) — so liveness is proved by traffic, and a
    // hello outstanding past SocketWatch.HELLO_STALE_MS rebuilds the
    // socket whatever `connected` claims. Cleared by every arriving line,
    // by a disconnect, and by the rebuild itself (the hello belonged to
    // the object being torn down).
    property bool helloInFlight: false
    property real helloSentAt: 0
    // Root-scope alias because the component's own id does not reach the
    // functions out here.
    property QtObject daemonSocket: helperLoader.item

    // The one rebuild of the socket object: destroy and recreate it
    // through the loader, on the next tick where QML is idle enough to
    // tear a live object graph down safely. onError's original home, now
    // shared with the watchdog's "rebuild" answer and the path check —
    // one place that knows a fresh socket object is the cure.
    function rebuildSocket() {
        root.helloInFlight = false
        // The disconnect arm's first act, carried here for the same
        // reason (ticket 54 review F1): the watchdog can order a rebuild
        // while inputReady still reads true (readiness moves only on
        // traffic outcomes, and 5 s of silence proves none), and a click
        // in the teardown window would otherwise queue onto a drained
        // FIFO and write into the dying socket.
        root.inputReady = false
        // Ticket 54: a lying socket never runs the disconnect arm, so the
        // rebuild carries that arm's two residual resets itself — the
        // text-reply FIFO (a stale head would be settled by a post-
        // recovery text-ok, the wrong reply for the wrong request) and
        // the compositor share generation (a restarted daemon can repeat
        // the stale one and the once-per-generation guard would skip a
        // re-share). SocketWatch owns the ledger, pinned by its suite.
        var resets = SocketWatch.rebuildResets({
            pendingTextReplies: root.pendingTextReplies,
            sharedKeymapGen: root.sharedKeymapGen
        })
        root.pendingTextReplies = resets.pendingTextReplies
        root.sharedKeymapGen = resets.sharedKeymapGen
        // A chord awaiting its final line's ack cannot be completed by a
        // helper that is being torn down: settle it as a cancellation, the
        // way every other failure path already does — and the ledger of
        // oks owed by the dead connection dies with it.
        if (root.chordAcks.chordDone) root.chordAckSettled(false)
        root.chordAcks = ChordAcks.connectionLost(root.chordAcks)
        Qt.callLater(function () {
            helperLoader.active = false
            helperLoader.active = true
        })
    }

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
        id: helperLoader
        active: true
        sourceComponent: helperComponent
    }

    Component {
        id: helperComponent

        Socket {
            id: helper
            path: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/oskar/control.sock"
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
                    root.pendingTextReplies = []
                    // The hello this object was owed can no longer arrive;
                    // the watchdog must not keep waiting on it.
                    root.helloInFlight = false
                    // The handshake no longer holds on this dead socket; the
                    // queue and facts stay until a new connection's fresh
                    // hello restarts them (a live helper may still answer for
                    // the transaction a reconnect is racing).
                    root.session = Session.reduce(root.session, { type: "connectionDown" })
                    // A chord awaiting its final line's ack settles as a
                    // cancellation — the helper released everything it held
                    // on the way down, no ack is coming, and the ledger of
                    // oks owed by this connection dies with it.
                    if (root.chordAcks.chordDone) root.chordAckSettled(false)
                    root.chordAcks = ChordAcks.connectionLost(root.chordAcks)
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
                    // Any line from the helper proves the pipe alive end to
                    // end (ticket 47's watchdog): the daemon serves each
                    // connection in order, so whatever this is, a hello
                    // written before it has been answered or overtaken by
                    // work that is about to answer.
                    root.helloInFlight = false
                    if (reply === "hello " + Session.PROTOCOL_VERSION) {
                        root.serviceIncompatible = false
                        root.inputReady = false
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
                            // Ticket 38: a genuinely new connection also
                            // resets the settle guard's world — the helper
                            // is back at group 0 and whatever this panel
                            // followed or commanded belongs to the old
                            // socket. The next reading establishes and arms
                            // the post-reconnect window. The repair timer's
                            // re-hello (the else arm below) changes nothing
                            // here: a live socket's world is intact.
                            root.settleGuard = SettleGuard.connected(
                                root.settleGuard)
                            root.modifierState = Modifiers.reduce(
                                root.modifierState, { type: "releaseAll" }).state
                            // Session bookkeeping starts over with the
                            // connection: the next configure's identity must
                            // be compared against what THIS helper instance
                            // has acknowledged, and no reply can still arrive
                            // for a transaction a predecessor was holding.
                            root.session = Session.reduce(root.session,
                                { type: "helloAcked", fresh: true })
                            helper.write("mods 0\n")
                        } else {
                            // The repair timer's re-hello of a live socket:
                            // the handshake holds, nothing resets.
                            root.session = Session.reduce(root.session,
                                { type: "helloAcked", fresh: false })
                        }
                        helper.write("keyboards\n")
                        helper.flush()
                        // A restarted helper is back at group 0 and has no idea
                        // which layout is current. Re-reading the compositor
                        // sends the right group; using groupCursor here
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
                            if (!root.anchorKeyboardName)
                                root.anchorKeyboardName = root.startupKeyboardName
                        }
                        root.pullLayoutsFromCompositor()
                    } else if (reply === "text-ok"
                            && root.pendingTextReplies.length > 0) {
                        var successes = root.pendingTextReplies.slice()
                        var succeeded = successes.shift()
                        root.pendingTextReplies = successes
                        if (succeeded) succeeded(true)
                    } else if (reply === "ok") {
                        // One plain command acknowledged. Draining the
                        // ledger settles a waiting chord exactly when its
                        // own final line's ack has arrived — never on the
                        // first ok of the burst.
                        var ack = ChordAcks.okReceived(root.chordAcks)
                        root.chordAcks = ack.state
                        if (ack.settle) root.chordAckSettled(true)
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
                                    console.log("[oskar] caps requested for group(s)",
                                        missing.join(","), "of", root.groupCount)
                                for (var mg = 0; mg < missing.length; mg++)
                                    sendCommandUnchecked(capsRequestLine(missing[mg]))
                            }
                            root.inputReady = Session.typingReady(root.session)
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
                            console.error("[oskar] unreadable keycap facts reply")
                            root.capsFactsFailed = true
                            root.inputReady = false
                        } else {
                            var applied = Session.applyCapsReply(root.session, parsed)
                            root.session = applied.state
                            if (applied.accepted) {
                                root.capsFactsFailed = false
                                root.shareKeymapWithCompositor()
                                if (Session.typingReady(root.session)) {
                                    root.inputReady = true
                                }
                            }
                        }
                    } else if (reply.indexOf("text-err") === 0) {
                        if (root.pendingTextReplies.length > 0) {
                            var failures = root.pendingTextReplies.slice()
                            var failed = failures.shift()
                            root.pendingTextReplies = failures
                            if (failed) failed(false)
                        }
                        console.warn("[oskar] text delivery refused:", reply)
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
                        } else if (reply === "err not ready") {
                            // A helper fresh out of systemd start answers err
                            // until its default keymap is installed; it cannot
                            // become ready without a configure, and nothing
                            // else sends one — so ask the compositor now
                            // instead of waiting out the repair timer.
                            root.pullLayoutsFromCompositor()
                        } else if (reply === "err key held" || reply === "err not holding") {
                            // Ownership refusals mean the helper's hold state
                            // is ahead of ours; the device is fine and typing
                            // stays enabled. The panel's chords never produce
                            // them, so one appearing is a client bug worth a
                            // journal line without bricking the keyboard.
                            console.warn("[oskar] ownership refusal:", reply)
                        } else if (reply === "err bad group") {
                            // A caps request earns this when the helper
                            // refuses facts for a group its keymap does not
                            // carry; since ticket 31 a refused configure or
                            // `group` command answers the same way. The
                            // panel can earn the latter two in one place
                            // since §53: a settle-held group meeting a
                            // layout list that shrank inside the window —
                            // a triple coincidence that self-heals through
                            // the quiesce follow — and the handling below
                            // stays caps-shaped on purpose there too. For the group being DRAWN that
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
                            } else {
                                console.error("[oskar] helper has no facts for a"
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
                        } else if (reply === "err unknown command") {
                            // Protocol 5 rewrote every text/text-unicode
                            // refusal into `text-err …`, settled by the arm
                            // above; `err unknown command` is the one
                            // refusal any verb can still earn, and it says
                            // the installed helper predates this panel's
                            // verbs — status-only, never a typing gate.
                            console.warn("[oskar] helper refused a command:", reply)
                        } else {
                            // An unrecognized reply can only be protocol
                            // drift; fail closed and leave a trace.
                            root.inputReady = false
                            console.warn("[oskar] unrecognized reply:", reply)
                        }
                    } else if (reply.indexOf("hello ") === 0) {
                        // A hello naming another version than the one this
                        // panel asked for is the same incompatibility in a
                        // different shape. Defensive: the current helper
                        // errs instead of greeting across versions.
                        root.serviceIncompatible = true
                        root.inputReady = false
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
                root.rebuildSocket()
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
        onTriggered: () => {
            if (root.daemonSocket) {
                // The version the session negotiates, never a literal: the
                // reply matcher above compares against the same constant, and
                // a stale literal here reads as an installation mismatch
                // against a helper this panel is actually compatible with.
                root.daemonSocket.write("hello " + Session.PROTOCOL_VERSION + "\n")
                root.daemonSocket.flush()
                // The watchdog's mark: written and unanswered. The write
                // itself cannot be trusted to fail on a dead transport
                // (quickshell may buffer it silently), so the mark is set
                // unconditionally and only ever cleared by arriving traffic.
                root.helloInFlight = true
                root.helloSentAt = Date.now()
            }
        }
    }

    Process {
        id: socketPathCheck
        command: ["test", "-S", (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/oskar/control.sock"]
        onExited: (code, ok) => {
            // The check ran a moment ago; the socket may have connected since
            // (the original attempt succeeding, or a sibling tick's rebuild).
            // Rebuilding a live connection would drop it mid-handshake.
            var item = root.daemonSocket
            if (code === 0 && !root.inputReady && !(item && item.connected)) {
                root.rebuildSocket()
            }
        }
    }

    Timer {
        id: reconnectTimer
        interval: 2000
        repeat: true
        // Also while a configure is outstanding. Readiness alone stopped being
        // enough once a group-only configure no longer lowered `inputReady`
        // (ticket 16): a socket that stays `connected` but never answers
        // `configured` would leave the panel ready-looking, drawing the acked
        // group while the helper types the queued one, with no tick to notice.
        // A configure is answered in well under this interval — the helper
        // replies before it compiles anything — so an entry still outstanding
        // when this fires is a lost reply, not a slow one.
        running: !root.inputReady || !Session.settled(root.session)
        onTriggered: () => {
            // Ticket 47's watchdog: the decision is SocketWatch's pure table,
            // pinned in tests/socket-watch.qml. The old inline policy — an
            // open socket is only ever re-helloed — turned a socket that lies
            // `connected` on a peer-closed transport into a permanent wedge
            // (the install-from-zero stranger's dead keys: re-hellos written
            // into a dead object, "Starting oskar.service…" standing,
            // every key click a silent no-op, escape only by shell restart).
            // Now a hello outstanding past its fair window rebuilds the
            // socket object whatever `connected` claims; a live helper
            // answers hello in well under a second, so only a socket that
            // cannot deliver ever sees the window expire. The rebuild path
            // is also the silent-dial cure: a fresh socket that connects
            // without ever signalling gets a hello on the next tick, and
            // the tick after that treats its silence the same way.
            var item = root.daemonSocket
            var action = SocketWatch.reconnectAction({
                connected: !!(item && item.connected),
                helloInFlight: root.helloInFlight,
                helloAgeMs: Date.now() - root.helloSentAt
            })
            if (action === "hello") {
                helloTimer.restart()
                return
            }
            if (action === "rebuild") {
                root.rebuildSocket()
                return
            }
            if (action === "path-check") {
                socketPathCheck.running = true
                return
            }
            // "wait": the outstanding hello is still inside its window.
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
        // Every plain command sent is an ok owed: the chord's wait drains
        // this ledger, so it must see every plain send — counted here, at
        // the one choke point every command goes through.
        root.chordAcks = ChordAcks.sent(root.chordAcks, text).state
        return true
    }

    // ---- the hold column's event path (ticket 37) ----
    //
    // The column one cap would offer right now: the position's extra
    // levels, read from the live caps facts. Both the defer decision and
    // the menu content flow through here so they cannot disagree about
    // what the keymap carries.
    function capHoldColumn(capData) {
        if (!capData || !capData.xkb || !capsFacts) return []
        return HoldColumn.columnEntries(capsFacts[capData.xkb])
    }

    function capDefersHold(capData) {
        // Ticket 58's generalisation, composed at the seam so it is
        // pinned (tests/input-profile.qml): in the MOUSE profile this is
        // ticket 50's interplay verbatim — Dwell.holdDefers, i.e. ticket
        // 37's column-only defer with the dwell veto over it, byte-today.
        // In the TOUCH profile every character cap defers — a drifting
        // finger must never strand a phantom character under
        // press-typing — on InputProfile.touchDefers's own rule (the
        // hold-menu threshold rides the same beginCapHold/endCapHold
        // machinery; a columnless hold stays pending past the threshold
        // and the release then types).
        return InputProfile.defersTyping(effectiveInputProfile, dwellEnabled,
            capData, capHoldColumn(capData), searchMode, inputReady)
    }

    function beginCapHold(capData, delegate) {
        holdCap = capData
        holdDelegate = delegate
        capHoldTimer.restart()
    }

    function clearCapHold() {
        holdCap = null
        holdDelegate = null
        capHoldTimer.stop()
    }

    /// The release half of a deferred cap. True when this delegate's hold
    /// consumed the release: before the threshold, the usual press+
    /// release pair goes out NOW — one character, today's chord rules and
    /// current latches, exactly the pair a non-deferred cap sends across
    /// press and release, only both at the release (the click sound moves
    /// with it, inside typeCap: no sound for a key that goes nowhere).
    /// After the threshold opened the menu the release is the hold's own
    /// and sends nothing; the menu stands for its own pick. Readiness can
    /// drop between press and release — then nothing is typed, like a
    /// canceled hold, rather than sounding a dead key.
    ///
    /// `inside` is the touch profile's slide-off half (ticket 58): false
    /// means the pointer LIFTED outside the cap's hit area, and a lifted
    /// finger that left first cancels — the drift a touch screen is for
    /// must never type. Undefined (the mouse profile's call) keeps
    /// byte-today semantics: a mouse hold's release types wherever the
    /// cursor sits when the button comes up.
    function endCapHold(delegate, inside) {
        if (holdCap) {
            if (holdDelegate !== delegate) return false
            var cap = holdCap
            clearCapHold()
            if (inside === false) return true
            if (!inputReady) return true
            typeCap(cap)
            releaseKey()
            return true
        }
        return holdMenuOpen && holdMenuDelegate === delegate
    }

    /// A deferred hold that lost its grab: nothing was ever down, so
    /// nothing is typed — strictly better than the stray character a
    /// press-typing cap leaves — and a menu that had opened folds with
    /// the hold that opened it.
    function cancelCapHold(delegate) {
        if (holdDelegate !== delegate && holdMenuDelegate !== delegate)
            return false
        clearCapHold()
        closeHoldMenu()
        return true
    }

    /// The threshold fired: open the menu over the held cap, or leave the
    /// hold pending when the position turns out to have nothing to offer
    /// (facts changed under the hold) — a release then still types, which
    /// is as close to "behaves exactly as today" as a deferred press can
    /// come, and no character was typed by the hold itself either way.
    function openHoldMenu() {
        if (!holdCap || !holdDelegate) {
            clearCapHold()
            return
        }
        var entries = capHoldColumn(holdCap)
        if (entries.length === 0) return
        var point = holdDelegate.mapToItem(root, 0, 0)
        holdMenuCap = holdCap
        holdMenuDelegate = holdDelegate
        holdMenuEntries = entries
        holdMenuCapX = point.x + holdDelegate.width / 2
        holdMenuCapTop = point.y
        holdMenuCapBottom = point.y + holdDelegate.height
        holdMenuOpen = true
        clearCapHold()
    }

    function closeHoldMenu() {
        holdMenuOpen = false
        holdMenuCap = null
        holdMenuDelegate = null
        holdMenuEntries = []
    }

    /// One menu entry, typed through the same exact-level chord the &123
    /// glyph caps send (typeCap's exact arm): the position plus
    /// levelChord's modifiers around it, one press and one release as a
    /// single click. `exact` spends latched Shift/AltGr per §2 without
    /// letting them choose the level, the configure stamp is taken at the
    /// pick, and the release lifts everything the press wrapped — the
    /// reducer owns the whole shape, nothing here re-derives it.
    function pickHoldEntry(entry) {
        var cap = holdMenuCap
        closeHoldMenu()
        if (!cap || !entry) return
        // The deep defence is applyModifierEvent's own gate; this guard
        // keeps the click sound from a pick that could not type, the same
        // rule the caps' press path keeps.
        if (!inputReady || searchMode) return
        root.keyPressed()
        applyModifierEvent({
            type: "press",
            position: cap.xkb,
            letter: isAlphabeticCap(cap),
            shift: Layout.levelChord(entry.level).shift,
            altgr: Layout.levelChord(entry.level).level3,
            // Levels 3-4 only, so never asked for; carried for parity
            // with the glyph caps' event shape.
            level5: Layout.levelChord(entry.level).level5,
            // <LVL3>, not RALT — the glyph caps' own rule (typeCap): RALT
            // is ISO_Level3_Shift only on some layouts; <LVL3> is it in
            // every group of every compiled keymap.
            level3Position: Layout.levelChord(entry.level).level3 ? "LVL3" : "",
            exact: true,
            configureStamp: session.sends
        })
        applyModifierEvent({ type: "release" })
    }

    // ---- the dwell event path (ticket 50) ----
    //
    // The chrome around Dwell.js's machine: enter/leave ride the cap's
    // hit area (the same bounds hover lights), one timer per threshold
    // crossing, and the returned action maps onto the press paths a
    // physical click takes — typeCap/triggerSpecial plus releaseKey, so
    // every chord, latch and search rule is decided by the code that
    // already owns it and a dwell press is indistinguishable from a
    // click at the socket.

    /// The pointer entered a cap's hit area. A previous rest dies here
    /// (a new enter always supersedes), then eligibility is Dwell's and
    /// the machine arms with the live facts' column — the same
    /// capHoldColumn the press-based hold reads, so the dwell menu and
    /// the hold menu cannot disagree about what a position offers.
    function dwellEnter(capData, delegate) {
        dwellReset()
        // dwellActive, not the raw setting (ticket 58): a touch finger
        // cannot hover, so the touch profile never arms a rest — the
        // profile's veto, composed in InputProfile.dwellArms.
        if (!dwellActive) return
        // The pure-dwell user's menu dismissal (ticket 50 review): the
        // standing hold menu's own dismissal routes are all clicks or
        // external folds, and a lingering rest is exactly this
        // audience's cadence — so a dwell arming anywhere else folds
        // the menu first. Pointer-only, one line, no chrome added.
        if (holdMenuOpen) closeHoldMenu()
        if (!Dwell.eligible(capData, searchMode, inputReady)) return
        var delay = Dwell.delayFor(dwellDelayMs)
        dwellState = Dwell.enter(Date.now(), delay,
            Dwell.menuDelayFor(delay), capHoldColumn(capData).length > 0)
        dwellCap = capData
        dwellDelegate = delegate
        dwellTimer.interval = delay
        dwellTimer.restart()
        dwellStartFill(delegate, delay)
    }

    /// The pointer left the cap's hit area: the rest and its pending menu
    /// arm die (the machine's leave owns that decision; the wiring only
    /// clears). A leave from a delegate that is no longer the dwelled one
    /// is a rebuild's stray signal and changes nothing.
    function dwellLeave(delegate) {
        if (dwellDelegate !== delegate) return
        dwellReset()
    }

    /// The entry arm (ticket 50, slice two): the hold menu's ENTRIES are
    /// dwell targets — a pure-dwell user opened the column menu by
    /// resting PAST the type, and needing one click to PICK breaks the
    /// click-free promise. Same machine, same delay, same quiet
    /// underline the caps draw; the fire is the entry's own click
    /// semantics (pickHoldEntry). The menu itself is never folded here —
    /// the fold-on-dwell-arm is the CAP arm's pointer-only dismissal,
    /// and this arm lives ON the menu. A rest on the padding or a gap
    /// never reaches this function at all: the hover shield (0105888)
    /// swallows it, so only the entry hit areas gained dwell. A previous
    /// rest dies first, so moving between entries re-targets — the new
    /// enter supersedes, exactly the caps' rule.
    function dwellEnterEntry(entry, delegate) {
        dwellReset()
        var delay = Dwell.delayFor(dwellDelayMs)
        var state = Dwell.enterEntry(entry, Date.now(), delay,
            dwellActive, searchMode, inputReady)
        if (!state) return
        dwellState = state
        dwellEntry = entry
        dwellDelegate = delegate
        dwellTimer.interval = delay
        dwellTimer.restart()
        dwellStartFill(delegate, delay)
    }

    /// The deadline timer fired: hand the machine the clock and map the
    /// crossing. A column cap's press re-arms the timer for the menu
    /// deadline (elapsed-from-enter, so a late delivery still waits the
    /// designed window); nothing ever re-arms for a repeat — a rest types
    /// once (Dwell.tick's own rule).
    function dwellTick() {
        if (!dwellState) return
        var now = Date.now()
        var result = Dwell.tick(dwellState, now)
        dwellState = result.state
        if (result.action === "press") {
            if (dwellState && dwellState.phase === "spent") {
                dwellTimer.interval = Dwell.nextArmMs(dwellState, now)
                dwellTimer.restart()
            }
            dwellFire()
        } else if (result.action === "menu") {
            dwellOpenMenu()
        } else if (dwellState && dwellState.phase !== "done") {
            // Ticket 55: a delivery can land BEFORE the deadline — Qt's
            // timers carry coarse-timer slack and may fire a few percent
            // EARLY (measured live: 782ms into an 800ms rest). The
            // machine correctly answers "none" below the deadline, and
            // `repeat: false` means that early fire was the timer's one
            // delivery — without this re-arm the rest stays armed
            // forever with no error, exactly the all-of-dwell-inert
            // defect the VM leg caught. Re-arm for the REMAINING time
            // against the absolute deadline (t0-anchored, so repeated
            // early deliveries converge on the crossing), covering both
            // crossings — the type deadline and the menu window alike.
            // nextArmMs owns that arithmetic (55 follow-up): it was
            // spelled twice here and in the press branch above.
            dwellTimer.interval = Dwell.nextArmMs(dwellState, now)
            dwellTimer.restart()
        }
    }

    /// The delay fired: the cap types. Readiness, search and availability
    /// are re-checked because they can drop while the pointer rests —
    /// endCapHold's rule: a press that cannot type sends nothing and
    /// sounds nothing. The release half goes to exactly the caps whose
    /// physical release sends it (capRect.types' rule, restated): a
    /// character cap's key lifts, a modifier's click is self-contained.
    function dwellFire() {
        // The entry arm first (slice two): an entry rest fires the
        // entry's own click semantics — pickHoldEntry — with the pick's
        // gate restated because readiness can drop while the pointer
        // rests. A gated entry's click returns before the pick and so
        // does its dwell: nothing is picked, nothing sounds, and the
        // menu keeps standing for the pointer's next move.
        if (dwellEntry) {
            var entry = dwellEntry
            dwellReset()
            if (!inputReady || searchMode) return
            pickHoldEntry(entry)
            return
        }
        var cap = dwellCap
        if (!cap) {
            dwellReset()
            return
        }
        if (!inputReady || searchMode || cap.unavailable === true) {
            dwellReset()
            return
        }
        if (!cap.key) {
            typeCap(cap)
            releaseKey()
            // The underline's uniform rule (§54: progress, never
            // state — it vanishes the instant the rest ends, typed or
            // not, on every character cap alike; a pinned-full line
            // through the menu window would read as state, and the
            // menu opening is its own signal). Ticket 50 review L1:
            // the fill used to linger at full width until the pointer
            // left.
            try { dwellDelegate.stopDwellFill() } catch (error) {}
            return
        }
        triggerSpecial(cap, false)
        if (Layout.positionForKeysym(cap.key)) releaseKey()
    }

    /// The second threshold: the continued rest opens ticket 37's menu,
    /// reusing openHoldMenu whole — geometry, catch area, the pick's
    /// chord. The entries are re-read from the live facts: a keymap that
    /// stopped carrying a column mid-rest ends the dwell quietly, never
    /// leaving the phantom hold a press-based open would (whose release
    /// would type on this cap's next click).
    function dwellOpenMenu() {
        var cap = dwellCap
        var delegate = dwellDelegate
        dwellReset()
        if (!cap || !delegate) return
        if (capHoldColumn(cap).length === 0) return
        holdCap = cap
        holdDelegate = delegate
        openHoldMenu()
    }

    /// One place clears a dwell: leave, a physical press superseding the
    /// rest, search arming, facts or rows rebuilding under the pointer,
    /// the panel closing, the setting turning off. The underline stops
    /// with it — the affordance IS the rest, and the rest is over.
    function dwellReset() {
        dwellState = null
        dwellCap = null
        dwellEntry = null
        var delegate = dwellDelegate
        dwellDelegate = null
        dwellTimer.stop()
        if (delegate) {
            // A delegate the row rebuild already destroyed is a wrapper
            // whose methods are gone; clearing must survive it.
            try { delegate.stopDwellFill() } catch (error) {}
        }
    }

    function dwellStartFill(delegate, delay) {
        if (!delegate) return
        try { delegate.startDwellFill(delay) } catch (error) {}
    }

    // Shift is applied as a real Shift press rather than by picking the shifted
    // character, because the compositor resolves the position through its own
    // layout. Which of Caps or Shift is doing the work follows the same rule
    // the key caps are drawn with, so what is shown is what is typed — the
    // reducer decides both, from the same `letter` and `caps` facts.
    function typeCap(capData) {
        // searchMode intercepts before anything the press would dispatch:
        // the character the cap draws — the same charUnderModifiers the label
        // pipeline uses — is the query's next character, and the helper
        // receives nothing (no tap, no down/up, no mods). Space rides this
        // arm too: its drawn character IS the separator. An empty resolution
        // (a cap that draws nothing) stays silent.
        if (root.searchMode) {
            var searchChar = root.charUnderModifiers(capData)
            // Truthiness, not !== "": a partially resolved dual cap can hand
            // back undefined, which a string signal coerces to "" and which
            // must stay silent like any other cap that draws nothing.
            if (searchChar) {
                root.keyPressed()
                root.searchInput("char", searchChar)
            }
            return
        }
        // The ten symbol/digit caps use Shift to pick the digit chord. The
        // latch already selected the layer, so the reducer receives an exact
        // chord and temporarily lifts Shift to type the digit's level 1.
        // `sk` alone: a cap either carries a resolved Shift half or it does
        // not. The old `|| capData.shiftToken` arm outlived the token caps
        // that used it, and its guard below could only ever have swallowed a
        // press in silence.
        var wantShiftLayer = !!capData.chrShift && shiftActive() && !!capData.xkbShift
        var position = wantShiftLayer ? capData.xkbShift : capData.xkb
        if (!position) return
        var level = wantShiftLayer
            ? (capData.slvl || 1)
            : (capData.baseLvl !== undefined ? capData.baseLvl : 1)
        root.keyPressed()
        applyModifierEvent({
            type: "press",
            position: position,
            letter: isAlphabeticCap(capData),
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
            level3Position: (wantShiftLayer ? capData.shiftLevel3 : capData.level3) === true
                ? "LVL3" : "",
            exact: capData.exact === true || capData.baseLvl !== undefined,
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

    function triggerSpecial(capData, doubleClick) {
        switch (capData.key) {
        case "close": dismissalAsked(); return
        // The ☺ cap (ticket 24) toggles the panel's own emoji page: open on
        // press, dismiss on a second press. No PATH probe stands in the
        // way — the page is ours and the only picker there is.
        case "emoji":
            root.emojiCapActivated()
            return
        // Not a keystroke, so no click sound, for the same reason close is
        // silent: nothing was typed.
        case "page": togglePage(); return
        case "fn":
            applyModifierEvent({ type: "fnClick" })
            rebuildRowModel()
            return
        case "caps":
            root.keyPressed()
            applyModifierEvent({ type: "capsClick" })
            return
        }
        if (Modifiers.isModifier(capData.key)) {
            // One click per physical press, and a lock is two presses, not
            // three: `doubleClick` arrives on top of the second press's own
            // click (issue 17) and would otherwise sound a third time.
            if (!doubleClick) root.keyPressed()
            applyModifierEvent({
                type: doubleClick ? "doubleClick" : "click",
                modifier: capData.key
            })
            return
        }
        // searchMode, for the caps that reach this far: BackSpace deletes,
        // the Esc cap closes the page through the panel, and every other
        // positional cap — Enter, Tab, the arrows — does nothing at all:
        // no query change, and no dispatch, so the focused client receives
        // nothing. The fixed cases and the modifiers above this line kept
        // their own paths (close and ☺ toggle the panel's surfaces, page
        // and fn and caps change only what the keys show or hold), which is
        // what lets the next letters come from a freshly switched group.
        if (root.searchMode) {
            if (capData.key === "BackSpace") {
                root.keyPressed()
                root.searchInput("backspace", "")
            } else if (capData.key === "Escape") {
                root.searchInput("escape", "")
            }
            return
        }
        var position = Layout.positionForKeysym(capData.key)
        if (!position) return
        root.keyPressed()
        applyModifierEvent({
            type: "press", position: position,
            configureStamp: session.sends
        })
    }

    /// Caps has exactly "off" and "on"; the real modifiers have "idle",
    /// "latched" and "locked" so all of their states remain distinguishable.
    function keyModifierState(capData) {
        if (capData.key === "caps") return modifierState.caps ? "on" : "off"
        if (capData.key === "fn") return modifierState.fn ? "on" : "off"
        if (!Modifiers.isModifier(capData.key)) return "idle"
        return modifierState[capData.key]
    }

    Column {
        id: grid
        anchors { bottom: parent.bottom }
        spacing: root.cellGap

        Repeater {
            model: root.rowModel
            delegate: Row { id: rowItem
                spacing: root.cellGap
                readonly property var rowModel: modelData  // row -> caps
                // `index` is the Repeater's, and the inner delegate's own
                // `index` shadows it, so the row's position is carried here.
                readonly property int rowIndex: index
                readonly property real hitTop: rowIndex === 0 ? root.edgeOutset : root.halfGap
                readonly property real hitBottom: rowIndex === root.rowModel.length - 1
                    ? root.edgeOutset : root.halfGap

                Repeater {
                    model: rowModel  // this row's caps
                    delegate: Item { id: capDelegate
                        property var capData: modelData
                        width: (capData.w || 1) * root.cellPitch - root.cellGap
                        height: root.capRowHeight
                        readonly property real hitLeft: index === 0
                            ? root.edgeOutset : root.halfGap
                        readonly property real hitRight: index === rowItem.rowModel.length - 1
                            ? root.edgeOutset : root.halfGap

                        // The dwell affordance's two handles, called only
                        // by the keyboard's dwell path (ticket 50): start
                        // grows the foot underline over the rest's delay,
                        // stop snaps it away. Methods rather than
                        // bindings because the animation must restart on
                        // every arm and die instantly on every cancel — a
                        // binding could only ever drain.
                        function startDwellFill(delay) {
                            dwellUnderline.visible = true
                            dwellFillAnim.duration = Math.max(1, delay)
                            dwellFillAnim.restart()
                        }
                        function stopDwellFill() {
                            dwellFillAnim.stop()
                            dwellUnderline.width = 0
                            dwellUnderline.visible = false
                        }

                        Rectangle {
                            id: capRect
                            // A declared spacer slot (`spacer: true` — the
                            // curated page's unfilled slots and its free
                            // row's pad) draws nothing: the page never shows
                            // a blank cap. An invisible item takes no mouse
                            // events either, so a dead slot stays dead while
                            // its neighbours' hit areas keep meeting at its
                            // midpoints.
                            visible: !capData.spacer
                            anchors { fill: parent }
                            radius: root.capCorner

                            // Three states have to be told apart at a glance
                            // (spec-v1 §5), so they differ in more than
                            // shade: latched is an accent outline over the
                            // ordinary fill, locked is filled accent. One
                            // reads as armed, the other as held down.
                            property string modState: root.keyModifierState(capData)
                            property bool latched: modState === "latched"
                            property bool locked: modState === "locked"
                            property bool toggleOn: modState === "on"
                            property bool stacked: root.isStackedPair(capData)
                            // Whether this cap types, which is the same test
                            // `onPressed` makes: a character, or a keysym with
                            // a position behind it. The modifiers and the
                            // command caps are neither. Caps acts on press;
                            // the remaining commands act on click.
                            property bool types: !capData.key
                                || !!Layout.positionForKeysym(capData.key)
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
                                || Modifiers.isModifier(capData.key)
                            property bool unavailable: capData.unavailable === true
                            property bool inputGated: !root.inputReady
                                && producesInput
                            property bool disabled: unavailable || inputGated
                            property bool isSuper: capData.key === "logo"
                            // One ink binding for every Super-mark arm
                            // (ticket 22): the cap's own state machine —
                            // disabled dims, locked/on knocks out, otherwise
                            // the plain glyph colour — tints the word, the
                            // Omarchy glyph and the drawn vectors alike.
                            readonly property color superInk: disabled ? root.textDim
                                : (locked || toggleOn) ? root.lockedText
                                : root.inkMain

                            color: disabled ? root.keyBg
                                : (locked || toggleOn) ? root.lockedFill
                                : latched ? root.latchedFill
                                : capHit.pressed ? root.pressFill
                                : capHit.containsMouse ? root.hoverFill
                                : root.keyBg
                            border.color: (latched || locked || toggleOn) ? root.theme.accent
                                : root.capEdge
                            border.width: latched ? root.latchedBorderWidth : root.keyBorderWidth

                            // ---- the Super cap's mark (ticket 22) ----
                            //
                            // One arm of the settings choice draws, chosen by
                            // the pure superMarkArm in KeyboardLayout.js; the
                            // cap's hit area, latch/chord behaviour and
                            // accessible name are the same whatever draws.
                            // The word arm is the generic label below; these
                            // three arms draw when their mark is picked. Each
                            // is wrapped in a Loader that is active only on
                            // the arm's own Super cap, so the other ~two dozen
                            // delegates instantiate nothing for them.

                            Text {
                                id: superLogo
                                // The Omarchy arm: same request as the bar
                                // launcher, and §27's gate stays attached to
                                // this arm alone — superMarkArm returns
                                // "omarchy" only when the packaged TTF is
                                // present, so Qt cannot substitute another
                                // family's U+E900 and an absent font lands on
                                // the word arm instead of a blank cap.
                                visible: !capRect.stacked && capRect.isSuper
                                    && root.superMarkArm === "omarchy"
                                anchors { centerIn: parent }
                                text: root.omarchyFontPresent ? "\ue900" : ""
                                textFormat: Text.PlainText
                                renderType: Text.NativeRendering
                                color: capRect.superInk
                                font.family: "omarchy"
                                font.pixelSize: root.superLogoSize
                                Accessible.name: "Super"
                            }

                            // The Windows arm: the four-pane 2×2 mark —
                            // square panes, one small gap — composed of
                            // plain Rectangles, the one mark needing no
                            // curves. Flat, monochrome, cap-state inked.
                            Loader {
                                active: !capRect.stacked && capRect.isSuper
                                    && root.superMarkArm === "windows"
                                anchors { centerIn: parent }
                                width: root.superLogoSize
                                height: root.superLogoSize
                                sourceComponent: Component {
                                    Item {
                                        anchors { fill: parent }
                                        Accessible.name: "Super"

                                        readonly property real pane: 0.45
                                        readonly property real offset: 0.55

                                        Rectangle {
                                            x: 0; y: 0
                                            width: parent.pane * parent.width
                                            height: parent.pane * parent.height
                                            color: capRect.superInk
                                        }
                                        Rectangle {
                                            x: parent.offset * parent.width; y: 0
                                            width: parent.pane * parent.width
                                            height: parent.pane * parent.height
                                            color: capRect.superInk
                                        }
                                        Rectangle {
                                            x: 0; y: parent.offset * parent.height
                                            width: parent.pane * parent.width
                                            height: parent.pane * parent.height
                                            color: capRect.superInk
                                        }
                                        Rectangle {
                                            x: parent.offset * parent.width
                                            y: parent.offset * parent.height
                                            width: parent.pane * parent.width
                                            height: parent.pane * parent.height
                                            color: capRect.superInk
                                        }
                                    }
                                }
                            }

                            // The macOS and Penguin arms: inline vectors
                            // drawn with QtQuick.Shapes — monochrome, no
                            // vendored raster, no font, no network. Paths
                            // are laid out in a fixed 100×100 box and
                            // scaled to the cap, so the same coordinates
                            // read the same at every preset. The module
                            // import is proven loadable by the host Qt
                            // 6 runtime offscreen (the run-tests.sh runtime
                            // instantiates a Shape with ShapePath, PathCubic
                            // and OddEvenFill cleanly); rendering shape and
                            // proportion stays for the owner's eyes, since
                            // the offscreen suites cannot judge a silhouette.
                            Loader {
                                id: commandMarkLoader
                                active: !capRect.stacked && capRect.isSuper
                                    && root.superMarkArm === "macos"
                                anchors { centerIn: parent }
                                width: root.superLogoSize
                                height: root.superLogoSize
                                sourceComponent: Component {
                                    Shape {
                                        anchors { fill: parent }
                                        Accessible.name: "Super"
                                        // CurveRenderer antialiases stroked
                                        // curves itself; GeometryRenderer
                                        // aliased the loops at key size (the
                                        // owner's pixelated-⌘ report), and an
                                        // MSAA layer broke the mark entirely.
                                        preferredRendererType: Shape.CurveRenderer

                                        transform: Scale {
                                            xScale: commandMarkLoader.width / 100
                                            yScale: commandMarkLoader.height / 100
                                        }

                                        // The macOS command mark (⌘): the
                                        // looped square as one stroked
                                        // outline — four straight sides and
                                        // four quarter-circle loops, RoundCap
                                        // and RoundJoin so the corners read
                                        // round, the fill transparent because
                                        // the stroke IS the mark. Coordinates
                                        // lifted verbatim from the owner
                                        // render the choice was made on.
                                        ShapePath {
                                            strokeColor: capRect.superInk
                                            fillColor: "transparent"
                                            strokeWidth: 8
                                            capStyle: ShapePath.RoundCap
                                            joinStyle: ShapePath.RoundJoin
                                            startX: 62.5; startY: 25
                                            PathLine { x: 62.5; y: 75 }
                                            PathArc {
                                                x: 75; y: 62.5
                                                radiusX: 12.5; radiusY: 12.5
                                                useLargeArc: true
                                                direction: PathArc.Counterclockwise
                                            }
                                            PathLine { x: 25; y: 62.5 }
                                            PathArc {
                                                x: 37.5; y: 75
                                                radiusX: 12.5; radiusY: 12.5
                                                useLargeArc: true
                                                direction: PathArc.Counterclockwise
                                            }
                                            PathLine { x: 37.5; y: 25 }
                                            PathArc {
                                                x: 25; y: 37.5
                                                radiusX: 12.5; radiusY: 12.5
                                                useLargeArc: true
                                                direction: PathArc.Counterclockwise
                                            }
                                            PathLine { x: 75; y: 37.5 }
                                            PathArc {
                                                x: 62.5; y: 25
                                                radiusX: 12.5; radiusY: 12.5
                                                useLargeArc: true
                                                direction: PathArc.Counterclockwise
                                            }
                                        }
                                    }
                                }
                            }

                            // Exact user-supplied monochrome Tux. Its SVG owns
                            // fixed black/white paint, including the white
                            // backing that makes the source path's transparent
                            // cutouts opaque and outlines it on dark caps.
                            Image {
                                id: penguinMark
                                readonly property bool selected: !capRect.stacked
                                    && capRect.isSuper
                                    && root.superMarkArm === "penguin"
                                visible: selected && status === Image.Ready
                                anchors { centerIn: parent }
                                width: root.superLogoSize
                                height: root.superLogoSize
                                source: selected ? "assets/monochrome-tux.svg" : ""
                                sourceSize: Qt.size(Math.max(1, Math.ceil(width)),
                                    Math.max(1, Math.ceil(height)))
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                mipmap: true
                                Accessible.name: "Super"
                            }

                            Text {
                                visible: !capRect.stacked
                                    && (!capRect.isSuper
                                        || root.superMarkArm === "word"
                                        || (root.superMarkArm === "penguin"
                                            && penguinMark.status !== Image.Ready))
                                anchors { centerIn: parent }
                                text: capData.label
                                    ? capData.label
                                    : root.charUnderModifiers(capData)
                                color: capRect.disabled ? root.textDim
                                    : (capRect.locked || capRect.toggleOn)
                                    ? root.lockedText : root.inkMain
                                font.family: root.glyphTypeface
                                font.pixelSize: root.capGlyphSize
                            }

                            // Stacked dual symbols: shifted symbol on top
                            // (dim by default), base symbol on the bottom
                            // (bright by default) — swapping emphasis when
                            // Shift is held, mirroring `.key.dual.shift-active`.
                            Text {
                                visible: capRect.stacked
                                // The `|| ""` guards the symbols-page dual
                                // caps, whose levels come from the keymap:
                                // a level that did not resolve is a §11 miss
                                // and an empty slot, never the string
                                // "undefined" drawn on a cap.
                                text: capData.chrShift || ""
                                anchors { top: parent.top }
                                anchors.topMargin: root.cellGap
                                anchors { horizontalCenter: parent.horizontalCenter }
                                color: capRect.disabled ? root.textDim
                                    : root.symbolLayerHeld() ? root.textHighlightColor : root.textDim
                                font.bold: root.symbolLayerHeld()
                                font.family: root.glyphTypeface
                                font.pixelSize: root.capGlyphSmall
                            }

                            Text {
                                visible: capRect.stacked
                                text: capData.chr || ""
                                anchors { bottom: parent.bottom }
                                anchors.bottomMargin: root.cellGap
                                anchors { horizontalCenter: parent.horizontalCenter }
                                color: capRect.disabled ? root.textDim
                                    : root.symbolLayerHeld() ? root.textDim : root.inkMain
                                font.family: root.glyphTypeface
                                font.pixelSize: root.capGlyphSize
                            }

                            // The hold-variant marker (the owner's
                            // 2026-09-14 call): a very light dot in the
                            // bottom-right corner of exactly the caps a
                            // hold would open a column menu for — telling
                            // what is worth holding without drawing the
                            // variants themselves (which would be
                            // clutter). It reads marksVariant on the same
                            // column facts the menu reads, so the dot and
                            // the menu cannot disagree; it is static
                            // keymap information, unmoved by gating or
                            // search, and it dims with a disabled cap
                            // rather than shouting over one.
                            Rectangle {
                                visible: HoldColumn.marksVariant(capData,
                                    root.capHoldColumn(capData))
                                width: Math.max(3, Math.round(root.cellGap * 0.55))
                                height: width
                                radius: width / 2
                                anchors {
                                    right: parent.right
                                    rightMargin: root.cellGap * 0.6
                                    bottom: parent.bottom
                                    bottomMargin: root.cellGap * 0.6
                                }
                                color: root.textDim
                                opacity: capRect.disabled ? 0.3 : 0.8
                            }

                            // The dwell progress affordance (ticket 50):
                            // a thin underline growing along the cap's
                            // foot while the rest counts toward the type.
                            // The corner dot's own register (ticket 45) —
                            // textDim ink, a hint of opacity, never an
                            // accent fill and never a dimmed glyph: this
                            // is PROGRESS, not state, so it exists only
                            // while a rest is live, grows linearly to the
                            // deadline, and vanishes the moment the rest
                            // ends by typing, cancelling or leaving. A
                            // second "unavailable/dim" reading is exactly
                            // what it must never become.
                            Rectangle {
                                id: dwellUnderline
                                visible: false
                                width: 0
                                height: Math.max(2,
                                    Math.round(root.cellGap * 0.45))
                                radius: height / 2
                                anchors {
                                    horizontalCenter: parent.horizontalCenter
                                    bottom: parent.bottom
                                    bottomMargin: Math.round(root.cellGap * 0.35)
                                }
                                color: root.textDim
                                opacity: 0.8
                            }
                            NumberAnimation {
                                id: dwellFillAnim
                                target: dwellUnderline
                                property: "width"
                                from: 0
                                to: capRect.width - root.cellGap
                                easing.type: Easing.Linear
                            }

                            MouseArea {
                                id: capHit
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
                                anchors { fill: parent }
                                anchors.leftMargin: -capDelegate.hitLeft
                                anchors.rightMargin: -capDelegate.hitRight
                                anchors.topMargin: -rowItem.hitTop
                                anchors.bottomMargin: -rowItem.hitBottom
                                hoverEnabled: true
                                // Ticket 58: in the touch profile our own
                                // surfaces may not steal a sliding finger
                                // from a pressed cap — the slide-off cancel
                                // contract needs the release delivered HERE.
                                // Nothing on today's grid steals (no
                                // Flickable parents the caps); the flag is
                                // the guarantee the profile pins, and it is
                                // deliberately NOT set on the flickable
                                // surfaces (the emoji grid, the settings
                                // scroll) where a slide IS the scroll.
                                preventStealing: root.profileAfford.preventStealing

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
                                onPressed: (mouse) => {
                                    // Ticket 58: the press reports its
                                    // source FIRST, so the very touch that
                                    // teaches auto already answers as touch
                                    // — this press defers, its release
                                    // types, and no phantom character lands
                                    // on the way the world flipped. A real
                                    // mouse button observes nothing.
                                    root.pointerSourceObserved(mouse.source)
                                    // A physical press supersedes any rest:
                                    // dwell and click never double-type, and
                                    // the press keeps exactly the semantics
                                    // it has today (in dwell mode no cap
                                    // defers — Dwell.holdDefers).
                                    root.dwellReset()
                                    // Not-ready gating (spec-v1.1 §6) and the
                                    // unavailable mark (§3) are properties of
                                    // the cap, so the whole press path —
                                    // including the click sound and the
                                    // pressed fill — never starts for a cap
                                    // that could not type.
                                    if (capRect.disabled) return
                                    if (!capData.key) {
                                        // Ticket 37: a character cap whose
                                        // position carries extra levels types
                                        // on RELEASE — the press arms a hold
                                        // and sends nothing, so the threshold
                                        // can open the column menu with no
                                        // stray character and no repeat. The
                                        // defer decision is HoldColumn's, on
                                        // the live facts.
                                        if (root.capDefersHold(capData)) {
                                            root.beginCapHold(capData,
                                                capDelegate)
                                            return
                                        }
                                        root.typeCap(capData)
                                        return
                                    }
                                    if (Layout.positionForKeysym(capData.key)
                                            || Modifiers.isModifier(capData.key)
                                            || capData.key === "caps"
                                            || capData.key === "fn"
                                            || capData.key === "page"
                                            || capData.key === "emoji") {
                                        root.triggerSpecial(capData, false)
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
                                // The release of a deferred hold comes first
                                // (ticket 37): before the threshold it sends
                                // the press+release pair; after the threshold
                                // it is the hold's own and types nothing,
                                // leaving the menu standing for its pick.
                                onReleased: (mouse) => {
                                    // The slide-off half of ticket 58's
                                    // release-typing: in the touch profile a
                                    // lift that left the cap first CANCELS
                                    // the hold (never types) — capHit still
                                    // holds the grab, so the release arrives
                                    // here wherever the finger wandered, and
                                    // contains() is the honest inside test.
                                    // The mouse profile passes undefined:
                                    // byte-today, a deferred hold's release
                                    // types wherever the button comes up.
                                    if (root.endCapHold(capDelegate,
                                            root.profileAfford.slideOffCancels
                                                ? capHit.contains(mouse)
                                                : undefined))
                                        return
                                    if (capRect.types) root.releaseKey()
                                    // A release with the pointer still on
                                    // the cap re-arms the dwell (ticket 50):
                                    // a click-and-rest user — or a click
                                    // that ends where it began, as they all
                                    // do — must not need to leave the key
                                    // and come back before resting works.
                                    // dwellActive, not dwellEnabled: a
                                    // touch profile never arms a rest even
                                    // with the setting left on.
                                    if (root.dwellActive && capHit.containsMouse)
                                        root.dwellEnter(capData, capDelegate)
                                }
                                // A deferred hold that loses its grab types
                                // NOTHING — no press line was ever sent, so
                                // there is no stray character and nothing to
                                // lift, strictly better than today. A hold
                                // that had opened its menu folds it here too.
                                onCanceled: {
                                    root.dwellReset()
                                    if (root.cancelCapHold(capDelegate)) return
                                    if (capRect.types) root.releaseKey()
                                }

                                // The dwell path's enter/leave (ticket 50):
                                // the hit area's own bounds — the same ones
                                // hover lights — decide when a rest begins
                                // and ends; cancellation is on leave, never
                                // on motion inside the cap (Dwell.move's
                                // rule, for the trembling hand dwell is for).
                                onEntered: root.dwellEnter(capData, capDelegate)
                                onExited: root.dwellLeave(capDelegate)

                                // What is left on the click is only the
                                // command cap that would tear something out
                                // from under the button still held — close.
                                // It is deliberately not swept into the press
                                // path with the modifiers, and it pays Qt's
                                // second-press suppression (issue 13) for it,
                                // which is survivable because nobody
                                // double-clicks Close to close twice.
                                //
                                // The page control (spec-v1.1 §3) and the
                                // emoji cap (ticket 24) are no longer among
                                // them: waiting for `clicked` lost every
                                // second press of a rapid pair to the same
                                // suppression — fatal now the emoji cap
                                // toggles a page, whose dismiss IS the second
                                // press. Neither tears anything out from
                                // under the pointer — the grid the button
                                // sits on does not rebuild — so both act on
                                // the way down, one press per press.
                                onClicked: {
                                    if (!capData.key) return
                                    if (Layout.positionForKeysym(capData.key)) return
                                    if (Modifiers.isModifier(capData.key)) return
                                    if (capData.key === "caps") return
                                    if (capData.key === "fn") return
                                    if (capData.key === "page") return
                                    if (capData.key === "emoji") return
                                    root.triggerSpecial(capData, false)
                                }

                                onDoubleClicked: (mouse) => {
                                    if (!capData.key || !Modifiers.isModifier(capData.key)) return
                                    // A locked upgrade is protocol-bearing
                                    // like any latch — refused while gated.
                                    if (capRect.inputGated) return
                                    root.triggerSpecial(capData, true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Timer {
        id: capHoldTimer
        // The one timer ticket 37 adds, and it repeats nothing: it fires
        // once per hold to open the column menu. Key repeat stays the
        // compositor's own (spec-v1 §6) — and a deferred cap, having sent
        // no press line at threshold, has no repeat to manage at all.
        interval: HoldColumn.HOLD_THRESHOLD_MS
        repeat: false
        onTriggered: root.openHoldMenu()
    }

    Timer {
        id: dwellTimer
        // The dwell path's one timer (ticket 50), and like ticket 37's it
        // repeats nothing by itself: it is deadline-driven — the delay,
        // then the menu window for a column cap — and Dwell.tick decides
        // what a crossing means. A crossing may take several fires: Qt's
        // coarse slack fires ~2% early and dwellTick re-arms for the
        // remaining time against the absolute deadline (ticket 55 — the
        // first cut assumed one interval per crossing and deadlocked
        // armed forever on the early fire). A cleared dwell never fires:
        // the machine's dead state answers "none" whatever a stray
        // trigger delivers.
        interval: 800
        repeat: false
        onTriggered: root.dwellTick()
    }

    // ---- the hold column's menu (ticket 37) ----
    //
    // Card-local, like ticket 35's chooser (commit 86a57b7's lesson): the
    // panel window's input mask is the card rect, so the menu lives
    // INSIDE the keyboard's own bounds — above it in z, over the held
    // cap's column. The catch area underneath eats every press that is
    // not on the menu itself: one click anywhere else dismisses without
    // typing, and no cap underneath can start a press of its own while
    // the menu stands.
    MouseArea {
        anchors { fill: parent }
        enabled: root.holdMenuOpen
        z: 4
        onClicked: root.closeHoldMenu()
    }

    Rectangle {
        id: holdMenu

        visible: root.holdMenuOpen
        z: 5

        // Above the held cap when the column fits there, below it when it
        // does not (a row-0 hold has no room above), and never outside
        // the keyboard's rect — that is what keeps the menu inside the
        // card, i.e. inside the input mask, docked or floating. Anchors
        // are baked at open (openHoldMenu); like the language chooser,
        // the menu does not follow a card dragged under it.
        readonly property real aboveY: root.holdMenuCapTop - height - root.cellGap
        readonly property real belowY: root.holdMenuCapBottom + root.cellGap
        x: Math.max(root.cellGap,
            Math.min(root.holdMenuCapX - width / 2,
                parent.width - width - root.cellGap))
        y: Math.max(root.cellGap,
            Math.min(aboveY >= root.cellGap ? aboveY : belowY,
                parent.height - height - root.cellGap))
        width: menuList.childrenRect.width + root.cellGap * 2
        height: menuList.childrenRect.height + root.cellGap * 2
        radius: root.capCorner
        color: root.theme.popupsBackground
        border.color: root.capEdge
        // The cap edge's own width, unqualified like the tokens the cap
        // delegates read — and not the upstream sketch's border line.
        border.width: keyBorderWidth

        // The hover shield (ticket 50 review): the menu's padding and
        // the gaps between entries accept HOVER, not just presses, so a
        // resting pointer cannot fall through onto the caps hidden
        // underneath — dwell was the first hover-action and weaponized
        // that fall-through, typing characters the user could not see.
        // The entries' own hit areas sit above this shield (declared
        // later inside the Column).
        MouseArea {
            anchors { fill: parent }
            hoverEnabled: true
            // Swallow hover; a press on the padding still closes (the
            // catch area's everywhere-outside contract, kept local).
            onClicked: root.closeHoldMenu()
        }

        Column {
            id: menuList
            anchors {
                top: parent.top
                topMargin: root.cellGap
                horizontalCenter: parent.horizontalCenter
            }
            spacing: root.cellGap / 2

            Repeater {
                model: root.holdMenuEntries

                Rectangle {
                    id: entryCard
                    property var entry: modelData
                    // The same disabled treatment the caps keep: an entry
                    // that could not type draws dim and refuses its click,
                    // and no click sound plays for it.
                    readonly property bool gated: !root.inputReady
                    width: root.capRowHeight
                    height: Math.round(root.capRowHeight * 0.8)
                    radius: root.capCorner
                    color: entryHit.containsMouse && !gated
                        ? root.hoverFill : "transparent"

                    // The dwell affordance's two handles, the caps' own
                    // (ticket 50, slice two): start grows the foot
                    // underline over the rest's delay, stop snaps it
                    // away — methods rather than bindings for the same
                    // reason the caps' are (restart on every arm, die
                    // instantly on every cancel).
                    function startDwellFill(delay) {
                        entryDwellUnderline.visible = true
                        entryDwellFillAnim.duration = Math.max(1, delay)
                        entryDwellFillAnim.restart()
                    }
                    function stopDwellFill() {
                        entryDwellFillAnim.stop()
                        entryDwellUnderline.width = 0
                        entryDwellUnderline.visible = false
                    }

                    Text {
                        anchors.centerIn: parent
                        text: entry.text
                        color: gated ? root.textDim : root.inkMain
                        font.family: root.glyphTypeface
                        font.pixelSize: root.capGlyphSize
                    }

                    // The dwell progress affordance (ticket 50, slice
                    // two): the caps' own underline in the caps' own
                    // register — textDim ink, a hint of opacity, never
                    // an accent fill — because it is the same PROGRESS
                    // the caps promise: it exists only while a rest is
                    // live and vanishes the instant the rest ends,
                    // picked, cancelled or left.
                    Rectangle {
                        id: entryDwellUnderline
                        visible: false
                        width: 0
                        height: Math.max(2,
                            Math.round(root.cellGap * 0.45))
                        radius: height / 2
                        anchors {
                            horizontalCenter: parent.horizontalCenter
                            bottom: parent.bottom
                            bottomMargin: Math.round(root.cellGap * 0.35)
                        }
                        color: root.textDim
                        opacity: 0.8
                    }
                    NumberAnimation {
                        id: entryDwellFillAnim
                        target: entryDwellUnderline
                        property: "width"
                        from: 0
                        to: entryCard.width - root.cellGap
                        easing.type: Easing.Linear
                    }

                    MouseArea {
                        id: entryHit
                        anchors { fill: parent }
                        hoverEnabled: true
                        Accessible.role: Accessible.Button
                        Accessible.name: entry.text
                        // A physical press supersedes the rest (the caps'
                        // own rule): dwell and click never double-pick.
                        // The click path itself is unchanged — a click
                        // still picks instantly, gate first.
                        onPressed: root.dwellReset()
                        onCanceled: root.dwellReset()
                        // The dwell path's entry arm (ticket 50, slice
                        // two): the hit area's own bounds decide the
                        // rest; moving between entries re-targets (the
                        // enter supersedes), the gap crossing is the
                        // shield's, and a leave cancels — the machine's
                        // rules, entry edition.
                        onEntered: root.dwellEnterEntry(entry, entryCard)
                        onExited: root.dwellLeave(entryCard)
                        onClicked: {
                            if (gated) return
                            root.pickHoldEntry(entry)
                        }
                    }
                }
            }
        }
    }
}
