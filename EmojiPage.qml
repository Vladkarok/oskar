import QtQuick
import QtQuick.Controls
import qs.Commons
import "EmojiCatalog.js" as Catalog
import "EmojiPage.js" as EmojiGrid

// The panel's own emoji page (ticket 24). Lives on the settings overlay
// window beside the settings card and rides the same mechanism
// (spec-v1.1 §5): the panel places it at leftover centre through
// SettingsPlacement, clamps it inside the leftover strip, and the keyboard
// band is never part of either — the keys stay on screen and clickable
// underneath, which is the point. Grid cells size from tokens and the
// keyboard's uiScale; whatever content does not fit scrolls inside the page.
//
// The keyboard's own caps feed the query while the page stands — searchMode
// routes them here before anything reaches the daemon — and the query
// drives the catalogue's ranked search across every group; an empty query
// shows the active group. Choosing an entry asks the panel to deliver it
// through the helper (no clipboard). The configured external app stays
// reachable as an explicit fallback through the header chip: the panel
// execs it and does nothing else — the external picker needs no
// cooperation from us any more (decisions §24).
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
    // Ticket 28's delivery mode, shown by the header's clipboard toggle.
    property string deliveryMode: "direct"
    signal deliveryModeRequested(string mode)

    // Overlay size the page may occupy. Placement (leftover centre) is
    // applied by the panel as x/y; this only feeds the clamp below.
    property real hostWidth: 0
    property real hostHeight: 0

    // The search text the on-screen keys build (Keyboard.searchMode routes
    // them here). Cleared on a fresh open — a stale filter must not greet
    // the next open the way a stale hex draft must not (the card's own
    // rule). A blank string is no query: the group slice shows, and search
    // is not asked (its empty answer is for found-nothing, not not-searching).
    property string query: ""
    // Ticket 29: whether the keys feed the search. Armed when the page
    // opens and when the search field is clicked; disarmed when another
    // client takes the pointer's focus (the panel watches Hyprland), so a
    // cap types into that client until the owner returns to the field.
    property bool searchArmed: true
    // Panel-local tab state, never persisted; defaults to the first group.
    property string activeGroup: "__usage__"
    readonly property var usageRecordSections: EmojiGrid.usageSections(
        usageRecords, gridColumnCount)
    readonly property var usageSections: ({
        frequent: EmojiGrid.recordsToEntries(usageRecordSections.frequent,
            Catalog.entries()),
        recent: EmojiGrid.recordsToEntries(usageRecordSections.recent,
            Catalog.entries())
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
                ? "__usage__" : Catalog.groups()[0]
        }
    }

    // Escape dismisses the page — but the overlay surface takes no keyboard
    // focus for its whole life (the settings layer's keyboardFocus is None),
    // so this handler cannot fire today and dismissal is the Esc cap's job,
    // routed through the panel like any cap action. The handler stands for
    // the day the surface takes focus; nothing depends on it now.
    Keys.onEscapePressed: emojiRoot.dismissed()

    // ---- geometry ----
    //
    // Width and height are natural-by-content, clamped to the leftover the
    // host hands in (the popover's own shape). The grid is the flexible
    // part: it gets whatever the clamped page leaves after header and tabs,
    // and scrolls the rest.

    readonly property real pageMargin: tokens.space(10)
    readonly property real contentSpacing: tokens.space(7)
    readonly property real gridGap: tokens.space(4)
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

        // ---- header: the search the keys type ----
        //
        // A field, a clear affordance, and the external app's chip. The
        // field shows what was typed — case included; the ranked search
        // lowercases its own side (§37). The chip is deliberately the
        // smaller, quieter control: the page's own search is the primary
        // route, the external app the explicit fallback.
        Item {
            id: headerRow
            width: parent.width
            height: tokens.space(28)

            Rectangle {
                id: searchField
                anchors {
                    left: parent.left
                    right: deliveryButton.left
                    rightMargin: emojiRoot.contentSpacing
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
                    text: emojiRoot.query !== "" ? emojiRoot.query : "Search"
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

                // Clicking the field TOGGLES the search (ticket 29): armed
                // is the page's default, and a click re-arms after a focus
                // change or a pick settles it. The toggle back is the
                // sanctioned escape for the one gesture Hyprland cannot
                // report — a click on the ALREADY-FOCUSED client emits no
                // event (0.56 source: rawWindowFocus early-returns on
                // same-surface), so "click the chat, type in the chat"
                // needs a visible control of our own: click the field to
                // hand the keys back, click it again to search. The clear
                // chip stays clickable on top.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    Accessible.role: Accessible.Button
                    Accessible.name: emojiRoot.searchArmed
                        ? "Search field — typing goes here"
                        : "Search field — click to type here"
                    onClicked: {
                        emojiRoot.searchArmed = !emojiRoot.searchArmed
                        console.log("[osk] emoji search",
                            emojiRoot.searchArmed ? "armed by field click"
                                : "disarmed by field click")
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
                        Accessible.name: "Clear search"
                        onClicked: emojiRoot.query = ""
                    }
                    HoverTooltip {
                        text: "Clear search"
                        hovered: clearArea.containsMouse
                    }
                }
            }

            Rectangle {
                id: deliveryButton
                // Ticket 28: the delivery mode lives beside the tone hand —
                // one press toggles typing (⌨) and clipboard compatibility
                // (📋). The clipboard mode REPLACES the clipboard with the
                // picked sequence; the tooltip says so, per §6.
                anchors {
                    right: toneButton.left
                    rightMargin: emojiRoot.contentSpacing
                    verticalCenter: parent.verticalCenter
                }
                width: tokens.space(28)
                height: tokens.space(24)
                radius: tokens.cornerRadius
                color: deliveryArea.pressed ? tokens.accent
                    : deliveryArea.containsMouse
                        ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                        : emojiRoot.deliveryMode === "clipboard"
                            ? Util.alpha(tokens.accent, tokens.hoverFillAlpha)
                            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: emojiRoot.deliveryMode === "clipboard"
                    ? tokens.accent
                    : Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    anchors.centerIn: parent
                    text: emojiRoot.deliveryMode === "clipboard" ? "📋" : "⌨"
                    font.pixelSize: tokens.fontBody
                }
                MouseArea {
                    id: deliveryArea
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: emojiRoot.deliveryMode === "clipboard"
                        ? "Delivery: clipboard compatibility"
                        : "Delivery: typing"
                    onClicked: emojiRoot.deliveryModeRequested(
                        emojiRoot.deliveryMode === "clipboard"
                            ? "direct" : "clipboard")
                }
                HoverTooltip {
                    text: emojiRoot.deliveryMode === "clipboard"
                        ? "Delivery: clipboard (replaces the clipboard)"
                        : "Delivery: typing"
                    hovered: deliveryArea.containsMouse
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
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Choose skin tone"
                    onClicked: emojiRoot.tonePickerOpen = !emojiRoot.tonePickerOpen
                }
                HoverTooltip {
                    text: "Choose skin tone"
                    hovered: toneArea.containsMouse
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
                    EmojiGrid.tabs(Catalog.groups()))

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
                            ? "Recent" : parent.groupValue
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
                            ? "Recent" : parent.groupValue
                        hovered: tabArea.containsMouse
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
                - tabsFlow.height - emojiRoot.contentSpacing * 3)

            GridView {
                id: grid
                anchors.fill: parent
                // No query: the active group's slice, catalogue order kept.
                // A query: the catalogue's ranked search across every
                // group — the tabs name a group, the search names an emoji —
                // capped at searchLimit after modifier families collapse, so
                // a broad term still fills the viewport with distinct tiles.
                model: emojiRoot.searching
                    ? EmojiGrid.visibleEntries(Catalog.search(emojiRoot.query, 0),
                        Catalog.entries(), emojiRoot.searchLimit)
                    : emojiRoot.activeGroup === "__usage__"
                        ? emojiRoot.usageSections.recent
                        : EmojiGrid.groupEntries(Catalog.entries(), emojiRoot.activeGroup)
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
                        text: "Most Frequent"
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
                                    Accessible.name: "Insert " + modelData.name
                                    onClicked: emojiRoot.emojiChosen(modelData, false)
                                }
                                HoverTooltip {
                                    text: modelData.name
                                    hovered: frequentArea.containsMouse
                                }
                            }
                        }
                    }

                    Item { width: 1; height: emojiRoot.gridGap * 2 }
                    Text {
                        visible: emojiRoot.usageSections.recent.length > 0
                        height: visible ? tokens.space(18) : 0
                        verticalAlignment: Text.AlignVCenter
                        text: "Recent"
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
                        Accessible.name: "Insert " + modelData.name
                        // The tile's origin — catalogue tile or usage
                        // history — decides the tone flag, with exactly the
                        // two facts that chose this grid's model (R1):
                        // history repeats its exact stored sequence.
                        onClicked: emojiRoot.emojiChosen(modelData,
                            EmojiGrid.appliesTone(emojiRoot.searching,
                                emojiRoot.activeGroup))
                    }
                    HoverTooltip {
                        text: modelData.name
                        hovered: cellArea.containsMouse
                    }
                }

                // An empty grid with no query cannot happen (a group is
                // never empty — tests/emoji-catalog.qml pins the
                // catalogue's shape), so an empty grid is the query
                // finding nothing.
                Text {
                    anchors.centerIn: parent
                    visible: grid.count === 0
                    text: emojiRoot.searching ? "No matches" : ""
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
                        Accessible.name: modelData.label
                        onClicked: {
                            emojiRoot.skinToneChosen(modelData.value)
                            emojiRoot.tonePickerOpen = false
                        }
                    }
                    HoverTooltip {
                        text: modelData.label
                        hovered: toneChoiceArea.containsMouse
                    }
                }
            }
        }
    }
}
