# Changelog

User-facing changes. The reasons behind them are in
[docs/decisions.md](docs/decisions.md).

## 0.1.1

The keyboard behaves as it did in 0.1.0. This release is about reading
and checking it.

- The README opens with the install. The source checkout, the pacman
  package and the prebuilt helper moved to "Other ways to install", and a
  row of links sits under the introduction.
- The test battery passes on GitHub again. It had failed there since the
  install record arrived, because the container ran it as root and one
  helper test expected a user session. Both were faults of the tests.

## 0.1.0 — the first release

The first published version: what the author has daily-driven, packaged
for other desks.

### Install channels

- `omarchy plugin add https://github.com/Vladkarok/oskar --enable`, then the
  plugin's `install.sh` for the helper. Until the helper is installed the
  panel says `oskar.service is not installed` and its Copy button hands
  over that command.
- A source checkout (`./install.sh`, `oskar setup`).
- The release tarball with its `PKGBUILD` (`makepkg -si`, `oskar setup`).
- Without a Rust toolchain: the release's prebuilt helper,
  `install.sh --prebuilt oskar-daemon-0.1.0-x86_64.tar.gz`.

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
- `oskar setup` and `oskar upgrade` take `--prebuilt <tarball>`; without
  cargo they keep the helper already installed instead of refusing, and a
  quick install-setup-upgrade sequence no longer trips the service's
  start-rate limit.
- The caps follow a layout switch made on the keyboard you type on, even
  when the compositor's current-keyboard flag sits on another device.
- The paste chip shows the kind and size of the clipboard and its text only
  while you point at it; content a password manager marks secret is never
  shown. A failed emoji pick puts the previous clipboard text back.
- `install.sh`, `uninstall.sh` and `oskar` replace, remove, move or
  switch on and off only files OSKar recorded when it wrote them and that
  are unchanged since. Anything else is left in place; `install.sh
  --force` moves it aside under a new dated name and deletes nothing. An
  install made before this release has no record and needs
  `./install.sh --force` once. `uninstall.sh` never leaves an enabled
  unit pointing at a removed helper (`uninstall.sh --force` moves what
  does not match aside), and the panel's Retry starts the service only
  when its unit is OSKar's.

