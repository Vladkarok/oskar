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
    // The size preset's scale, the same multiplier the keys ride
    // (Keyboard.qml): the grid grows with the keyboard it is typed from.
    property real uiScale: 1.0

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
    // Panel-local tab state, never persisted; defaults to the first group.
    property string activeGroup: Catalog.groups().length > 0 ? Catalog.groups()[0] : ""

    // A blank query — spaces included, since a lone separator is not a term
    // — leaves the group slice in force.
    readonly property bool searching: query.trim() !== ""
    // The ranked search's cap: rows' worth of a page, so a broad term hands
    // the model a bounded set while the grid scrolls what there is.
    readonly property int searchRows: 8
    readonly property int searchLimit: Math.max(1, gridColumnCount) * searchRows

    // Step 4's seam: a cell press names its entry; the panel delivers.
    signal emojiChosen(var entry)
    signal dismissed()
    // The fallback's seam (ticket 24 step 5): the chip names the configured
    // external app and one press asks the panel to exec it — nothing more
    // rides along, no window management, no session.
    property string externalApp: ""
    signal externalAppRequested()

    // One intercepted keyboard cap, applied to the standing query. The
    // keyboard names the action ("char" with the character it drew,
    // "backspace", "space"); the pure rule is EmojiGrid's.
    function applySearchKey(action, text) {
        emojiRoot.query = EmojiGrid.nextQuery(emojiRoot.query, action, text)
    }

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus()
            emojiRoot.query = ""
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
    // Key-sized cells: the keyboard's own key height is space(42) * uiScale
    // (Keyboard.qml), so a cell breathes like a key at every preset.
    readonly property real cellSize: Math.round(tokens.space(42) * uiScale)
    readonly property int naturalColumns: 8
    readonly property real naturalPageWidth: pageMargin * 2
        + naturalColumns * cellSize + (naturalColumns - 1) * gridGap
    readonly property real maxPageWidth: hostWidth > 0
        ? Math.max(0, hostWidth - tokens.space(6) * 2) : naturalPageWidth
    width: Math.min(naturalPageWidth, maxPageWidth)
    // Columns the clamped width actually holds — never fewer than one, so a
    // narrow output narrows the grid instead of spilling cells past the edge.
    readonly property int gridColumnCount: EmojiGrid.columnsFor(
        width - pageMargin * 2, cellSize, gridGap, naturalColumns)

    readonly property real gridRowsWanted: 4
    readonly property real gridIdealHeight:
        gridRowsWanted * (cellSize + gridGap) - gridGap
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
                    right: externalAppChip.left
                    rightMargin: emojiRoot.contentSpacing
                    top: parent.top
                    bottom: parent.bottom
                }
                radius: tokens.cornerRadius
                color: Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
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
                }
            }

            // The configured external app (spec-v1.1 §1, 2026-09-09
            // amendment): one compact chip, one press, one execDetached —
            // the panel runs it and nothing more, the way the ☺ cap once
            // did. No fitting, no session, no paste handoff; the app's
            // windows are the user's to close. Absent from PATH, the panel
            // raises the transient hint; the chip itself stays put.
            Rectangle {
                id: externalAppChip
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                width: Math.min(externalAppLabel.implicitWidth + tokens.space(8) * 2,
                    parent.width / 3)
                height: tokens.space(22)
                radius: tokens.cornerRadius
                visible: emojiRoot.externalApp !== ""
                color: chipArea.pressed ? tokens.accent
                    : chipArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
                    : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
                border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
                border.width: tokens.normalBorderWidth

                Text {
                    id: externalAppLabel
                    anchors.centerIn: parent
                    width: parent.width - tokens.space(8) * 2
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    // The popover's own shortening: the launcher prefix
                    // says nothing the row has not already said.
                    text: emojiRoot.externalApp.indexOf("omarchy-") === 0
                        ? emojiRoot.externalApp.slice("omarchy-".length)
                        : emojiRoot.externalApp
                    color: chipArea.pressed ? tokens.background : tokens.muted
                    font.family: tokens.fontFamily
                    font.pixelSize: tokens.fontBodySmall
                }

                MouseArea {
                    id: chipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Open " + emojiRoot.externalApp
                    onClicked: emojiRoot.externalAppRequested()
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
                model: EmojiGrid.tabs(Catalog.groups())

                Rectangle {
                    property string groupValue: modelData.value
                    property string groupLabel: modelData.label
                    property bool active: groupValue === emojiRoot.activeGroup
                    width: tabLabel.implicitWidth + tokens.space(10) * 2
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
                        font.family: tokens.fontFamily
                        font.pixelSize: tokens.fontBodySmall
                        font.bold: parent.active
                    }

                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        hoverEnabled: true
                        Accessible.role: Accessible.Button
                        Accessible.name: parent.groupValue
                        onClicked: {
                            // A tab pick answers as "show me this group": a
                            // standing search yields, or the pick would look
                            // dead — the ranked results outrank the slice
                            // while the query stands.
                            emojiRoot.query = ""
                            emojiRoot.activeGroup = parent.groupValue
                        }
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
                // capped at searchLimit so a broad term hands the model a
                // bounded set. Skin-tone variants rank through their names.
                model: !emojiRoot.searching
                    ? EmojiGrid.groupEntries(Catalog.entries(), emojiRoot.activeGroup)
                    : Catalog.search(emojiRoot.query, emojiRoot.searchLimit)
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
                        onClicked: emojiRoot.emojiChosen(modelData)
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
}
