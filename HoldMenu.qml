import QtQuick

Item {
    id: menu

    // The hold column's menu: the everywhere-outside catch area, the
    // popup card over the held cap's column, and the entry delegates
    // with their own dwell underline affordance. What stayed in the
    // keyboard is everything a pick is ABOUT: the pending hold and its
    // threshold timer (holdCap/holdDelegate, beginCapHold/endCapHold —
    // the release typing path), the column facts (capHoldColumn, handed
    // in as `columnFor` so the menu's content and the caps' corner dot
    // cannot disagree about what the keymap carries), and the pick's
    // dispatch to typing (pickHoldEntry, handed in as `pickEntry` — the
    // chord is the keyboard's, through applyModifierEvent exactly as a
    // glyph cap's press). The dwell MACHINE stayed too: the entry arm's
    // enter/leave/reset ride the callbacks below, and only this menu's
    // own affordance and hit-area wiring live here.
    //
    // The menu's baked state (cap, delegate, entries, geometry) lives
    // here because the grid the delegate lives in can rebuild under a
    // standing menu and the menu's pick must still name the position
    // that was held. The hosted keyboard forwards menuOpen and entries
    // under the names the integration leg probes
    // (tools/integration/hold_column.py).

    // ---- IN from the keyboard ----
    //
    // The geometry and ink facts the card and its entries draw with,
    // resolved keyboard tokens under their own names so the moved
    // bindings keep their shape.
    property real cellGap: 2
    property real capRowHeight: 42
    property real capCorner: 4
    property int keyBorderWidth: 1
    property color popupsBackground: "transparent"
    property color capEdge: "transparent"
    property color hoverFill: "transparent"
    property color textDim: "transparent"
    property color inkMain: "transparent"
    property string glyphTypeface: ""
    property int capGlyphSize: 12
    // The typing gate the entries' disabled treatment reads.
    property bool inputReady: false
    // The column lookup (capHoldColumn), on the live caps facts:
    // (cap) => entries.
    property var columnFor: null
    // The pick's dispatch to typing (pickHoldEntry): (entry) => void.
    property var pickEntry: null
    // The dwell machine's entry arm (dwellEnterEntry/dwellLeave/
    // dwellReset on the keyboard): the fire path is a typing path and
    // stays there; these are only the hit area's wiring.
    property var dwellEnterEntry: null
    property var dwellLeave: null
    property var dwellReset: null

    // ---- OUT to the keyboard ----
    //
    // The menu's baked copies, assigned at open and cleared at close.
    property bool menuOpen: false
    property var cap: null
    property Item delegate: null
    property var entries: []
    // The held cap's geometry in the keyboard's coordinates (this
    // component fills the keyboard root, so its own are those), mapped
    // once at open: the menu positions itself from these, not from a
    // delegate that a row rebuild may have destroyed.
    property real capX: 0
    property real capTop: 0
    property real capBottom: 0

    /// The threshold fired: open the menu over the held cap, or leave
    /// the hold pending when the position turns out to have nothing to
    /// offer (facts changed under the hold) — a release then still
    /// types, which is as close to "behaves exactly as today" as a
    /// deferred press can come, and no character was typed by the hold
    /// itself either way. The return says whether the menu opened, so
    /// the caller keeps its hold pending exactly when it did not.
    function open(cap, delegate) {
        var entries = columnFor(cap)
        if (entries.length === 0) return false
        var point = delegate.mapToItem(menu, 0, 0)
        menu.cap = cap
        menu.delegate = delegate
        menu.entries = entries
        menu.capX = point.x + delegate.width / 2
        menu.capTop = point.y
        menu.capBottom = point.y + delegate.height
        menu.menuOpen = true
        return true
    }

    function close() {
        menu.menuOpen = false
        menu.cap = null
        menu.delegate = null
        menu.entries = []
    }

    // ---- the hold column's menu ----
    //
    // Card-local: the panel window's input mask is the card rect, so the
    // menu lives INSIDE the keyboard's own bounds — above it in z, over
    // the held cap's column. The catch area underneath eats every press
    // that is not on the menu itself: one click anywhere else dismisses
    // without typing, and no cap underneath can start a press of its own
    // while the menu stands.
    MouseArea {
        anchors { fill: parent }
        enabled: menu.menuOpen
        z: 4
        onClicked: menu.close()
    }

    Rectangle {
        id: holdMenu

        visible: menu.menuOpen
        z: 5

        // Above the held cap when the column fits there, below it when it
        // does not (a row-0 hold has no room above), and never outside
        // the keyboard's rect — that keeps the menu inside the card, i.e.
        // inside the input mask, docked or floating. Anchors are baked at
        // open (the component's open); the menu does not follow a card
        // dragged under it.
        readonly property real aboveY: menu.capTop - height - menu.cellGap
        readonly property real belowY: menu.capBottom + menu.cellGap
        x: Math.max(menu.cellGap,
            Math.min(menu.capX - width / 2,
                parent.width - width - menu.cellGap))
        y: Math.max(menu.cellGap,
            Math.min(aboveY >= menu.cellGap ? aboveY : belowY,
                parent.height - height - menu.cellGap))
        width: menuList.childrenRect.width + menu.cellGap * 2
        height: menuList.childrenRect.height + menu.cellGap * 2
        radius: menu.capCorner
        color: menu.popupsBackground
        border.color: menu.capEdge
        // The cap edge's own width, IN like the tokens the entries
        // read — and not the upstream sketch's border line.
        border.width: menu.keyBorderWidth

        // The hover shield: the menu's padding and the gaps between
        // entries accept HOVER, not just presses, so a resting pointer
        // cannot fall through onto the caps hidden underneath and type
        // characters the user could not see. The entries' own hit areas
        // sit above this shield (declared later inside the Column).
        MouseArea {
            anchors { fill: parent }
            hoverEnabled: true
            // Swallow hover; a press on the padding still closes (the
            // catch area's everywhere-outside contract, kept local).
            onClicked: menu.close()
        }

        Column {
            id: menuList
            anchors {
                top: parent.top
                topMargin: menu.cellGap
                horizontalCenter: parent.horizontalCenter
            }
            spacing: menu.cellGap / 2

            Repeater {
                model: menu.entries

                Rectangle {
                    id: entryCard
                    property var entry: modelData
                    // The same disabled treatment the caps keep: an entry
                    // that could not type draws dim and refuses its click,
                    // and no click sound plays for it.
                    readonly property bool gated: !menu.inputReady
                    width: menu.capRowHeight
                    height: Math.round(menu.capRowHeight * 0.8)
                    radius: menu.capCorner
                    color: entryHit.containsMouse && !gated
                        ? menu.hoverFill : "transparent"

                    // The dwell affordance's two handles, the caps' own:
                    // start grows the foot underline over the rest's
                    // delay, stop snaps it away — methods rather than
                    // bindings so they restart on every arm and die
                    // instantly on every cancel.
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
                        color: gated ? menu.textDim : menu.inkMain
                        font.family: menu.glyphTypeface
                        font.pixelSize: menu.capGlyphSize
                    }

                    // The dwell progress affordance: the caps' own
                    // underline in the caps' own register — textDim ink, a
                    // hint of opacity, never an accent fill — because it
                    // is the same PROGRESS the caps promise: it exists
                    // only while a rest is live and vanishes the instant
                    // the rest ends, picked, cancelled or left.
                    Rectangle {
                        id: entryDwellUnderline
                        visible: false
                        width: 0
                        height: Math.max(2,
                            Math.round(menu.cellGap * 0.45))
                        radius: height / 2
                        anchors {
                            horizontalCenter: parent.horizontalCenter
                            bottom: parent.bottom
                            bottomMargin: Math.round(menu.cellGap * 0.35)
                        }
                        color: menu.textDim
                        opacity: 0.8
                    }
                    NumberAnimation {
                        id: entryDwellFillAnim
                        target: entryDwellUnderline
                        property: "width"
                        from: 0
                        to: entryCard.width - menu.cellGap
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
                        onPressed: menu.dwellReset()
                        onCanceled: menu.dwellReset()
                        // The dwell path's entry arm: the hit area's own
                        // bounds decide the rest; moving between entries
                        // re-targets (the enter supersedes), the gap
                        // crossing is the shield's, and a leave cancels.
                        onEntered: menu.dwellEnterEntry(entry, entryCard)
                        onExited: menu.dwellLeave(entryCard)
                        onClicked: {
                            if (gated) return
                            menu.pickEntry(entry)
                        }
                    }
                }
            }
        }
    }
}
