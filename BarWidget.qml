import QtQuick
import qs.Commons
import qs.Ui

// The bar entry for the panel: one icon that flips the keyboard's
// visibility through the shell IPC, so the bar and the panel itself can
// never disagree about who owns the toggle.
BarWidget {
    id: root
    moduleName: "io.github.vladkarok.oskar"

    implicitWidth: toggle.implicitWidth
    implicitHeight: toggle.implicitHeight

    WidgetButton {
        id: toggle
        anchors {
            fill: parent
        }
        bar: root.bar
        text: "⌨"
        tooltipText: "Show or hide the on-screen keyboard"
        onPressed: function() {
            if (!root.bar)
                return
            root.bar.run("omarchy-shell shell toggle io.github.vladkarok.oskar")
        }
    }
}
