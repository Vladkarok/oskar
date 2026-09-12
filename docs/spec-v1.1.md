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
- The emoji cap displays `☺` and launches `emote` directly. The existing
  Hyprland `stay_focused` rule remains: selection or Escape closes Emote;
  click-away dismissal is not promised.

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

## 4. Geometry

Docked mode reserves exactly the visible panel height. Non-fullscreen tiled
windows end at or above the panel; fullscreen behaviour remains the v1
exception. Reservation cannot guarantee that another client preserves its
internal bottom scroll position, chat composer or caret after resize.

Preset changes preserve bottom-centre in docked mode. Floating mode preserves
the card centre, clamped only enough to keep the complete card on its output;
saved placement uses that deterministic anchor. The size control opens a
direct M/L/XL chooser. Choosing the active preset closes it without movement.

## 5. Settings and configuration

The gear opens a compact popover anchored at the top-left under the gear. It
does not replace the key grid or resize the panel, and closes on outside click
or Escape. Changes apply immediately; there is no Save or rollback-on-close.
Each override can be reset. Reset-all requires confirmation.

Approved fields are: docked/floating mode, M/L/XL size, sound on/off, follow
Omarchy theme, key radius, panel radius, key background, panel background,
text colour, accent/active colour and border colour. Custom sound files,
volume, fonts, spacing and opacity are out of scope.

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
allowed. Panel geometry, appearance, pointer feel, popovers, Emote behaviour
and shared-Style refresh require VM screenshots or host hand verification as
appropriate. Modifier feel is judged on the host, because VM latency makes
that evidence invalid.

## 9. Deferred

Licence ticket 12, arbitrary Unicode insertion, custom sounds and volume,
font/spacing/opacity controls, app-specific docked scrolling workarounds and
backward-compatible OSK config migration are not part of v1.1.
