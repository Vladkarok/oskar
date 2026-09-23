import QtQuick
import qs.Commons
import "Config.js" as ConfigFile

// The panel's one reader of Omarchy's shared style tokens.
//
// Every colour, font and radius the keyboard draws with comes from `Color`
// and `Style`, which are singletons the shell reassigns when the theme
// changes — so an ordinary QML binding through here redraws the keyboard
// live, with no restart of the shell or the plugin, and without touching the
// keymap or the helper socket. That is the whole of `follow_theme: true`, and
// it is why there are no colour literals anywhere in the panel.
//
// The indirection exists for the other half: `follow_theme: false` stops the
// keyboard tracking theme changes and does nothing else in v1.
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
// there. While following-off the snapshot is held for as long as that state
// lasts: re-enabling following releases it (release()), so a later flip to
// following-off freezes the tokens as they are THEN — each stop holds the
// moment it stopped at, never a replay of an older look.
//
// Overrides resolve in three tiers: user override, then the live (or
// frozen) shared token, then the shipped fallback. The
// panel binds this facade's `overrides` to its sparse user-override map, and
// the resolved properties below check their override first and fall back to
// exactly the token they resolved to before overrides existed — so an
// explicit field wins over the theme for that field while the rest keep
// following (or stay frozen), and every resolved read stays a binding on
// `overrides` plus the singletons, which is what makes both external config
// edits and theme switches redraw immediately. Theme remains the OSK's only
// reader of shared tokens; overrides arrive here already validated by
// Config.js and never touch Hyprland or the shell's style files.
QtObject {
    id: theme

    property bool follow: true
    property var held: null
    // The sparse user-override map (camelCase keys, already validated). Bound
    // in from the panel; never written here.
    property var overrides: ({})

    readonly property bool frozen: !follow && held !== null

    // Whether one appearance field carries an explicit user override right
    // now. Reads `overrides` so bindings that call it re-evaluate when the
    // map changes. The owns test is Config.js's — one home for the map's
    // shape, as for its validation and serialization.
    function hasOverride(name) {
        return ConfigFile.owns(overrides, name)
    }

    // The third precedence tier: with no override and no token answer, an
    // appearance field resolves to what Config.js ships — read from Config.js
    // rather than spelled here, so the shipped defaults keep their one home.
    // The shell answers every token in a normal session, so the tier only
    // shows outside one: an undeclared token reads undefined, and a colour
    // still at the singletons' unset default is fully transparent, which
    // would paint nothing.
    function colorAnswered(token) {
        return token !== undefined && token !== null && token !== "" && token.a > 0
    }
    function valueAnswered(token) {
        return token !== undefined && token !== null
    }
    function shippedColor(name) {
        return Qt.color(ConfigFile.maintainerDefaults()[name])
    }

    // Hold the tokens as they are right now. No-op while a snapshot is
    // already held — call release() when following re-enables so the next
    // stop here freezes fresh values.
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
            cardBorderSpec: Border.hyprlandActiveSpec(Color.accent, 2),
            cardBorderToken: Border.value("hyprland", "active-border")
                || Border.value("notifications", "border")
        }
    }

    // Drop the held snapshot so the keyboard tracks the live tokens again.
    // Meaningless while already following (held is only read when frozen),
    // which is exactly when the panel calls it.
    function release() {
        held = null
    }

    readonly property color foreground: frozen ? held.foreground : Color.foreground
    readonly property color background: frozen ? held.background : Color.background
    // Theme-derived accent, ignoring a user accentColor override. Colour-row
    // swatches stay recommendations from the current (or frozen) Omarchy
    // theme; pinning an accent must not replace that swatch with itself.
    readonly property color themeAccent: colorAnswered(frozen ? held.accent : Color.accent)
        ? (frozen ? held.accent : Color.accent)
        : shippedColor("accentColor")
    // The accent and the latched "selected" tint are one override field:
    // an explicit accent wins for
    // both, with the selected fill re-tinted at the same alpha the theme's
    // own selected fill carries, so latched keys stay a lighter wash of the
    // accent and locked keys stay solid — one hue choice, the state weights
    // stay the theme's.
    readonly property color accent: hasOverride("accentColor")
        ? overrideAsColor("accentColor")
        : themeAccent
    readonly property color urgent: frozen ? held.urgent : Color.urgent
    readonly property color muted: frozen ? held.muted : Color.muted
    readonly property color popupsBackground: frozen ? held.popupsBackground : Color.popups.background
    // The latched modifier's tint. A shared token rather than an alpha this
    // file picks, so a theme that says what "selected" looks like is obeyed.
    readonly property color themeSelectedFill: frozen ? held.selectedAccentFill : Style.selectedAccentFill
    readonly property color selectedAccentFill: hasOverride("accentColor")
        ? Util.alpha(overrideAsColor("accentColor"), themeSelectedFill.a) : themeSelectedFill

    // Panel background (the card) and text: the override, else the token the
    // keyboard has always drawn with. The text override is scoped to the
    // keyboard's own glyph colour — the theme's `muted` stays the answer for
    // secondary text, since "dim" is a relation to the theme's palette, not
    // to one user-chosen colour.
    function overrideAsColor(name) {
        var raw = overrides[name]
        if (typeof raw === "string") return Qt.color(raw)
        return raw
    }

    readonly property color panelBackground: hasOverride("panelBackground")
        ? overrideAsColor("panelBackground")
        : colorAnswered(popupsBackground) ? popupsBackground
        : shippedColor("panelBackground")
    readonly property color textColor: hasOverride("textColor")
        ? overrideAsColor("textColor")
        : colorAnswered(foreground) ? foreground
        : shippedColor("textColor")
    // The keys' resting fill: always opaque. A translucent override
    // (host #0ad4d4d4) is painted onto the panel first — using its RGB
    // as the cap makes hover an opaque pale square. No override is an
    // opaque mix of the panel with the foreground at the theme's resting
    // alpha. No answered foreground falls through to the shipped colour.
    readonly property color keyFill: {
        var raw = hasOverride("keyBackground")
            ? overrides.keyBackground
            : colorAnswered(foreground)
                ? mixColor(panelBackground, foreground, normalFillAlpha)
                : shippedColor("keyBackground")
        var stacked = ConfigFile.compositeOnto(panelBackground, raw)
        return Qt.rgba(stacked.r, stacked.g, stacked.b, 1)
    }
    // Hover and press are a modest mix of that resting cap toward the
    // theme foreground (Config.js clamps the mix). Follow-theme with no
    // colour override is the path that must stay a key of the current
    // theme; a pinned key-background uses the same mix so hover cannot
    // get worse than follow-theme.
    readonly property color keyHoverFill: mixColor(keyFill, keyForeground,
        ConfigFile.keyHoverMix(hoverFillAlpha))
    readonly property color keyActiveFill: mixColor(keyFill, keyForeground,
        ConfigFile.keyPressMix(pressedFillAlpha,
            ConfigFile.keyHoverMix(hoverFillAlpha)))
    readonly property color keyForeground: colorAnswered(foreground)
        ? foreground : shippedColor("textColor")

    // Opaque mix of `base` toward `target` at `amount`. Popover chrome still
    // calls this as a foreground overlay; key hover/press go through
    // Config.js's clamped mix so a high theme alpha cannot bleach a cap.
    function mixColor(base, target, amount) {
        var mixed = ConfigFile.mixRgb(base, target, amount)
        return Qt.rgba(mixed.r, mixed.g, mixed.b, 1)
    }

    // Composites the foreground over `base` at opacity `a` — the colour that
    // painting foreground@a onto base produces. Chrome (popover card, etc.)
    // still uses this; keys do not.
    function tintTowardForeground(base, a) {
        return mixColor(base, keyForeground, a)
    }

    // The raw shared rounding token, carried as declared (var, not int): an
    // int binding coerces an absent token to 0, and a coerced 0 reads as
    // answered by `valueAnswered`, which would bypass the shipped 8/12
    // fallbacks capCorner and panelRadius exist to apply. An explicit zero
    // stays a valid answer — it arrives as a validated override (checked
    // first below) or from a theme that really declared zero.
    readonly property var cornerRadius: frozen ? held.cornerRadius : Style.cornerRadius
    // Key and panel rounding split the one shared cornerRadius token into two
    // fields; with no override both are the token, so
    // a following keyboard rounds exactly as it did before overrides existed.
    readonly property int capCorner: hasOverride("capCorner")
        ? overrides.capCorner
        : valueAnswered(cornerRadius) ? cornerRadius
        : ConfigFile.maintainerDefaults().capCorner
    readonly property int panelRadius: hasOverride("panelRadius")
        ? overrides.panelRadius
        : valueAnswered(cornerRadius) ? cornerRadius
        : ConfigFile.maintainerDefaults().panelRadius
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
    // and taking it apart here would be this file inventing a border. The
    // precedence chain is complete for the border as one field: an
    // explicit border override replaces the whole spec with a flat one at
    // the card's shipped border weight; the theme's own token — the
    // `[hyprland] active-border` value, or the `[notifications] border`
    // compatibility value older generated themes carry — is the second
    // tier, frozen as the snapshot took it; and a theme that declares no
    // border token at all falls through to the shipped border colour rather
    // than borrowing the accent silently.
    readonly property string borderToken: frozen ? held.cardBorderToken
        : (Border.value("hyprland", "active-border")
            || Border.value("notifications", "border"))
    readonly property var cardBorderSpec: hasOverride("borderColor")
        ? Border.flat(overrides.borderColor, 2)
        : borderToken !== "" ? (frozen ? held.cardBorderSpec
            : Border.hyprlandActiveSpec(theme.accent, 2))
        : Border.flat(shippedColor("borderColor"), 2)

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
