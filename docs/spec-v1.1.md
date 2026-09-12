# v1.1 spec — interaction, recovery and local settings

Approved 2026-09-04. This document is the authoritative delta to
[the v1 spec](spec-v1.md): v1 remains the regression baseline except where
this document explicitly replaces it. [decisions.md](decisions.md) records
the reasons; this file records required behaviour.

## 1. Key arrangement and controls

- Keep one Super key on the left; remove the duplicate right Super.
- Arrange arrows as an own-styled inverted T. Microsoft artwork and assets
  are not copied.
- Row widths follow the owner-supplied Windows reference, measured from a
  screenshot: a 15.5-unit row on a half-unit lattice with the classic
  stagger, so adjacent rows' gap lines interleave and Enter's left edge
  sits at the up arrow's middle. The page key closes the command row in the
  bottom-right slot; a Del cap ends the main page's second row.
- Fn remains a session-only semantic toggle. It replaces the top row in
  place and never changes panel height or the docked exclusive zone.
- The emoji cap displays `☺` and launches the configured picker. The default
  picker is Omarchy's own default emoji app (`omarchy-menu-emoji`, verified
  against Omarchy 4.0.2: it toggles the shell's own emoji overlay); the
  settings popover's Emoji app row chooses among the pickers detected on
  PATH, persisted as a sparse `emoji_app` override, and an override may name
  any app. A configured picker missing from PATH raises the existing
  transient hint, naming the configured app. (2026-09-06 amendment, ticket
  08: replaces the v1.1 one-shot courtesy move.) After a standalone picker's
  window maps, the panel fits it into a clear region of the same output in
  one logical coordinate system: above the keyboard first — resizing the
  picker shorter, scrollable, when it is taller than the space — then a
  fitting side region; where no region can take the picker, the panel
  exposes that constraint instead of declaring an overlapping placement
  successful. Every placement is verified against the resulting rectangle,
  not the dispatch's exit code. Placement recomputes on panel drag,
  dock/float, preset, picker resize, output removal and scale changes,
  without polling, and moves only the window the panel's own launch
  identified. A picker that is a shell overlay, not a client window, is
  Omarchy's own placement and is left alone. For Emote, selection or Escape
  closes it (its own single-instance behaviour over the existing
  `stay_focused` rule); click-away dismissal is not promised.

## 2. Modifier semantics

- Shift latches immediately for the next non-modifier press; double-clicking
  Shift locks it until clicked again.
- Ctrl, Alt and Super latch immediately for the next non-modifier press and
  cannot lock. Clicking a latched one cancels it, so a double click ends idle.
- Latched modifiers still stack and are consumed only by a non-modifier key.
- Caps remains an immediate, persistent semantic toggle affecting letters
  only. It emits no physical Caps position. Fn remains a semantic toggle.
- The only lock hint is `Double-click Shift to lock`.

## 3. Pages and symbols

`&123`, `ABC` and symbol-page controls act immediately and lose no rapid
clicks. Page changes do not resize the panel, consume latches, alter the
active group or replace the keymap.

Page 1 remains derived from the active group's compiled keymap. It is loaded
deterministically on cold start even when the detected layout equals the
initial default. A visible cap must never be silently blank: unresolved
keymap-wide state produces a clear unavailable/error state; an unavailable
optional page-2 symbol is visibly disabled or omitted.

Page 2 has a stable curated arrangement for currency, mathematics,
typographic punctuation, brackets, legal marks and common symbols. A symbol
is enabled only when a key position and level in the complete active XKB
keymap can produce it. Recompute availability when the configured keymap
changes. Show page 2 only when at least eight curated symbols are available.
The panel never uses clipboard mutation, toolkit Unicode entry, an IME/text
protocol, or temporary/per-symbol keymap replacement to type a symbol.

The symbols page (the page the `&123` key opens) is built from DUAL-LEVEL
caps with no built-in characters: every non-letter position the alphanumeric
block carries draws its keymap levels stacked — shifted on top, base on
bottom — with the emphasis swapping on Shift and the typed level following
Shift under the main page's ordinary pairing semantics (a latched or locked
Shift applies to these presses and is consumed by them; they are not
`exact`). Digits type from this page without leaving it. A level the keymap
does not carry is a §11 miss; a position with neither level resolving draws
dim and refuses presses (§3).

## 4. Geometry

Docked mode reserves exactly the visible panel height. Non-fullscreen tiled
windows end at or above the panel; fullscreen behaviour remains the v1
exception. Reservation cannot guarantee that another client preserves its
internal bottom scroll position, chat composer or caret after resize.

Preset changes preserve bottom-centre in docked mode. Floating mode preserves
the card centre, clamped only enough to keep the complete card on its output;
saved placement uses that deterministic anchor. Sizes are chosen from the
direct M/L/XL chooser inside the settings popover (§5) — the header carries
no size control; choosing the active preset moves nothing.

## 5. Settings and configuration

The gear opens a compact popover anchored at the top-left under the gear. It
does not replace the key grid or resize the panel, and closes on outside click
or Escape. Changes apply immediately; there is no Save or rollback-on-close.
The one exception is colour text entry (below): a hex field's unapplied text
is a local draft, not an applied setting. Each override can be reset.
Reset-all requires confirmation. Choosing the already-active size preset
inside the settings popover deliberately leaves the popover open — a settings
surface persists through use — while the size change itself still preserves
§4's no-movement guarantee.

Approved fields are: docked/floating mode, M/L/XL size, the emoji picker
app, sound on/off, follow Omarchy theme, key radius, panel radius, key
background, panel background, text colour, accent/active colour and border
colour. Custom sound files, volume, fonts, spacing and opacity are out of
scope.

(2026-09-06 amendment, owner-requested — replaces the always-visible
embedded colour pickers and their immediate writes while dragging.) Each
colour row shows up to four theme-derived quick swatches — the current
theme's background, foreground, accent and muted colour, with maintained
fallbacks when a token is unanswered and duplicate resolved colours removed —
and clicking one immediately writes that resolved colour as an override. A
later theme change must not silently rewrite a colour chosen this way.
Besides the swatches, each row carries an editable hex field with a small
adjacent mouse-clickable Apply button, a Custom colour control, and the
per-override reset.

The hex field's text is a local draft until Apply: invalid or incomplete
text stays editable, shows an inline error, and writes nothing; Enter may
commit but is never required; Apply captures the current draft before any
focus-loss dismissal can drop it. Custom colour opens one larger, separate
editor for the selected setting — a generous colour plane, usable hue and
brightness controls, a synchronized hex field, and a clear old/new preview —
with local preview and explicit Apply and Cancel; Cancel or dismissal drops
only that editor's uncommitted draft, previously applied settings survive,
and every other control's immediate behaviour is unchanged. No RGB/HSL mode
menus, saved palettes, colour history or additional opacity controls are
provided.

The typed-hex entry is the panel's ONE sanctioned keyboard-focus exception
(2026-09-04 amendment, owner-requested; extended 2026-09-06 to the custom
editor's hex field). While a hex field is active the layer surface takes
keyboard focus — a brief Exclusive prime acquiring it, OnDemand holding it,
Omarchy's own KeyboardPanel pattern — and the moment the entry ends (Apply,
Escape, or an outside click or the popover closing dismissing it) the surface
returns to `WlrKeyboardFocus.None`. No other control, on any other row, ever
takes keyboard focus. The entry accepts the same hex grammar the Config.js
validation holds every other colour write to; an invalid entry is refused
inline, writes nothing, and stays active for correcting.

The OSK itself must be able to enter and correct a whole hex value with no
physical keyboard (2026-09-06 amendment). That self-editing routes locally
into the selected field: the panel presents a temporary local hex-entry pad —
`#`, the digits, `A`–`F`, and caret/delete/select controls — and inserts its
input straight into the draft. Draft characters and modifier chords never
reach the previously focused application or the helper; the system keymap is
never replaced and the selected group never changes; `#`, the digits and
`A`–`F` stay available under every configured layout; the dismissal mask
never swallows the pad's own clicks; and the ordinary page and modifier
state is left exactly as it was.

Configuration has three roles:

1. Complete maintainer defaults shipped with the plugin.
2. Sparse user overrides at `$XDG_CONFIG_HOME/omarchy-osk/config.json`.
3. Geometry/state at `$XDG_STATE_HOME/omarchy-osk/state.json`.

Effective appearance is user override, then a live Omarchy theme token, then
the shipped fallback. GUI writes are atomic. Valid external file changes
reload without polling and update an open GUI. A malformed edit leaves the
last valid runtime state intact, is not overwritten, and displays an inline
error. During development no compatibility migration is required: existing
OSK config and state may be replaced.

Every override key the panel writes uses the approved field's snake_case
name; that is the canonical spelling. An external edit may also use the
field's camelCase runtime spelling, and it is held to exactly the same
validation as the canonical name. If both spellings of one field appear,
the canonical spelling wins regardless of JSON order; an invalid value
under either spelling is a malformed edit with the preservation semantics
above. A key that names no approved field is an unknown field: it is
preserved verbatim across reloads and panel saves — except for a key the
runtime cannot hold as the override map's own property (notably
`__proto__`), which is dropped — and is never rewritten into a canonical
name, so serialization can never give an unvalidated key an approved
field's authority. (2026-09-06, review finding R5.)

## 6. Helper lifecycle and panel status

Normal installation and development provisioning enable and start
`omarchy-osk.service` for the graphical user session. Its existing one-second
systemd crash restart policy remains authoritative.

The panel distinguishes starting/configuring, unavailable, incompatible and
ready states without adding a heartbeat or status poll. While not ready,
input-producing caps are disabled; Close, Settings, mode, size, Caps and Fn
remain usable. A compact friendly header notice names
`omarchy-osk.service`, does not resize the keyboard, and disappears after the
existing socket handshake succeeds.

For an unavailable service, Retry may run
`systemctl --user start omarchy-osk.service` and reconnect. A protocol
mismatch says the input service needs updating and offers Copy install
command plus Retry; the panel never silently builds, installs, escalates or
loops notifications.

## 7. Theme refresh ownership

The OSK continues to consume theme values through its single Theme facade.
Live updates of shared Omarchy theme tokens, including Hyprland rounding,
belong to Omarchy's shared Style provider. The OSK must not add a second
Hyprland/style reader. Local radius and colour overrides apply immediately.
Until the shared cross-repository change lands, a shell restart is an honest
known limitation for externally changed Hyprland rounding.

## 8. Regression and evidence

All accepted v1 behaviour remains required: focus retention, safe physical
keyboard selection and language switching, complete-keymap coupling,
XWayland input, byte-identical configure short-circuiting, bounded keymap
churn, contiguous hit areas, rapid taps, compositor repeat, stuck-key cleanup,
sound, theme switching, panel invocation, output selection and fixed-height
Fn switching.

Use only the two product seams in v1 §15: the control socket in a nested
Hyprland session and the pure modifier reducer. Helper unit tests remain
allowed. Panel geometry, appearance, pointer feel, popovers, emoji picker
behaviour and shared-Style refresh require VM screenshots or host hand
verification as appropriate. Modifier feel is judged on the host, because
VM latency makes that evidence invalid.

## 9. Deferred

Licence ticket 12, arbitrary Unicode insertion, custom sounds and volume,
font/spacing/opacity controls, app-specific docked scrolling workarounds and
backward-compatible OSK config migration are not part of v1.1.
