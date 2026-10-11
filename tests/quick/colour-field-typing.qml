import QtQuick
import QtQuick.Controls
import QtTest
import "../../Config.js" as ConfigFile

// The colour fields are read-only to Qt and type through
// ConfigFile.fieldKeyEdit (decisions §120). The suites drive a mock; this
// drives a real TextInput and a real TextField, the way SettingsColorRow
// and SettingsColorEditor declare theirs, under Qt Quick Test offscreen:
// typing, Backspace, Delete, Cut, selection replace, maximumLength, Ctrl+C,
// the caret, the paste chord reaching the chip and not Qt, and the one
// write per key that the editor's channel handler depends on.
// Run: qmltestrunner -input tests/quick/colour-field-typing.qml
Item {
    id: root
    width: 400; height: 200
    property int routed: 0
    property var edits: []
    function pasteCurrentContent() { routed += 1 }

    TextInput { id: source; text: "ff00ff"; width: 100; height: 20 }

    // The guard as the colour fields declare it.
    component Guarded: TextInput {
        id: g
        width: 100; height: 20
        maximumLength: 9
        readOnly: true
        selectByMouse: true
        cursorVisible: activeFocus
        cursorDelegate: Rectangle { width: 2; radius: 1; color: "red"; visible: parent.activeFocus }
        onTextEdited: root.edits.push(text)
        Keys.onPressed: function (event) {
            if (event.matches(StandardKey.Paste)) {
                event.accepted = true
                root.pasteCurrentContent()
                return
            }
            var edit = ConfigFile.fieldKeyEdit(g, event)
            if (!edit.handled) return
            event.accepted = true
            if (edit.changed) g.textEdited()
        }
    }

    Guarded { id: guarded; y: 40 }

    // A channel field: its handler normalises the number it is given on
    // every textEdited, the way SettingsColorEditor.pushFields does.
    Guarded {
        id: channel
        y: 60
        maximumLength: 3
        onTextEdited: {
            var n = parseInt(text, 10)
            var normal = isNaN(n) ? "" : String(n)
            if (normal !== text) text = normal
        }
    }

    TextField {
        id: guardedField
        y: 80; width: 100; height: 20
        maximumLength: 9
        readOnly: true
        cursorVisible: activeFocus
        cursorDelegate: Rectangle { width: 2; radius: 1; color: "red"; visible: parent.activeFocus }
        onTextEdited: root.edits.push(text)
        Keys.onPressed: function (event) {
            if (event.matches(StandardKey.Paste)) {
                event.accepted = true
                root.pasteCurrentContent()
                return
            }
            var edit = ConfigFile.fieldKeyEdit(guardedField, event)
            if (!edit.handled) return
            event.accepted = true
            if (edit.changed) guardedField.textEdited()
        }
    }

    TextInput { id: sink; y: 120; width: 100; height: 20 }

    TestCase {
        name: "ColourFieldTyping"
        when: windowShown

        function init() {
            source.selectAll(); source.copy()
            guarded.text = ""; guardedField.text = ""; sink.text = ""; channel.text = ""
            root.routed = 0; root.edits = []
        }

        function test_typing_lands_one_edit_per_key() {
            guarded.forceActiveFocus()
            keyClick(Qt.Key_NumberSign); keyClick(Qt.Key_A); keyClick(Qt.Key_B); keyClick(Qt.Key_C)
            compare(guarded.text, "#abc")
            compare(root.edits, ["#", "#a", "#ab", "#abc"], "textEdited once per key, with the result")
            keyClick(Qt.Key_Backspace)
            compare(guarded.text, "#ab")
            keyClick(Qt.Key_Home); keyClick(Qt.Key_Delete)
            compare(guarded.text, "ab", "Home moved the cursor (Qt) and Delete removed (ours)")
            compare(guarded.cursorPosition, 0)
        }

        function test_selection_replace_is_one_write() {
            channel.forceActiveFocus()
            keyClick(Qt.Key_1); keyClick(Qt.Key_0); keyClick(Qt.Key_0)
            compare(channel.text, "100")
            channel.select(0, 1)
            keyClick(Qt.Key_2)
            compare(channel.text, "200", "the normaliser saw the result, not an intermediate 00")
            compare(channel.cursorPosition, 1)
            channel.select(0, 1)
            keyClick(Qt.Key_Backspace)
            compare(channel.text, "0", "removing the leading digit leaves 00, normalised to 0")
        }

        function test_max_length_and_select_all_replace() {
            guarded.forceActiveFocus()
            keyClick(Qt.Key_1); keyClick(Qt.Key_2); keyClick(Qt.Key_3); keyClick(Qt.Key_4); keyClick(Qt.Key_5)
            keyClick(Qt.Key_6); keyClick(Qt.Key_7); keyClick(Qt.Key_8); keyClick(Qt.Key_9); keyClick(Qt.Key_0)
            compare(guarded.text, "123456789", "the tenth key is refused by maximumLength")
            keyClick(Qt.Key_A, Qt.ControlModifier)
            keyClick(Qt.Key_X)
            compare(guarded.text, "x", "Ctrl+A (Qt) then a key replaces the selection (ours)")
        }

        function test_paste_chords_reach_the_chip_not_qt() {
            guarded.forceActiveFocus()
            keyClick(Qt.Key_V, Qt.ControlModifier)
            keyClick(Qt.Key_Insert, Qt.ShiftModifier)
            compare(guarded.text, "", "neither chord reached Qt's paste")
            compare(root.routed, 2, "both chords reached the chip action")
        }

        function test_copy_and_cut() {
            guarded.forceActiveFocus()
            keyClick(Qt.Key_Z); keyClick(Qt.Key_Q)
            keyClick(Qt.Key_A, Qt.ControlModifier)
            keyClick(Qt.Key_C, Qt.ControlModifier)
            sink.forceActiveFocus()
            keyClick(Qt.Key_V, Qt.ControlModifier)
            compare(sink.text, "zq", "Ctrl+C in the read-only field copied")
            guarded.forceActiveFocus()
            guarded.select(0, 1)
            keyClick(Qt.Key_X, Qt.ControlModifier)
            compare(guarded.text, "q", "Ctrl+X removed the selection")
            sink.text = ""
            sink.forceActiveFocus()
            keyClick(Qt.Key_V, Qt.ControlModifier)
            compare(sink.text, "z", "and copied it first")
        }

        function test_ctrl_delete_to_the_ends() {
            guarded.forceActiveFocus()
            keyClick(Qt.Key_A); keyClick(Qt.Key_B); keyClick(Qt.Key_C); keyClick(Qt.Key_D)
            keyClick(Qt.Key_Left); keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Delete, Qt.ControlModifier)
            compare(guarded.text, "ab")
            keyClick(Qt.Key_Backspace, Qt.ControlModifier)
            compare(guarded.text, "")
        }

        function test_textfield_variant() {
            guardedField.forceActiveFocus()
            keyClick(Qt.Key_7); keyClick(Qt.Key_Backspace); keyClick(Qt.Key_8)
            compare(guardedField.text, "8")
            keyClick(Qt.Key_V, Qt.ControlModifier)
            compare(guardedField.text, "8")
            compare(root.routed, 1)
        }

        function test_caret_follows_focus() {
            guarded.forceActiveFocus()
            verify(guarded.cursorVisible, "cursorVisible follows focus despite readOnly")
            var caret = null
            for (var i = 0; i < guarded.children.length; i++)
                if (guarded.children[i].color !== undefined && guarded.children[i].width === 2) caret = guarded.children[i]
            verify(caret !== null, "the cursorDelegate was created")
            verify(caret.visible, "the caret shows while focused")
            sink.forceActiveFocus()
            verify(!guarded.cursorVisible, "cursorVisible drops with focus")
            verify(!caret.visible, "the caret hides when focus leaves")
        }
    }
}
