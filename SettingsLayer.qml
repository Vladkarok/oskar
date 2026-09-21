import QtQuick
import Quickshell
import "SettingsPlacement.js" as SettingsPlacement

Item {
    id: root

    // The settings layer's content, split out of Panel.qml (the
    // structural split's step five): the leftover geometry engine
    // (overlayBox/bandBox/leftoverBox and the three centre placements),
    // the input-mask Region the window binds, the everywhere-outside
    // dismiss area, and the popover/editor hosting — SettingsPopover
    // and SettingsColorEditor instantiated here, at the layer's
    // coordinates, exactly where the monolith had them. What stayed in
    // the panel is everything the layer is a WINDOW for: the surface
    // flags, the WLR focus contract (keyboardFocus — hex editing and
    // the armed search prime on panel state), and the two focus sinks
    // (endHexEdit's parking spots, plain Items the panel still names);
    // the emoji page and its placement machinery (applyEmojiPosition/
    // rememberEmojiPosition) stay panel-side too — the page is not a
    // settings surface, so it remains a direct child of the window and
    // reads the geometry engine's boxes back through this component's
    // readonly surface.
    //
    // The seam's shape, chosen and why: the panel-root facts the moved
    // code touches (customEditorField, emojiOpen, mode, the editor's
    // label/old-colour, and the endHexEdit/closeCustomEditor/
    // openCustomEditor calls) all ride the `panel` reference the
    // popover already took — one access path, and the only honest one
    // for emojiOpen, which the dismiss area WRITES (a mirrored IN
    // property would fork that write off a copy). The ids the moved
    // code read that are not panel-root properties — tokens, card, and
    // the emoji page itself — ride their own IN properties, named as
    // the monolith named them so the moved bindings keep their shape.

    // ---- IN from the panel ----
    //
    // The panel root: the popover/editor's own `panel` prop chain, and
    // every panel-root fact the geometry engine and the dismiss area
    // read (and the one they write).
    property var panel: null
    // The theme facade the popover and the editor draw with.
    property var tokens: null
    // The keyboard card — the band the leftover is computed around
    // (SettingsPlacement.overlayBand's second argument, live).
    property var card: null
    // The emoji page item: the mask's page rect and the dismiss area's
    // page hit-test read it live; the page itself stays in Panel.qml,
    // a sibling of this component inside the settings window.
    property var emojiPage: null

    // Any leftover-centre surface: the settings card, the custom
    // colour editor, or the emoji page (ticket 24). The mask and the
    // dismiss area arm on this, and never on the keyboard band.
    readonly property bool overlayOpen: settingsPopover.visible
        || root.panel.customEditorField !== ""
        || root.panel.emojiOpen
    // Ticket 29: the page alone is non-modal — the card and the editor
    // keep the modal leftover (an outside click dismisses them), but
    // with only the page standing the input region is the page's own
    // rectangle, so a press on the client behind it reaches that
    // client: focus moves, the rawEvent disarm routes the keys there,
    // and the page stays up for the next pick.
    readonly property bool emojiPageSolo: root.panel.emojiOpen
        && !settingsPopover.visible && root.panel.customEditorField === ""
    readonly property var overlayBox: ({
        x: 0, y: 0, w: root.width, h: root.height
    })
    readonly property var bandBox: SettingsPlacement.overlayBand(
        root.panel.mode, overlayBox,
        { x: root.card.x, y: root.card.y, w: root.card.width, h: root.card.height })
    readonly property var leftoverBox: SettingsPlacement.overlayInputRect(
        overlayBox, bandBox)
    readonly property var popoverPlace: SettingsPlacement.centreInLeftover(
        overlayBox, bandBox,
        { w: settingsPopover.width, h: settingsPopover.height })
    readonly property var editorPlace: SettingsPlacement.centreInLeftover(
        overlayBox, bandBox,
        { w: customColorEditor.width, h: customColorEditor.height })
    readonly property var emojiPlace: SettingsPlacement.centreInLeftover(
        overlayBox, bandBox,
        { w: root.emojiPage.width, h: root.emojiPage.height })

    // The input mask the window binds: empty until an overlay opens,
    // then the leftover (or, with only the page standing, the page's
    // own rectangle — the solo non-modal pass-through) unioned with the
    // popover's, the editor's and the page's rects, so Custom on the
    // band still receives clicks without a bounding-box over keys.
    readonly property Region inputMask: Region {
        x: root.overlayOpen
            ? (root.emojiPageSolo ? root.emojiPage.x
                : root.leftoverBox.x) : 0
        y: root.overlayOpen
            ? (root.emojiPageSolo ? root.emojiPage.y
                : root.leftoverBox.y) : 0
        width: root.overlayOpen
            ? (root.emojiPageSolo ? root.emojiPage.width
                : root.leftoverBox.w) : 0
        height: root.overlayOpen
            ? (root.emojiPageSolo ? root.emojiPage.height
                : root.leftoverBox.h) : 0
        Region {
            x: settingsPopover.x
            y: settingsPopover.y
            width: settingsPopover.visible ? settingsPopover.width : 0
            height: settingsPopover.visible ? settingsPopover.height : 0
            intersection: Intersection.Combine
        }
        Region {
            x: customColorEditor.x
            y: customColorEditor.y
            width: customColorEditor.visible ? customColorEditor.width : 0
            height: customColorEditor.visible ? customColorEditor.height : 0
            intersection: Intersection.Combine
        }
        Region {
            x: root.emojiPage.x
            y: root.emojiPage.y
            width: root.emojiPage.visible ? root.emojiPage.width : 0
            height: root.emojiPage.visible ? root.emojiPage.height : 0
            intersection: Intersection.Combine
        }
    }

    MouseArea {
        x: root.leftoverBox.x
        y: root.leftoverBox.y
        width: root.overlayOpen ? root.leftoverBox.w : 0
        height: root.overlayOpen ? root.leftoverBox.h : 0
        enabled: root.overlayOpen
        z: 0
        onClicked: function (mouse) {
            if (settingsPopover.visible
                && mouse.x + x >= settingsPopover.x
                && mouse.x + x <= settingsPopover.x + settingsPopover.width
                && mouse.y + y >= settingsPopover.y
                && mouse.y + y <= settingsPopover.y + settingsPopover.height)
                return
            if (customColorEditor.visible
                && mouse.x + x >= customColorEditor.x
                && mouse.x + x <= customColorEditor.x + customColorEditor.width
                && mouse.y + y >= customColorEditor.y
                && mouse.y + y <= customColorEditor.y + customColorEditor.height)
                return
            if (root.emojiPage.visible
                && mouse.x + x >= root.emojiPage.x
                && mouse.x + x <= root.emojiPage.x + root.emojiPage.width
                && mouse.y + y >= root.emojiPage.y
                && mouse.y + y <= root.emojiPage.y + root.emojiPage.height)
                return
            root.panel.endHexEdit()
            if (root.panel.customEditorField !== "") {
                root.panel.closeCustomEditor()
                return
            }
            settingsPopover.visible = false
            root.panel.emojiOpen = false
        }
    }

    SettingsPopover {
        id: settingsPopover
        panel: root.panel
        tokens: root.tokens
        hostWidth: root.leftoverBox.w
        hostHeight: root.leftoverBox.h
        x: root.popoverPlace.x
        y: root.popoverPlace.y
        z: 1
        onCustomColourRequested: function (fieldName, labelText) {
            root.panel.openCustomEditor(fieldName, labelText)
        }
    }

    SettingsColorEditor {
        id: customColorEditor
        panel: root.panel
        tokens: root.tokens
        fieldName: root.panel.customEditorField
        labelText: root.panel.customEditorLabel
        visible: root.panel.customEditorField !== ""
        oldColor: root.panel.customEditorOldColor
        hostWidth: root.leftoverBox.w
        hostHeight: root.leftoverBox.h
        x: root.editorPlace.x
        y: root.editorPlace.y
        z: 2
        onDismissed: root.panel.closeCustomEditor()
    }

    // ---- OUT to the panel ----
    //
    // The header chrome's read (the gear and the language chip key on
    // the popover standing), and the panel's open/close calls — one
    // function per intent instead of a writable alias, the smaller
    // surface for the four read sites and four write sites the
    // monolith had. resetAllArmed only ever clears, so it clears
    // through its own name; the two insert targets keep the branch the
    // panel's insertLocalClipboardText always made.
    readonly property bool popoverVisible: settingsPopover.visible
    function openPopover() { settingsPopover.visible = true }
    function closePopover() { settingsPopover.visible = false }
    function disarmResetAll() { settingsPopover.resetAllArmed = false }
    function adoptAppliedColour(name, value) {
        settingsPopover.adoptAppliedColour(name, value)
    }
    function popoverInsertHexText(text) { settingsPopover.insertHexText(text) }
    function editorInsertHexText(text) { customColorEditor.insertHexText(text) }
}
