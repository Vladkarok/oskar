# Changelog

User-facing changes. The reasons behind them are in
[docs/decisions.md](docs/decisions.md).

## Unreleased

No numbered release yet; install from source (see the README).

### What works today

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
- Settings: mode, size preset, interface language, input profile (mouse,
  touch in beta, or auto; the mouse profile offers dwell-to-type), key-click
  sound, and appearance (corner radius and colours, applied live).
- Colours and geometry follow the Omarchy theme.
- `oskar setup | upgrade | status | teardown` manage the helper service and
  plugin registration.
