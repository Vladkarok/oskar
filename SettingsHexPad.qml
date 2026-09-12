import QtQuick
import qs.Commons

// The temporary local hex-entry pad (spec-v1.1 §5, 2026-09-06 amendment):
// how the OSK enters and corrects a whole hex value with no physical
// keyboard, under `us` and `ua` alike. The pad is fixed-label panel chrome —
// it never replaces the system keymap, never changes the selected group, and
// never asks the helper to type. Every key edits the target field's draft
// directly (insert, delete, caret, select), so a draft character or modifier
// chord cannot reach the previously focused application: no virtual key is
// pressed at all. The pad lives INSIDE the surface that hosts its field
// (the settings popover, or the custom colour editor), so the card's input
// mask and the popover's dismissal mask never swallow its clicks.
Item {
    id: hexPad

    // The panel's live Theme facade.
    property var tokens
    // The draft's TextInput. One pad serves one surface's fields; the field
    // stays focused while the pad is used (a MouseArea takes no keyboard
    // focus), so the §5 focus exception and the caret both remain where the
    // user left them.
    property var field: null

    readonly property int rows: 3
    readonly property int columns: 8
    readonly property real keyGap: tokens.space(5)
    readonly property real keyHeight: tokens.space(30)

    // The host sets the width (the popover's control zone or the editor's
    // column); the height follows from the key grid. implicitWidth is only
    // a floor for hosts that do not set one.
    implicitWidth: columns * tokens.space(24) + (columns - 1) * keyGap
    implicitHeight: rows * keyHeight + (rows - 1) * keyGap
    height: implicitHeight

    readonly property real keyWidth: (width - (columns - 1) * keyGap) / columns

    function insertText(text) {
        if (!field || !text) return
        var start = field.selectionStart, end = field.selectionEnd
        if (start >= 0 && end > start) field.remove(start, end)
        var room = field.maximumLength > 0 ? field.maximumLength - field.length : -1
        if (room === 0) return
        if (room > 0 && text.length > room) text = text.slice(0, room)
        field.insert(field.cursorPosition, text)
    }

    function backspace() {
        if (!field) return
        var start = field.selectionStart, end = field.selectionEnd
        if (start >= 0 && end > start) { field.remove(start, end); return }
        if (field.cursorPosition > 0) field.remove(field.cursorPosition - 1, field.cursorPosition)
    }

    function deleteForward() {
        if (!field) return
        var start = field.selectionStart, end = field.selectionEnd
        if (start >= 0 && end > start) { field.remove(start, end); return }
        if (field.cursorPosition < field.length) field.remove(field.cursorPosition, field.cursorPosition + 1)
    }

    function moveCaret(delta) {
        if (!field) return
        field.deselect()
        field.cursorPosition = Math.max(0, Math.min(field.length, field.cursorPosition + delta))
    }

    function selectAll() {
        if (field) field.selectAll()
    }

    component PadKey: Rectangle {
        id: padKey

        property string caption: ""
        property string accessName: ""
        signal activated()

        width: hexPad.keyWidth
        height: hexPad.keyHeight
        radius: tokens.cornerRadius
        color: keyArea.pressed ? tokens.accent
            : keyArea.containsMouse ? Util.alpha(tokens.foreground, tokens.hoverFillAlpha)
            : Util.alpha(tokens.foreground, tokens.normalFillAlpha)
        border.color: Util.alpha(tokens.foreground, tokens.pressedFillAlpha)
        border.width: tokens.normalBorderWidth

        Text {
            anchors.centerIn: parent
            text: padKey.caption
            color: tokens.foreground
            font.family: tokens.fontFamily
            font.pixelSize: tokens.fontBody
            font.bold: padKey.caption.length === 1
        }

        MouseArea {
            id: keyArea
            anchors.fill: parent
            hoverEnabled: true
            Accessible.role: Accessible.Button
            Accessible.name: padKey.accessName !== "" ? padKey.accessName : padKey.caption
            onClicked: padKey.activated()
        }
    }

    Column {
        anchors.fill: parent
        spacing: hexPad.keyGap

        // The digits. Fixed labels — no group switch stands behind them, so
        // the same ten presses exist under `us` and `ua` alike.
        Row {
            spacing: hexPad.keyGap
            Repeater {
                model: ["1", "2", "3", "4", "5", "6", "7", "8"]
                PadKey {
                    caption: modelData
                    onActivated: hexPad.insertText(modelData)
                }
            }
        }

        Row {
            spacing: hexPad.keyGap
            Repeater {
                model: ["9", "0", "A", "B", "C", "D", "E", "F"]
                PadKey {
                    caption: modelData
                    onActivated: hexPad.insertText(modelData)
                }
            }
        }

        // The edit row: the '#', backward/forward delete, the caret moves
        // and select-all — entering, correcting and selecting a complete
        // value without a physical keyboard. The letters above are
        // uppercase per the amendment; the entry grammar accepts either
        // case, so one set serves both.
        Row {
            spacing: hexPad.keyGap
            Repeater {
                model: [
                    { c: "#", n: "" },
                    { c: "\u232b", n: "Backspace" },
                    { c: "\u2190", n: "Caret left" },
                    { c: "\u2192", n: "Caret right" },
                    { c: "All", n: "Select all" },
                    { c: "\u2326", n: "Delete forward" }
                ]
                PadKey {
                    caption: modelData.c
                    accessName: modelData.n
                    onActivated: {
                        if (modelData.c === "#") hexPad.insertText("#")
                        else if (modelData.n === "Backspace") hexPad.backspace()
                        else if (modelData.n === "Caret left") hexPad.moveCaret(-1)
                        else if (modelData.n === "Caret right") hexPad.moveCaret(1)
                        else if (modelData.n === "Select all") hexPad.selectAll()
                        else hexPad.deleteForward()
                    }
                }
            }
            // Two invisible spacers keep the edit row on the shared grid —
            // six labelled keys, one key width, no row of its own size.
            Item { width: hexPad.keyWidth; height: 1 }
            Item { width: hexPad.keyWidth; height: 1 }
        }
    }
}
