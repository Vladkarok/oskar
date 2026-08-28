import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "io.github.vladkarok.osk"

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\u2328"
        tooltipText: "Toggle On-Screen Keyboard"
        onPressed: function(buttonCode) {
            if (!root.bar) return
            root.bar.run("omarchy-shell shell toggle io.github.vladkarok.osk")
        }
    }
}
