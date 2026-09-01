# On-Screen Keyboard for Omarchy

A mouse-driven on-screen keyboard for Omarchy Quattro. The key caps follow the
active keyboard layout, so what is drawn is what gets typed, and the panel takes
its colours and geometry from the Omarchy theme.

Derived from [abdxdev/omarchy-onscreen-keyboard](https://github.com/abdxdev/omarchy-onscreen-keyboard)
(MIT). Both copyright lines are kept in `LICENSE`; the input path no longer
shares anything with it.

## Status

**Work in progress. Not ready to enable on a machine you rely on.**

The QML panel works. The input helper in `daemon/` passes its unit tests and
the nested-session smoke, and is disabled by default until it has survived
daily use — next step is dogfooding in a disposable Omarchy VM, then on a real
session.

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

## Why not an existing keyboard

Surveyed August 2026. None does layout mirroring on Hyprland; this is the only
implementation found that follows the system layout at all.

- **wvkbd** types through the same protocol but ships static keycap sets switched
  only by its own key, and its auto-show occupies the single input-method slot.
- **squeekboard** is unmaintained (Phosh replaced it); **maliit** speaks
  input-method-v1, which Hyprland does not implement, and is dormant.
- **IME/text-input routes** (fcitx5, maliit, GNOME apps) never reach XWayland,
  which is a hard requirement here, and would fight Caps-Lock layout toggles
  with a second layout state.
- **GNOME Shell's OSK** is the proof the design is right — a compositor-owned
  virtual device over one system-wide input source — but it is welded to
  mutter/ibus. **Sway** already has the compositor-side fix (same-keymap
  devices share layout state, switches skip virtual keyboards); that is the
  model for the eventual Hyprland upstream work.

## Known problems

1. ~~**The helper's keymap becomes the seat's.**~~ **Closed by design.** Hyprland
   re-points the seat at the typing device before forwarding input, but a client
   is only told about a keymap change when the bytes differ
   (`CWLKeyboardResource::sendKeymap`, `src/protocols/core/Seat.cpp`). The helper
   compiles the identical RMLVO the compositor uses, so switching between the
   physical keyboard and the helper is invisible to clients. The churn storm that
   motivated this (56 rebuilds a minute, 56,547 in five minutes once it fed back)
   only happened because the old keymaps differed. Remaining work is proof, not
   design: the polygon asserts compositor rebuilds stay at the floor, and the
   claim still needs daily-use confirmation.
2. ~~**The compiled keymap is incomplete.**~~ **Closed.** The `configure` command
   carries rules, model, layouts, variants, options and a keymap file, and the
   panel sends it with the full set read from the compositor.
3. **Device selection is imperfect.** The panel reads layouts from the most
   convincing typed keyboard — Hyprland's active-keyboard flag (`main`, the
   seat's current keyboard) if a filtered device holds it, else the device the
   last switch named, else layout progress — but advances only a device
   supported by the first two tiers; with no positive evidence the language
   button does nothing rather than guess. The evidence tiers cannot be closed
   completely: hotplug and mouse media keys can move the flag until the next
   physical keypress, Hyprland emits `activelayout` for hotplug and config
   reloads and not only for deliberate switches, and tied-at-zero devices are
   assumed to share the seat's RMLVO. The root cause is upstream: layout state
   lives per device (including power buttons and gaming mice), and nothing
   announces a change of the seat's current keyboard. An upstream discussion
   with Sway's keyboard-group semantics as prior art is planned.
4. ~~**Held keys are tracked per connection**~~ **Closed.** The device is
   shared, so held keys carry per-connection claims: the press belongs to the
   first claim, the release to the last, a release from a connection that
   never claimed the code is refused, a tap cannot lift another connection's
   hold, and a disconnect releases only that connection's claims (smoke
   covered, including two clients sharing one hold).

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
The smoke checks the readiness gate, that exactly two keymaps get compiled
(default plus configured — a byte-identical `configure` must short-circuit),
that the device's group follows `configure`/`group` commands with an
assertion before every tap (read back from `hyprctl devices`), that a client
disconnecting mid-chord leaves the helper serving, and the multi-client
ownership rules (foreign releases refused, shared holds surviving one
holder's release, taps refusing to lift a hold). What it cannot see is the
character an app receives — that is what the VM dogfooding phase is for.

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

Leave the service disabled until the helper has survived daily use. The panel
alone can be enabled with `omarchy plugin enable io.github.vladkarok.osk`.
