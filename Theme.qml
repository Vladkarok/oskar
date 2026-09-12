import QtQuick
import qs.Commons

// The panel's one reader of Omarchy's shared style tokens (spec-v1 §8).
//
// Every colour, font and radius the keyboard draws with comes from `Color`
// and `Style`, which are singletons the shell reassigns when the theme
// changes — so an ordinary QML binding through here redraws the keyboard
// live, with no restart of the shell or the plugin, and without touching the
// keymap or the helper socket. That is the whole of `follow_theme: true`, and
// it is why there are no colour literals anywhere in the panel.
//
// The indirection exists for the other half: `follow_theme: false` (spec-v1
// §10) stops the keyboard tracking theme changes and does nothing else in v1.
// It is implemented by holding one snapshot of the tokens and reading from it
// instead of from the singletons — a binding that never reads `Color` cannot
// be re-evaluated when `Color` changes, so the keyboard simply stays as it
// was. The independent colour schema is v2; this is only the escape hatch.
//
// The snapshot is taken when the panel is first shown rather than when the
// plugin loads: the shell reads the theme's files asynchronously, and a
// snapshot taken at load could catch the singletons' built-in defaults and
// freeze the keyboard onto a theme nobody chose. Nothing is on screen before
// the first open, so nothing visible ever changes as a result of taking it
// there, and it is taken exactly once — a later open does not re-read the
// theme, which is what "stops tracking" has to mean.
QtObject {
    id: theme

    property bool follow: true
    property var held: null

    readonly property bool frozen: !follow && held !== null

    function freeze() {
        if (held) return
        held = {
            foreground: Color.foreground,
            background: Color.background,
            accent: Color.accent,
            urgent: Color.urgent,
            muted: Color.muted,
            popupsBackground: Color.popups.background,
            selectedAccentFill: Style.selectedAccentFill,
            cornerRadius: Style.cornerRadius,
            normalBorderWidth: Style.normalBorderWidth,
            focusBorderWidth: Style.focusBorderWidth,
            normalFillAlpha: Style.normalFillAlpha,
            hoverFillAlpha: Style.hoverFillAlpha,
            pressedFillAlpha: Style.pressedFillAlpha,
            fontFamily: Style.font.family,
            fontBody: Style.font.body,
            fontBodySmall: Style.font.bodySmall,
            spacingSm: Style.spacing.sm,
            spacingMd: Style.spacing.md,
            spacingLg: Style.spacing.lg,
            popupPadding: Style.spacing.popupPadding,
            spacingScale: Style.spacing.scale,
            cardBorderSpec: Border.hyprlandActiveSpec(Color.accent, 2)
        }
    }

    readonly property color foreground: frozen ? held.foreground : Color.foreground
    readonly property color background: frozen ? held.background : Color.background
    readonly property color accent: frozen ? held.accent : Color.accent
    readonly property color urgent: frozen ? held.urgent : Color.urgent
    readonly property color muted: frozen ? held.muted : Color.muted
    readonly property color popupsBackground: frozen ? held.popupsBackground : Color.popups.background
    // The latched modifier's tint. A shared token rather than an alpha this
    // file picks, so a theme that says what "selected" looks like is obeyed.
    readonly property color selectedAccentFill: frozen ? held.selectedAccentFill : Style.selectedAccentFill

    readonly property int cornerRadius: frozen ? held.cornerRadius : Style.cornerRadius
    readonly property int normalBorderWidth: frozen ? held.normalBorderWidth : Style.normalBorderWidth
    readonly property int focusBorderWidth: frozen ? held.focusBorderWidth : Style.focusBorderWidth
    readonly property real normalFillAlpha: frozen ? held.normalFillAlpha : Style.normalFillAlpha
    readonly property real hoverFillAlpha: frozen ? held.hoverFillAlpha : Style.hoverFillAlpha
    readonly property real pressedFillAlpha: frozen ? held.pressedFillAlpha : Style.pressedFillAlpha

    readonly property string fontFamily: frozen ? held.fontFamily : Style.font.family
    readonly property int fontBody: frozen ? held.fontBody : Style.font.body
    readonly property int fontBodySmall: frozen ? held.fontBodySmall : Style.font.bodySmall

    readonly property int spacingSm: frozen ? held.spacingSm : Style.spacing.sm
    readonly property int spacingMd: frozen ? held.spacingMd : Style.spacing.md
    readonly property int spacingLg: frozen ? held.spacingLg : Style.spacing.lg
    readonly property int popupPadding: frozen ? held.popupPadding : Style.spacing.popupPadding

    // The card's border, which a theme can give its own colour, width and
    // gradient through `[hyprland] active-border`. Held whole rather than
    // re-derived from the frozen accent: what the shell hands out is one spec,
    // and taking it apart here would be this file inventing a border.
    readonly property var cardBorderSpec: frozen ? held.cardBorderSpec
        : Border.hyprlandActiveSpec(theme.accent, 2)

    // `Style.space` in the same shape: the theme's spacing scale applied to a
    // pixel value. Frozen, the scale is the one from the snapshot; the
    // rounding and the 1px floor are Style's, kept identical so a frozen
    // keyboard is the same geometry as a following one on the same theme.
    function space(px) {
        if (!frozen) return Style.space(px)
        var n = Number(px)
        if (!isFinite(n) || n <= 0) return 0
        return Math.max(1, Math.round(n * held.spacingScale))
    }
}
