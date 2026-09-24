# Changelog

User-facing changes. The reasons behind them are in
[docs/decisions.md](docs/decisions.md).

## 0.3.0 — the first release

The first published release. The early 0.1.x–0.2.1 tags were withdrawn
before it; this version starts above them so no old tag name is reused.

### Install channels

- `omarchy plugin add https://github.com/Vladkarok/oskar --enable`, then the
  plugin's `install.sh` for the helper. Until the helper is installed the
  panel says `oskar.service is not installed` and its Copy button hands
  over that command.
- A source checkout (`./install.sh`, `oskar setup`).
- The release tarball with its `PKGBUILD` (`makepkg -si`, `oskar setup`).

### What works

- Caps follow the active keyboard layout, including non-Latin layouts:
  what is drawn is what gets typed, in native Wayland, XWayland, Wine/Proton
  and Electron windows.
- Switching languages from the panel moves the physical keyboard too, and
  the other way round. A two-layout seat toggles directly, and three or
  more layouts open a chooser. Each language is named in its own language.
- Docked mode, flush along the bottom edge and reserving that space, or
  floating mode, dragged by its bar.
- Holding a key opens its extra keymap levels as a column.
- A `?123` symbols page, with currency and punctuation on every layout.
- An emoji page with categories, recents, skin tones and search in
  English, Russian and Ukrainian. Every pick is delivered through the
  clipboard and a paste chord. The emoji page can optionally be dragged.
- Settings: mode, size preset, interface language, input profile (mouse by default,
  touch in beta, or auto; the mouse profile offers dwell-to-type), key-click
  sound, and appearance (corner radius and colours, applied live).
- Colours and geometry follow the Omarchy theme.
- `oskar setup | upgrade | status | teardown` manage the helper service and
  plugin registration.

### Fixed before release

- The emoji search's clear button sat under the skin-tone button.
- Settings: the Super mark row's reset button was cut off at the popover's
  edge, the reset icon drew as a stray hook in the theme's font, and the
  language row's labels overran each other on a seat with four layouts.
- `install.sh` reported the helper running before the new helper answered.

