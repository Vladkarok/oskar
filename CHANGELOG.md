# Changelog

User-facing changes. The reasons behind them are in
[docs/decisions.md](docs/decisions.md).

## Unreleased

No numbered version has been published; the early 0.1.x–0.2.1 tags were
withdrawn. The version string in the tree (0.3.0) reserves a number above
them so no old tag name is reused, and the first release will start there.

### Install channels

- `omarchy plugin add https://github.com/Vladkarok/oskar --enable`, then the
  plugin's `install.sh` for the helper. Until the helper is installed the
  panel says `oskar.service is not installed` and its Copy button hands
  over that command.
- A source checkout (`./install.sh`, `oskar setup`).
- The release tarball with its `PKGBUILD` (`makepkg -si`, `oskar setup`).
- Without a Rust toolchain (once a release exists): its prebuilt helper,
  `install.sh --prebuilt oskar-daemon-<version>-x86_64.tar.gz`.

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

### Fixed

- The emoji search's clear button sat under the skin-tone button.
- Settings: the Super mark row's reset button was cut off at the popover's
  edge, the reset icon drew as a stray hook in the theme's font, and the
  language row's labels overran each other on a seat with four layouts.
- `install.sh` reported the helper running before the new helper answered.
- The input profile defaults to Mouse; Auto (switch on the first touch)
  and Touch opt in, because the touch profile has met emulated hardware
  only.
- The Italian interface draft is held back until it has been proofread;
  the interface ships in English, Russian and Ukrainian.
- Summoning the panel on a second monitor no longer flashes it on the
  first one: the window maps only once the pointer's output is known.

