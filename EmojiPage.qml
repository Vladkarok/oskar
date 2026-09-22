import QtQuick
import QtQuick.Controls
import qs.Commons
import "EmojiPage.js" as EmojiGrid
import "UiStrings.js" as UiStrings

// The panel's own emoji page (ticket 24). Lives on the settings overlay
// window beside the settings card and rides the same mechanism
// (spec-v1.1 §5): the panel places it at leftover centre through
// SettingsPlacement, clamps it inside the leftover strip, and the keyboard
// band is never part of either — the keys stay on screen and clickable
// underneath, which is the point. (With `emoji_drag` on — §103 — the
// page grows a drag strip, moves freely and MAY cover the band; the
// clamp is the visible overlay, not the leftover.) Grid cells size from tokens and the
// keyboard's uiScale; whatever content does not fit scrolls inside the page.
//
// The keyboard's own caps feed the query while the page stands — searchMode
// routes them here before anything reaches the daemon — and the query
// drives the catalogue's ranked search across every group; an empty query
// shows the active group. Choosing an entry asks the panel to deliver it;
// this page is the only picker (the external-app machinery is history,
// decisions §24).
Rectangle {
    id: emojiRoot

    visible: false

    // The panel's live Theme facade — every colour, font and spacing here
    // comes from it and from nowhere else (spec-v1 §8).
    property var tokens
    property string pageSize: "medium"
    property var usageRecords: []
    property string skinTone: ""
    property bool tonePickerOpen: false

    // Overlay size the page may occupy. Placement (leftover centre) is
    // applied by the panel as x/y; this only feeds the clamp below.
    property real hostWidth: 0
    property real hostHeight: 0

    // The free-drag affordance (the emoji-drag ticket), wired from the
    // panel's emoji_drag setting. Off (the default) means no strip, no
    // drag, exactly the page that shipped; on grows a drag strip along
    // the top edge, above the search header, wearing the keyboard
    // card's own three-state line (DragLine.qml — parity by
    // construction).
    property bool dragEnabled: false
    // The window the page may be dragged in ({w,h} — the settings
    // layer's own size, not the leftover: free placement may cover the
    // keyboard band). The strip's MouseArea clamps the drag to it.
    // The FULL box shape {x, y, w, h} — the placement module's validBox
    // refuses a bounds without x/y (§104's poison: clampedTopLeft
    // answered null and the settle threw). The drag clamp reads w/h;
    // both consumers take the one object.
    property var dragBounds: null
    // Whether a strip drag is live. The panel's placement guard reads
    // it: a held drag owns the placement, the floating card's own rule.
    readonly property bool dragActive: stripDrag.drag.active
    // A free drag ended — release, or the compositor took the gesture
    // away mid-drag and wherever the hand left the page is still worth
    // keeping (the card's onCanceled reasoning). The panel persists the
    // page's centre.
    signal dragSettled()

    // The search text the on-screen keys build (Keyboard.searchMode routes
    // them here). Cleared on a fresh open — a stale filter must not greet
    // the next open the way a stale hex draft must not (the card's own
    // rule). A blank string is no query: the group slice shows, and search
    // is not asked (its empty answer is for found-nothing, not not-searching).
    property string query: ""
    // Ticket 29: whether the keys feed the search. Armed when the page
    // opens and when the search field is clicked (2026-09-13: a click is
    // ALWAYS an arm — the old toggle handed the keys to the app beneath
    // the owner's pointer the moment he clicked the field to focus it);
    // disarmed when another client takes the pointer's focus (the panel
    // watches Hyprland), after a delivered pick, and by Escape — the Esc
    // cap's or, since ticket 42, a physical one.
    property bool searchArmed: true
    // The active xkb layout code, wired from the panel: the placeholder
    // word speaks the language the owner is typing in (Пошук/Поиск/
    // Search — UiStrings.tr("emoji.searchPlaceholder", emojiRoot.uiLang)).
    property string layoutCode: ""
    // The effective profile's hover-tooltip rule (ticket 62), wired from
    // the panel: in touch, possibly-synthesized hover never names
    // anything — the chrome rule, mirrored for the page's tooltips.
    property bool tooltipHoverShows: true
    // The panel's resolved UI language (ticket 52: override over layout):
    // every word of the page's chrome — placeholder included — follows
    // it, so a pinned choice moves the placeholder with the rest.
    property string uiLang: "en"
    // Panel-local tab state, never persisted; defaults to the first group.
    property string activeGroup: "__usage__"
    // Ticket 34: the usage category renders this snapshot of the records,
    // not the live store — refreshed on open and on re-entry into the
    // usage group only, so repeated picks never move a tile under the
    // pointer. A plain copy with no binding on usageRecords; the store
    // itself stays live (decisions §44).
    property var usageSnapshotRecords: []
    readonly property var usageRecordSections: EmojiGrid.usageSections(
        usageSnapshotRecords, gridColumnCount)
    readonly property var usageSections: ({
        frequent: EmojiGrid.recordsToEntries(usageRecordSections.frequent,
            EmojiGrid.allEntries()),
        recent: EmojiGrid.recordsToEntries(usageRecordSections.recent,
            EmojiGrid.allEntries())
    })

    // A blank query — spaces included, since a lone separator is not a term
    // — leaves the group slice in force.
    readonly property bool searching: query.trim() !== ""
    // The ranked search's cap: rows' worth of a page, so a broad term hands
    // the model a bounded set while the grid scrolls what there is.
    readonly property int searchRows: 8
    readonly property int searchLimit: Math.max(1, gridColumnCount) * searchRows

    // Step 4's seam: a cell press names its entry; the panel delivers.
    signal emojiChosen(var entry, bool applyTone)
    signal skinToneChosen(string tone)
    signal dismissed()
    // Ticket 42: one routed PHYSICAL key event, in the same action
    // vocabulary Keyboard.searchInput speaks ("char" with event.text,
    // "backspace", "escape"). The panel applies it with the very rule the
    // caps' input uses, so Escape's disarm has one definition.
    signal physicalSearchInput(string action, string text)
    // Ticket 58: the page's presses report their pointer source to the
    // panel's input-profile observation — a touch on the emoji page teaches
    // auto exactly a touch on the caps does.
    signal pointerSourceObserved(var source)

    // One intercepted keyboard cap, applied to the standing query. The
    // keyboard names the action ("char" with the character it drew,
    // "backspace", "space"); the pure rule is EmojiGrid's.
    function applySearchKey(action, text) {
        emojiRoot.query = EmojiGrid.nextQuery(emojiRoot.query, action, text)
    }

    // The paste chip's panel-local target while the page is open (R2): the
    // search is the active input — every key types into it — so a paste
    // appends what the clipboard served, collapsed and bounded by the pure
    // rule (EmojiGrid.searchPasteText): the query is typed text, not
    // whatever bytes the clipboard holds.
    function pasteIntoSearch(text) {
        var inserted = EmojiGrid.searchPasteText(text, 64)
        if (inserted === "") return
        emojiRoot.query = EmojiGrid.nextQuery(emojiRoot.query, "char", inserted)
    }

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus()
            emojiRoot.query = ""
            emojiRoot.tonePickerOpen = false
            emojiRoot.searchArmed = true
            emojiRoot.activeGroup = emojiRoot.usageRecords.length > 0
                ? "__usage__" : EmojiGrid.allGroups()[0]
            emojiRoot.usageSnapshotRecords = EmojiGrid.usageViewOnOpen(
                emojiRoot.usageRecords)
            // Ticket 42: the page opens armed, so the key scope takes the
            // scene's focus at open — the last assignment wins, and it
            // must be the scope, not this Rectangle.
            searchKeyScope.forceActiveFocus()
        }
    }

    // Ticket 42: the scope holds the scene's focus exactly while the
    // search is armed. Re-arm (a field click) re-focuses it; every disarm
    // — the focus watcher, a delivered pick, the Esc caps, physical
    // Escape — hands it back, and the panel's keyboardFocus binding drops
    // the surface to None in the same breath.
    onSearchArmedChanged: {
        if (searchArmed)
            searchKeyScope.forceActiveFocus()
        else
            searchKeyScope.focus = false
    }

    // Ticket 34's second refresh point: re-entry into the usage category
    // re-snapshots the store's accumulated picks; leaving it keeps the
    // standing view. Only entry changes the snapshot — picks while the
    // usage category shows re-order nothing.
    onActiveGroupChanged: {
        emojiRoot.usageSnapshotRecords = EmojiGrid.usageViewOnGroupChange(
            emojiRoot.activeGroup, emojiRoot.usageRecords,
            emojiRoot.usageSnapshotRecords)
    }

    // Escape's two meanings now both live (ticket 42): while the surface
    // holds keyboard focus and the search is armed, the key scope routes
    // Escape to the panel — clear + disarm + release, the same rule the
    // Esc cap runs; disarmed, it dismisses the page, as the Esc cap's
    // second press does. With no item focused (disarmed, surface already
    // released) nothing here fires at all.
    Keys.onEscapePressed: emojiRoot.dismissed()

    // The focusable target physical typing lands on while the search is
    // armed (ticket 42). Nothing visual, nothing clickable: the drawn
    // field above stays the single visual truth, and no TextInput exists
    // to grab or pre-edit. The routing itself is EmojiGrid.searchKeyAction
    // — this handler only gates on the arm and passes the named action
    // and the event's text through. Disarmed, nothing routes: the surface
    // may hold compositor focus for a few commits before the panel's
    // None binding lands, and keystrokes in that transient window are
    // EATEN here, not forwarded — the compositor has no other focused
    // surface to hand them to yet. Transient and bounded by the disarm
    // round trip; the settled state is what the VM leg asserts.
    FocusScope {
        id: searchKeyScope
        width: 0
        height: 0

        Keys.onPressed: function (event) {
            var action = EmojiGrid.searchKeyAction(event)
            if (action === "") return
            event.accepted = true
            if (action === "escape") {
                if (emojiRoot.searchArmed)
                    emojiRoot.physicalSearchInput("escape", "")
                else
                    emojiRoot.dismissed()
                return
            }
            if (!emojiRoot.searchArmed) return
            emojiRoot.physicalSearchInput(action, event.text)
        }
    }

    // ---- geometry ----
    //
    // Width and height are natural-by-content, clamped to the leftover the
    // host hands in (the popover's own shape). The grid is the flexible
    // part: it gets whatever the clamped page leaves after header and tabs,
    // and scrolls the rest.

    readonly property real pageMargin: tokens.space(10)
    readonly property real contentSpacing: tokens.space(7)
    readonly property real gridGap: tokens.space(4)
    // The drag strip's height — a comfortable grab band, its share of
    // the natural height and the column's spacing counted only while
    // the strip stands, so an off setting leaves today's arithmetic
    // byte-for-byte.
    readonly property real stripHeight: tokens.space(20)
    // Key-sized cells, independent from the keyboard's own M/L/XL scale:
    // this page's preset changes viewport capacity, not tile or key size.
    readonly property real cellSize: Math.round(tokens.space(42))
    readonly property var requestedCapacity: EmojiGrid.pageCapacity(pageSize)
    readonly property int naturalColumns: requestedCapacity.columns
    readonly property real naturalPageWidth: pageMargin * 2
        + naturalColumns * cellSize + (naturalColumns - 1) * gridGap
    readonly property real maxPageWidth: hostWidth > 0
        ? Math.max(0, hostWidth - tokens.space(6) * 2) : naturalPageWidth
    width: Math.min(naturalPageWidth, maxPageWidth)
    // Columns the clamped width actually holds — never fewer than one, so a
    // narrow output narrows the grid instead of spilling cells past the edge.
    readonly property int gridColumnCount: EmojiGrid.columnsFor(
        width - pageMargin * 2, cellSize, gridGap, naturalColumns)

    readonly property real gridRowsWanted: requestedCapacity.rows
    readonly property real usageChromeHeight: EmojiGrid.usageChromeHeight(
        !searching && activeGroup === "__usage__"
            && usageSections.frequent.length > 0,
        tokens.space(18), tokens.space(5), gridGap)
    readonly property real gridIdealHeight:
        gridRowsWanted * (cellSize + gridGap) - gridGap + usageChromeHeight
    readonly property real naturalPageHeight: pageMargin * 2 + headerRow.height
        + 1 + tabsFlow.height + gridIdealHeight + contentSpacing * 3
        + (dragEnabled ? stripHeight + contentSpacing : 0)
    readonly property real maxPageHeight: hostHeight > 0
        ? Math.max(0, hostHeight - tokens.space(6) * 2) : tokens.space(120)
    height: Math.min(naturalPageHeight, maxPageHeight)

    // The card's own panel-radius token — an override on panelRadius is
    // honoured here exactly as on the keyboard and the popover.
    radius: tokens.panelRadius
    // One step distinct from the card beneath.
    color: tokens.tintTowardForeground(tokens.panelBackground, tokens.hoverFillAlpha)
    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
    border.width: tokens.normalBorderWidth
    clip: true

    // The page's own background accepts clicks: cells, tabs and gaps are
    // INSIDE the page, so a press on them is never an outside click — the
    // dismiss area under this surface only sees presses that actually left
    // the page (the popover's own rule).
    MouseArea {
        anchors.fill: parent
        hoverEnabled: false
        onClicked: emojiRoot.tonePickerOpen = false
    }

    Column {
        id: contentColumn
        anchors.fill: parent
        anchors.margins: emojiRoot.pageMargin
        spacing: emojiRoot.contentSpacing

        // ---- the free-drag strip (the emoji-drag ticket) ----
        //
        // The keyboard card's own drag grammar wearing a new host: the
        // shared DragLine along the page's top edge, ABOVE the search
        // header. The strip consumes its own press — a drag is not a
        // click into the field, so the armed search underneath stays
        // exactly as armed as it was — and the press joins the
        // input-profile observation like every other surface the panel
        // draws. The clamp is dragBounds (the whole layer), not the
        // leftover: free placement may cover the keyboard band. The
        // release hands the placement to the panel, which remembers the
        // page's centre.
        Item {
            id: dragStrip
            width: parent.width
            height: emojiRoot.stripHeight
            visible: emojiRoot.dragEnabled

            DragLine {
                tokens: emojiRoot.tokens
                grabbed: stripDrag.pressed
                carried: stripDrag.drag.active
                hovered: stripDrag.containsMouse
                edgeGap: tokens.space(2)
                shortenBy: tokens.space(6)
                liftBy: 1
            }

            MouseArea {
                id: stripDrag
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeAllCursor
                drag.target: emojiRoot
                drag.axis: Drag.XAndYAxis
                drag.minimumX: 0
                drag.maximumX: emojiRoot.dragBounds
                    ? Math.max(0, emojiRoot.dragBounds.w - emojiRoot.width) : 0
                drag.minimumY: 0
                drag.maximumY: emojiRoot.dragBounds
                    ? Math.max(0, emojiRoot.dragBounds.h - emojiRoot.height) : 0
                onPressed: function (mouse) {
                    emojiRoot.pointerSourceObserved(mouse.source)
                }
                onReleased: emojiRoot.dragSettled()
                onCanceled: emojiRoot.dragSettled()
                HoverTooltip {
                    text: UiStrings.tr("emoji.dragStrip", emojiRoot.uiLang)
                    hovered: stripDrag.containsMouse
                        && emojiRoot.tooltipHoverShows
                }
            }
        }

        // ---- header: the search the keys type ----
        //
        // A field and its clear affordance. The field shows what was
        // typed — case included; the ranked search lowercases its own
        // side (§37).
        Item {
            id: headerRow
            width: parent.width
            height: tokens.space(28)

            Rectangle {
                id: searchField
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    bottom: parent.bottom
                }
                radius: tokens.cornerRadius
                color: Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                // Ticket 29: the field says whether the keys are typing into
                // it — accent outline and a caret while armed, the resting
                // look while another client owns the input.
                border.color: emojiRoot.searchArmed
                    ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: emojiRoot.searchArmed
                    ? tokens.focusBorderWidth
                    : tokens.normalBorderWidth

                Text {
                    id: searchLabel
                    anchors {
                        left: parent.left
                        leftMargin: tokens.space(8)
                        right: clearChip.left
                        rightMargin: tokens.space(6)
                        verticalCenter: parent.verticalCenter
                    }
                    // The query once there is one. Empty and armed (the
                    // field is the keys' target): NOTHING — the caret is
                    // the whole story, the placeholder word would only sit
                    // under it. Empty and disarmed: the placeholder, in
                    // the active layout's language.
                    text: emojiRoot.query !== "" ? emojiRoot.query
                        : (emojiRoot.searchArmed ? ""
                            : UiStrings.tr("emoji.searchPlaceholder",
                                emojiRoot.uiLang))
                    color: emojiRoot.query !== "" ? tokens.foreground : tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBody
                    elide: Text.ElideRight
                }

                // The caret (ticket 29): a quiet bar at the query's end —
                // the field is not a TextInput, so the caret is drawn.
                Rectangle {
                    visible: emojiRoot.searchArmed
                    width: 2
                    radius: 1
                    color: tokens.accent
                    x: Math.min(searchLabel.x + searchLabel.implicitWidth
                        + tokens.space(2), clearChip.x - tokens.space(6))
                    anchors {
                        top: parent.top; topMargin: tokens.space(7)
                        bottom: parent.bottom; bottomMargin: tokens.space(7)
                    }
                }

                // Clicking the field ARMS the search, always (2026-09-13;
                // was a toggle, ticket 29). A click on a search field means
                // "type here" — the owner's pointer gesture said so — and
                // an armed field stays armed. Handing the keys back to the
                // app is the focus watcher's job (a real focus change) and
                // a delivered pick's; both fire without asking the field
                // to guess what a click meant. The clear chip stays
                // clickable on top.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    Accessible.role: Accessible.Button
                    Accessible.name: emojiRoot.searchArmed
                        ? "Search field — typing goes here"
                        : "Search field — click to type here"
                    onClicked: function (mouse) {
                        emojiRoot.pointerSourceObserved(mouse.source)
                        if (emojiRoot.searchArmed) return
                        emojiRoot.searchArmed = true
                        console.log("[oskar] emoji search armed by field click")
                    }
                }

                Rectangle {
                    id: clearChip
                    anchors {
                        right: parent.right
                        rightMargin: tokens.space(4)
                        verticalCenter: parent.verticalCenter
                    }
                    visible: emojiRoot.query !== ""
                    width: tokens.space(20)
                    height: tokens.space(20)
                    radius: width / 2
                    color: clearArea.pressed ? tokens.accent
                        : clearArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)

                    Text {
                        anchors.centerIn: parent
                        text: "\u2715"
                        color: clearArea.pressed ? tokens.background : tokens.foreground
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    MouseArea {
                        id: clearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        Accessible.role: Accessible.Button
                        Accessible.name: UiStrings.tr("emoji.clearSearch", emojiRoot.uiLang)
                        onClicked: function (mouse) {
                            emojiRoot.pointerSourceObserved(mouse.source)
                            emojiRoot.query = ""
                        }
                    }
                    HoverTooltip {
                        text: UiStrings.tr("emoji.clearSearch", emojiRoot.uiLang)
                        hovered: clearArea.containsMouse
                        && emojiRoot.tooltipHoverShows
                    }
                }
            }


            Rectangle {
                id: toneButton
                anchors {
                    right: parent.right
                    rightMargin: emojiRoot.contentSpacing
                    verticalCenter: parent.verticalCenter
                }
                width: tokens.space(28)
                height: tokens.space(24)
                radius: tokens.cornerRadius
                color: toneArea.pressed ? tokens.accent
                    : emojiRoot.tonePickerOpen || toneArea.containsMouse
                        ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: emojiRoot.tonePickerOpen ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    anchors.centerIn: parent
                    text: EmojiGrid.toneHand(emojiRoot.skinTone)
                    font.pixelSize: tokens.fontBody
                }
                MouseArea {
                    id: toneArea
                    property bool touchHeld: false
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: UiStrings.tr("emoji.chooseTone", emojiRoot.uiLang)
                    onPressAndHold: touchHeld = true
                    onReleased: function (mouse) {
                        if (!(mouse.x >= 0 && mouse.x <= width
                                && mouse.y >= 0 && mouse.y <= height))
                            touchHeld = false
                    }
                    onCanceled: touchHeld = false
                    onClicked: function (mouse) {
                        var held = touchHeld
                        touchHeld = false
                        if (held) return
                        emojiRoot.tonePickerOpen = !emojiRoot.tonePickerOpen
                    }
                }
                HoverTooltip {
                    text: UiStrings.tr("emoji.chooseTone", emojiRoot.uiLang)
                    hovered: toneArea.containsMouse
                        && (emojiRoot.tooltipHoverShows || toneArea.touchHeld)
                }
            }

        }

        Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
        }

        // ---- category tabs ----
        //
        // The card's chip idiom: the active tab is accent-OUTLINED with
        // accent text, never solid-filled — a surface reports what is in
        // force, not what is pressed.
        Flow {
            id: tabsFlow
            width: parent.width
            spacing: emojiRoot.contentSpacing

            Repeater {
                model: [{ value: "__usage__", label: "🕘" }].concat(
                    EmojiGrid.tabs(EmojiGrid.allGroups()))

                Rectangle {
                    property string groupValue: modelData.value
                    property string groupLabel: modelData.label
                    property bool active: groupValue === emojiRoot.activeGroup
                    width: tokens.space(28)
                    height: tokens.space(24)
                    radius: tokens.cornerRadius
                    color: tabArea.pressed ? tokens.accent
                        : active ? "transparent"
                        : tabArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: active ? tokens.accent
                        : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: active ? tokens.focusBorderWidth
                        : tokens.normalBorderWidth

                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        text: parent.groupLabel
                        color: tabArea.pressed ? tokens.background
                            : parent.active ? tokens.accent : tokens.foreground
                        font.pixelSize: tokens.space(15)
                    }

                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        hoverEnabled: true
                        Accessible.role: Accessible.Button
                        Accessible.name: parent.groupValue === "__usage__"
                            ? UiStrings.tr("emoji.recent", emojiRoot.uiLang)
                            : parent.groupValue
                        onClicked: {
                            // A tab pick answers as "show me this group": a
                            // standing search yields, or the pick would look
                            // dead — the ranked results outrank the slice
                            // while the query stands.
                            emojiRoot.query = ""
                            emojiRoot.activeGroup = parent.groupValue
                        }
                    }
                    HoverTooltip {
                        text: parent.groupValue === "__usage__"
                            ? UiStrings.tr("emoji.recent", emojiRoot.uiLang)
                            : parent.groupValue
                        hovered: tabArea.containsMouse
                            && emojiRoot.tooltipHoverShows
                    }
                }
            }
        }

        // ---- the grid ----
        //
        // Lazy: the view instantiates delegates only as its viewport (plus
        // a small cache) reaches them — never all 3781 entries, the group
        // slice and the bounded search results alike. A clamped page height
        // leaves the grid less than its ideal rows and it scrolls the
        // difference itself.
        Item {
            id: gridArea
            width: parent.width
            height: Math.max(0, contentColumn.height - headerRow.height - 1
                - tabsFlow.height - emojiRoot.contentSpacing * 3
                - (emojiRoot.dragEnabled ? emojiRoot.stripHeight
                    + emojiRoot.contentSpacing : 0))

            GridView {
                id: grid
                anchors.fill: parent
                // No query: the active group's slice, catalogue order kept.
                // A query: the catalogue's ranked search across every
                // group — the tabs name a group, the search names an emoji —
                // capped at 3x searchLimit raw on the catalogue side, glyphs whole, so
                // a broad term still fills the viewport with distinct tiles.
                model: emojiRoot.searching
                    ? EmojiGrid.visibleEntries(
                        EmojiGrid.searchEverything(emojiRoot.query,
                            emojiRoot.searchLimit),
                        EmojiGrid.allEntries(), 0)
                    : emojiRoot.activeGroup === "__usage__"
                        ? emojiRoot.usageSections.recent
                        : EmojiGrid.groupEntries(EmojiGrid.allEntries(), emojiRoot.activeGroup)
                // The gap lives inside the cell pitch; each delegate gives
                // the trailing gap back as its own margin.
                cellWidth: emojiRoot.cellSize + emojiRoot.gridGap
                cellHeight: emojiRoot.cellSize + emojiRoot.gridGap
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                onModelChanged: grid.contentY = 0
                ScrollBar.vertical: ScrollBar {
                    policy: grid.contentHeight > grid.height
                        ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    implicitWidth: tokens.space(6)
                    contentItem: Rectangle {
                        implicitWidth: tokens.space(4)
                        radius: width / 2
                        color: parent.pressed ? tokens.accent
                            : Util.alpha(tokens.foreground, parent.hovered ? 0.45 : 0.28)
                    }
                    background: Item { implicitWidth: tokens.space(6) }
                }

                header: Column {
                    id: usageHeader
                    visible: !emojiRoot.searching
                        && emojiRoot.activeGroup === "__usage__"
                    width: grid.width
                    height: visible && emojiRoot.usageSections.frequent.length > 0
                        ? implicitHeight : 0
                    spacing: tokens.space(5)

                    Text {
                        height: tokens.space(18)
                        verticalAlignment: Text.AlignVCenter
                        text: UiStrings.tr("emoji.mostFrequent", emojiRoot.uiLang)
                        color: tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }

                    Row {
                        spacing: emojiRoot.gridGap
                        Repeater {
                            model: emojiRoot.usageSections.frequent
                            Rectangle {
                                width: emojiRoot.cellSize
                                height: emojiRoot.cellSize
                                radius: tokens.cornerRadius
                                color: frequentArea.pressed ? tokens.accent
                                    : frequentArea.containsMouse
                                        ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                                border.color: Util.alpha(tokens.foreground,
                                    tokens.pressedFillAlpha)
                                border.width: tokens.normalBorderWidth
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.emoji
                                    font.pixelSize: Math.max(1,
                                        Math.round(emojiRoot.cellSize * 0.55))
                                }
                                MouseArea {
                                    id: frequentArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    Accessible.role: Accessible.Button
                                    Accessible.name: UiStrings.tr("access.insert",
                                        emojiRoot.uiLang, [modelData.name])
                                    onClicked: function (mouse) {
                                        emojiRoot.pointerSourceObserved(mouse.source)
                                        emojiRoot.emojiChosen(modelData, false)
                                    }
                                }
                                HoverTooltip {
                                    text: modelData.name
                                    hovered: frequentArea.containsMouse
                                        && emojiRoot.tooltipHoverShows
                                }
                            }
                        }
                    }

                    Item { width: 1; height: emojiRoot.gridGap * 2 }
                    Text {
                        visible: emojiRoot.usageSections.recent.length > 0
                        height: visible ? tokens.space(18) : 0
                        verticalAlignment: Text.AlignVCenter
                        text: UiStrings.tr("emoji.recent", emojiRoot.uiLang)
                        color: tokens.muted
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                    }
                }

                delegate: Rectangle {
                    width: grid.cellWidth - emojiRoot.gridGap
                    height: grid.cellHeight - emojiRoot.gridGap
                    radius: tokens.cornerRadius
                    color: cellArea.pressed ? tokens.accent
                        : cellArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                    border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                    border.width: tokens.normalBorderWidth

                    Text {
                        anchors.centerIn: parent
                        text: modelData.emoji
                        font.pixelSize: Math.max(1, Math.round(emojiRoot.cellSize * 0.55))
                    }

                    MouseArea {
                        id: cellArea
                        anchors.fill: parent
                        hoverEnabled: true
                        Accessible.role: Accessible.Button
                        Accessible.name: UiStrings.tr("access.insert",
                            emojiRoot.uiLang, [modelData.name])
                        // The tile's origin — catalogue tile or usage
                        // history — decides the tone flag, with exactly the
                        // two facts that chose this grid's model (R1):
                        // history repeats its exact stored sequence.
                        onClicked: function (mouse) {
                            emojiRoot.pointerSourceObserved(mouse.source)
                            emojiRoot.emojiChosen(modelData,
                                EmojiGrid.appliesTone(emojiRoot.searching,
                                    emojiRoot.activeGroup))
                        }
                    }
                    HoverTooltip {
                        text: modelData.name
                        hovered: cellArea.containsMouse
                            && emojiRoot.tooltipHoverShows
                    }
                }

                // An empty grid with no query cannot happen (a group is
                // never empty — tests/emoji-catalog.qml pins the
                // catalogue's shape), so an empty grid is the query
                // finding nothing.
                Text {
                    anchors.centerIn: parent
                    visible: grid.count === 0
                    text: emojiRoot.searching
                        ? UiStrings.tr("emoji.noMatches", emojiRoot.uiLang) : ""
                    color: tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }
            }
        }
    }

    Rectangle {
        id: tonePopup
        visible: emojiRoot.tonePickerOpen
        z: 20
        anchors {
            top: parent.top
            topMargin: emojiRoot.pageMargin + headerRow.height
            right: parent.right
            rightMargin: emojiRoot.pageMargin
        }
        width: toneOptions.implicitWidth + tokens.space(6) * 2
        height: tokens.space(34)
        radius: tokens.cornerRadius
        color: tokens.panelBackground
        border.color: tokens.accent
        border.width: tokens.normalBorderWidth

        Row {
            id: toneOptions
            anchors.centerIn: parent
            spacing: tokens.space(3)
            Repeater {
                model: EmojiGrid.SKIN_TONES
                Rectangle {
                    readonly property bool active: modelData.value === emojiRoot.skinTone
                    width: tokens.space(26)
                    height: tokens.space(26)
                    radius: tokens.cornerRadius
                    color: toneChoiceArea.pressed ? tokens.accent
                        : toneChoiceArea.containsMouse
                            ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                            : "transparent"
                    border.color: active ? tokens.accent : "transparent"
                    border.width: active ? tokens.focusBorderWidth : 0
                    Text {
                        anchors.centerIn: parent
                        text: modelData.hand
                        font.pixelSize: tokens.fontBody
                    }
                    MouseArea {
                        id: toneChoiceArea
                        anchors.fill: parent
                        hoverEnabled: true
                        Accessible.role: Accessible.Button
                        Accessible.name: EmojiGrid.toneNameId(modelData.value) !== ""
                            ? UiStrings.tr(EmojiGrid.toneNameId(modelData.value),
                                emojiRoot.uiLang)
                            : modelData.label
                        onClicked: {
                            emojiRoot.skinToneChosen(modelData.value)
                            emojiRoot.tonePickerOpen = false
                        }
                    }
                    HoverTooltip {
                        text: EmojiGrid.toneNameId(modelData.value) !== ""
                            ? UiStrings.tr(EmojiGrid.toneNameId(modelData.value),
                                emojiRoot.uiLang)
                            : modelData.label
                        hovered: toneChoiceArea.containsMouse
                            && emojiRoot.tooltipHoverShows
                    }
                }
            }
        }
    }
}
