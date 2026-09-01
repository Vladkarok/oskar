# On-Screen Keyboard for Omarchy

A mouse-driven on-screen keyboard for Omarchy Quattro. The key caps follow the
active keyboard layout, so what is drawn is what gets typed, and the panel takes
its colours and geometry from the Omarchy theme.

Derived from [abdxdev/omarchy-onscreen-keyboard](https://github.com/abdxdev/omarchy-onscreen-keyboard)
(MIT). Both copyright lines are kept in `LICENSE`.

## Status

**Work in progress. Not ready to enable on a machine you rely on.**

The QML panel works. The input helper in `daemon/` does not yet meet the bar: it
is disabled by default and should stay that way until the issues below are
closed.

## Layout

| path | what it is |
|---|---|
| `manifest.json` | plugin manifest (`io.github.vladkarok.osk`) |
| `Panel.qml` | the floating keyboard window |
| `Keyboard.qml` | key grid, layout tracking, socket client |
| `KeyboardLayout.js` | key rows, keysym tables, xkb position mapping |
| `BarWidget.qml` | bar icon that toggles the panel |
| `daemon/` | Rust helper holding one virtual keyboard |
| `tools/nested-session.sh` | runs a command against a throwaway nested Hyprland |
| `tools/smoke-daemon.sh` | end-to-end check of the helper |

## Why there is a helper at all

QML cannot drive `zwp_virtual_keyboard`, so typing has to go through a separate
process. The first version spawned `wtype` once per keystroke, which cost 37.8ms
a key (measured) and never reached XWayland clients, because `wtype` uploads a
small synthetic keymap that XWayland ignores — keystrokes vanished into Proton
games and Electron apps. A single long-lived helper with a complete keymap
brought that to 0.4ms average and does reach XWayland.

## Known problems

These are why the helper is off. Details are in the commit messages.

1. **The helper's keymap becomes the seat's.** Hyprland calls `setKeyboard()`
   before forwarding virtual input, which broadcasts that device's keymap to
   every client including XWayland. Typing therefore swaps the seat-advertised
   keymap between the physical keyboard, any other virtual keyboard, and this
   one. On a live session that produced 56 keymap rebuilds a minute and appeared
   to disturb layout switching in other applications. The helper's keymap must
   match the compositor's complete RMLVO configuration before this is safe.
2. **The compiled keymap is incomplete.** `kb_variant`, `kb_options`,
   `kb_model` and `kb_rules` are not all carried through yet.
3. **Device selection is wrong.** The panel picks the keyboard with the highest
   layout index, which is not the same as the one being typed on. Hyprland lists
   every device exposing an HID keyboard interface as a keyboard — including
   gaming mice, lid switches and power buttons — so a switch can land on a mouse
   and the reading follows it.
4. **Held keys are tracked per connection** while the device is shared.

## Testing

Never exercise the helper against the session you are working in. A keymap
feedback loop in an earlier version drove xkbcomp 56,547 times in five minutes
and froze the desktop hard enough to require a TTY switch.

```sh
tools/nested-session.sh ./daemon/target/release/omarchy-osk-daemon
tools/nested-session.sh tools/smoke-daemon.sh
```

The harness starts a disposable nested Hyprland, gives the subject a private
`XDG_RUNTIME_DIR` so its control socket cannot collide with an installed
service, and fails the run if compositor keymap rebuilds exceed a threshold.

```sh
cd daemon && cargo test
```

## Install

```sh
cd daemon && cargo build --release
install -Dm755 target/release/omarchy-osk-daemon ~/.local/libexec/omarchy-osk-daemon
install -Dm644 ../systemd/omarchy-osk.service ~/.config/systemd/user/omarchy-osk.service
systemctl --user daemon-reload
```

Leave the service disabled until the problems above are resolved. The panel
alone can be enabled with `omarchy plugin enable io.github.vladkarok.osk`.
