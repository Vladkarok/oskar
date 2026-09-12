import QtQuick
import qs.Commons
import qs.Ui

// The bar entry for the panel (spec-v1 §2): one icon that flips the
// keyboard's visibility through the shell IPC, so the bar and the panel
// itself can never disagree about who owns the toggle.
BarWidget {
    id: root
    moduleName: "io.github.vladkarok.osk"

    implicitWidth: toggle.implicitWidth
    implicitHeight: toggle.implicitHeight

    WidgetButton {
        id: toggle
        anchors {
            fill: parent
        }
        bar: root.bar
        // The keyboard glyph as a literal, and the shell-API handler
        // spelled with the arg omitted where the contract allows.
        text: "⌨"
        tooltipText: "Show or hide the on-screen keyboard"
        onPressed: function() {
            if (!root.bar)
                return
            root.bar.run("omarchy-shell shell toggle io.github.vladkarok.osk")
        }
    }
}
