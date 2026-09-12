# v1.1 spec — interaction, recovery and local settings

Approved 2026-09-04. This document is the authoritative delta to
[the v1 spec](spec-v1.md): v1 remains the regression baseline except where
this document explicitly replaces it. [decisions.md](decisions.md) records
the reasons; this file records required behaviour.

## 1. Key arrangement and controls

- Keep one Super key on the left; remove the duplicate right Super.
  Super's cap draws Omarchy's compact mark: U+E900 from the installed
  `omarchy` icon font (`/usr/share/fonts/omarchy/omarchy.ttf`), the same
  mechanism the bar menu launcher uses. Source: Omarchy
  (`default/fonts/omarchy/omarchy.ttf` and `shell/plugins/menu/BarWidget.qml`),
  MIT, copyright David Heinemeier Hansson. The accessible name remains
  Super. Key position, hit area, latch/cancel semantics, and emitted
  chords are unchanged. If that font is missing, the cap shows the
  readable Super label rather than going blank. (2026-09-07, ticket 15)
- The header carries a current-content paste control at top centre
  (2026-09-07, ticket 14; preview 2026-09-08). A click pastes the CLIPBOARD
  selection into the intended client without writing clipboard contents and
  without taking panel focus. History stays out. When CLIPBOARD is empty
  the control is absent, not a disabled empty icon. When the payload is
  text the chip shows the start of that string on one line, elided to the
  chip width; a non-text payload keeps a clipboard glyph and no preview.
  Clipboard contents are observed by a watch or a bounded refresh on panel
  open and on paste click, never by polling. An open picker search field or
  a focused settings colour field (hex, RGB or HSV) is the intended target
  when it is the active input; otherwise the previously focused client is. Delivery must work for
  a native client, a terminal, and an XWayland client; Ctrl+V alone is not
  an accepted universal path. Latched Ctrl/Alt/Super are not mixed into the
  paste chord. This is an explicit user paste command, not a path for typing
  curated symbols (§3).
- Arrange arrows as an own-styled inverted T. Microsoft artwork and assets
  are not copied.
- Ordinary pages remain five rows this release. The main page keeps a
  dedicated digit row; an ordinary click on a digit cap types that digit.
  A four-row compact arrangement is not a v1.1 requirement
  ([compact-control-map.md](compact-control-map.md); decisions §28).
  (2026-09-07, ticket 11)
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
  dock/float, preset, output removal and scale changes, without polling,
  and moves only the window the panel's own launch identified. The picker
  session is armed before that process is started, so a fast map cannot
  arrive against a null session. Launch identity is bound once, after the
  StartupWMClass probe completes or fails, and is not recomputed from later
  openwindows; the executable-name fallback is not accepted until that
  probe has settled, so a concurrent same-class or fallback-class window
  that maps first cannot become the picker. Hyprland 0.56.2 has no
  client-geometry socket event (`movewindow`/`movewindowv2` is
  move-to-workspace; `resizewindow` is absent), so a picker-initiated
  resize is noticed on the next panel or output event, or the bounded
  re-observation that verifies the panel's own dispatch — not as a
  dedicated compositor event. (2026-09-07, ticket 10: replaces the
  shell-overlay placement exemption.) For Omarchy's own emoji overlay
  (`omarchy-menu-emoji` → `omarchy.emojis`) the emoji cap uses the
  shell's real open, hide, and open-state operations rather than a
  blind toggle or backdrop dismissal. An opt-in OSK invocation payload
  (`{"osk":true,…}`) carries the panel band, output box, and work area
  in PickerFit.js logical units; the overlay fits its inner card with
  `planPlacement` and subtracts the panel band from its input region so
  OSK clicks land. Ordinary standalone invocation — `omarchy-menu-emoji`
  with no OSK payload, Super+Period, the bar — keeps the existing
  fullscreen Exclusive centred card. OSK invocation primes keyboard
  focus with the shell KeyboardPanel Exclusive-then-OnDemand pattern so
  picker search receives virtual-keyboard input while the panel stays
  `WlrKeyboardFocus.None`; Exclusive is not held, because it routes
  pointer events to the overlay and blocks the OSK. Rapid presses,
  close while opening, selection, Escape (clear filter, then dismiss),
  panel close, picker-app change, and output/geometry changes settle
  through that open/hide/state contract. The overlay still inserts
  through `omarchy-menu-emoji-insert`; the panel restores the recorded
  client when it still exists and the user has not focused a different
  application, and does not paste again. Moving an ordinary client is
  not the overlay solution. For Emote the emoji cap owns one
  observed picker session — closed, opening, open, or closing — of the
  one appearance the launch bound. Closed → press starts Emote once and
  records the intended client; open → press dismisses that window with
  `closewindow` on its address, never a second `emote` exec (that
  destroy/recreates the picker) and never a process-name kill. A second
  press while opening cancels; a late map of the cancelled appearance is
  closed, not adopted. Panel close or picker-app change while opening
  keeps that closer until the window is gone or the mapping timeout
  closewindows the late launch address. A press while closing retries
  dismiss; a failed closewindow settles the session. An in-flight close
  is not aborted by starting another handoff and is pinned to the address
  that was closing — a later stay or map must not retarget it. Settle
  drops any queued handoff so a leftover close cannot closewindow the
  next appearance. Mashing ☺ while closing with no pin does not postpone
  the closer. Selection, Escape, panel
  close, picker-app change, process failure, and the bounded mapping
  timeout settle the session.
  A dead remembered openwindow is dropped so it cannot bind.
  Ordinary OSK stays `WlrKeyboardFocus.None`. Picker search is the
  deliberate external target: OSK presses type into it because Emote
  remains the compositor keyboard target, not because the panel takes
  focus. `stay_focused` on the identified window is unset for the
  session (a true value wins pointer hit-testing before overlays and
  blocks OSK clicks, including ☺ dismiss); it is not a class-wide rule
  and is not the keyboard-target path (`hl.dsp.focus` still moves the
  keyboard target). Click-away dismissal is not promised.
  On settle, focus returns to the recorded client when it still exists
  and the user has not focused a different application, before Emote's
  own delayed paste, with exactly one insertion.

## 2. Modifier semantics

- Shift latches immediately for the next non-modifier press; double-clicking
  Shift locks it until clicked again.
- Ctrl, Alt and Super latch immediately for the next non-modifier press and
  cannot lock. Clicking a latched one cancels it, so a double click ends idle.
- Latched modifiers still stack and are consumed only by a non-modifier key.
- Caps remains an immediate, persistent semantic toggle affecting letters
  only. It emits no physical Caps position. Fn remains a semantic toggle.
- Shift still locks on double-click. The header does not hint that.

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
changes. This release hosts those specials as pair caps on `&123` when they
fit. Show page 2 only when pair-slot capacity is exceeded and at
least eight curated symbols remain unhosted; do not open it merely because
eight or more curated tokens exist. The panel never uses clipboard mutation,
toolkit Unicode entry, an IME/text protocol, or temporary/per-symbol keymap
replacement to type a symbol.

The symbols page (the page the `&123` key opens) is built from DUAL-LEVEL
caps with no built-in characters: every non-letter position the alphanumeric
block carries draws its keymap levels stacked — shifted on top, base on
bottom — with the emphasis swapping on Shift and the typed level following
Shift under the main page's ordinary pairing semantics (a latched or locked
Shift applies to these presses and is consumed by them; they are not
`exact`). Digits type from this page without leaving it. A level the keymap
does not carry is a §11 miss; a position with neither level resolving draws
dim and refuses presses (§3).

Curated specials whose first occurrence is at keymap level 3 or 4 of an
alphanumeric-block position are **pair caps** on this same page: stacked
level 4 over level 3, Shift emphasises the upper half, and a press is
AltGr+position (non-exact, latch-applied Shift). Pair caps fill only for a
group whose compiled RALT is `ISO_Level3_Shift`. They occupy the current
8-unit spacer on the Shift…Enter row first, then — when more than eight pair
caps are needed — a fifth symbols row of fifteen unit slots plus a half-unit
pad, without raising pinned page height above five rows. That packing holds
the probed inventories (ua 12, fr 16, gb 19, de 21); us has none. Command
row, Fn-in-place, header and paste controls are unchanged.
(2026-09-07, ticket 11)

## 4. Geometry

Docked mode reserves exactly the visible panel height. Non-fullscreen tiled
windows end at or above the panel; fullscreen behaviour remains the v1
exception. Reservation cannot guarantee that another client preserves its
internal bottom scroll position, chat composer or caret after resize.

Preset changes preserve bottom-centre in docked mode. Floating mode preserves
the card centre, clamped only enough to keep the complete card on its output;
saved placement uses that deterministic anchor. Sizes are chosen from the
direct M/L/XL chooser inside the settings popover (§5) — the header carries
no size control and no Dock/Float control; mode lives only in Settings.
Choosing the active preset moves nothing. Key radius is a 0–24 integer
stored as a proportion of a medium key: 24 is fully rounded (a circle on a
square cap) at every preset because the drawn radius scales with key
height. Panel radius is a separate pixel control and does not scale with
the preset.

## 5. Settings and configuration

The gear opens a compact popover in the centre of leftover space: the
output minus the keyboard band (the docked exclusive-zone strip, or the
floating card). It is not glued to the keyboard's edge, and it stays
on-screen when the keyboard is parked at the top. It does not replace the
key grid or resize the panel, does not extend the docked exclusive zone,
and closes on leftover click or Escape. Covering the keys if leftover is
too small is accepted; the popover is not shrunk or fitted to avoid that.
While settings is open, OSK keys stay clickable and type into the
previously focused client, or into a focused colour field. Changes apply
immediately; there is no Save or rollback-on-close. The one exception is
colour text entry (below): a field's unapplied text is a local draft, not
an applied setting. Each override can be reset. Reset-all requires
confirmation. Choosing the already-active size preset inside the settings
popover deliberately leaves the popover open — a settings surface persists
through use — while the size change itself still preserves §4's
no-movement guarantee.

Approved fields are: docked/floating mode, M/L/XL size, the emoji picker
app, sound on/off, follow Omarchy theme, key radius, panel radius, key
background, panel background, text colour, accent/active colour and border
colour. Key radius 0–24 is relative to the medium preset so a stored 24
stays a circle at L and XL; panel radius is whole pixels. Key hover and
press are a modest mix of the resting key fill toward the theme
foreground — never a replacement fill that is the foreground itself —
so follow-theme caps stay keys of the current theme. Custom sound
files, volume, fonts, spacing and opacity are out of scope.

(2026-09-06 amendment, owner-requested — replaces the always-visible
embedded colour pickers and their immediate writes while dragging.) Each
colour row shows up to four theme-derived quick swatches — the current
theme's background, foreground, accent and muted colour, with maintained
fallbacks when a token is unanswered and duplicate resolved colours removed —
and clicking one immediately writes that resolved colour as an override. A
later theme change must not silently rewrite a colour chosen this way.
Besides the swatches, each row carries an editable hex field with a compact
mouse-only confirm control next to it, a Custom colour control, and the
per-override reset. Swatches sit on the same control group as that row's
label and hex field; they are not a shared strip across rows. There is no
full-width Apply word-button.

The hex field's text is a local draft until confirm: invalid or incomplete
text stays editable, shows an inline error, and writes nothing; confirm
captures the current draft before any focus-loss dismissal can drop it.
Confirm and Cancel are mouse-only. Custom colour opens one larger editor
for the selected setting, still in leftover-centre, never as a key-grid
overlay: a large hue×saturation square, a thin value/brightness slider that
does not duplicate the square, an optional solid swatch, a hex field, and
an RGB/HSV mode switch with three numeric fields. Local preview; explicit
confirm and Cancel; Cancel or dismissal drops only that editor's
uncommitted draft; previously applied settings survive. No hex pad, no
saved palettes, colour history or extra opacity controls.

The typed colour-field entry is the panel's ONE sanctioned keyboard-focus
exception (2026-09-04 amendment, owner-requested; extended 2026-09-06 to
the custom editor, 2026-09-08 to RGB/HSV fields and to the main OSK).
While a hex/RGB/HSV field is active the settings overlay takes keyboard
focus — a brief Exclusive prime acquiring it, OnDemand holding it,
Omarchy's own KeyboardPanel pattern — and the moment the entry ends
(confirm, Escape, leftover click, or the popover closing) that overlay
returns to `WlrKeyboardFocus.None`. The keyboard panel itself stays
`None` so its exclusive zone and key hits are untouched. No other
control, on any other row, ever takes keyboard focus. Hex accepts the
same grammar Config.js holds every other colour write to; an invalid
entry is refused inline, writes nothing, and stays active for correcting.
Focusing hex selects all. Right-click on hex is the stock text menu
(cut/copy/paste), not a custom menu.

The OSK itself types into the focused hex/RGB/HSV field (2026-09-08
amendment, owner-requested). There is no local hex-entry pad. While no
colour field is focused, OSK keys type into the previously focused
client. While one is focused, the main keyboard types into that field
through the helper, the same path as any other client; the system keymap
and selected group are unchanged. Paste into a focused colour field still
inserts locally from CLIPBOARD.

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
font/spacing/opacity controls, app-specific docked scrolling workarounds,
backward-compatible OSK config migration, and a four-row compact arrangement
(merged digit caps, one-row height cut) are not part of v1.1.
(2026-09-07, ticket 11)
