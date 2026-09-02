# On-Screen Keyboard for Omarchy

A mouse-driven on-screen keyboard for Omarchy Quattro. The key caps follow the
active keyboard layout, so what is drawn is what gets typed, and the panel takes
its colours and geometry from the Omarchy theme.

Derived from [abdxdev/omarchy-onscreen-keyboard](https://github.com/abdxdev/omarchy-onscreen-keyboard)
(MIT). Both copyright lines are kept in `LICENSE`; the input path no longer
shares anything with it.

## Status

**Work in progress. Not ready to enable on a machine you rely on.**

The QML panel works and the input helper passes its unit tests, the
nested-session smoke, and first dogfooding in a disposable Omarchy VM:
typing precision (screenshot-verified), layout mirroring in both
directions with zero keymap churn, USB hotplug survival, and cold-boot
self-recovery. Still ahead: daily use in the VM, sleep/wake on real
hardware, and a longer stretch on a real session before the service
earns a place in autostart.

## Layout

| path | what it is |
|---|---|
| `manifest.json` | plugin manifest (`io.github.vladkarok.osk`) |
| `Panel.qml` | the keyboard window: a docked full-width strip or a floating overlay |
| `Keyboard.qml` | key grid, layout tracking, socket client |
| `KeyboardLayout.js` | key rows, keysym tables, xkb position mapping |
| `ModifierReducer.js` | the modifier state machine (pure, tested) |
| `Config.js` | parse/serialize for the one config file |
| `BarWidget.qml` | bar icon that toggles the panel |
| `daemon/` | Rust helper holding one virtual keyboard |
| `tools/nested-session.sh` | runs a command against a throwaway nested Hyprland |
| `tools/smoke-daemon.sh` | end-to-end check of the helper |
| `tools/integration/` | the assertions that check runs, and their plumbing |
| `tools/provenance.py` | measures what the shell layer still shares with upstream |
| `docs/orientation.md` | what this is, current state, how the work runs |
| `docs/decisions.md` | why the design looks like this, and the dead ends |
| `docs/vm-handoff.md` | the dogfooding VM: operating manual and queue |

## Modes and configuration

The panel has two geometries. **Docked** (the default on first run) sits
flush along the bottom edge at full width and reserves that space through
the layer-shell exclusive zone, so windows move up while it is open and
return when it closes — the way the Windows touch keyboard behaves. A
fullscreen window ignores exclusive zones and is overlaid instead. **Floating**
reserves nothing and is dragged by its bar. The mode button on the panel
switches between them.

Everything persists in one file, `$XDG_CONFIG_HOME/omarchy-osk/config.json`,
which is both the documented config and the saved state — there is no second
state file. A missing file or a missing or malformed key falls back to the
defaults rather than failing to start.

| key | values | default |
|---|---|---|
| `mode` | `docked` \| `floating` | `docked` |
| `position` | `{x, y}`, floating mode only | unset |
| `size_preset` | preset name | `medium` |
| `sound` | `true` \| `false` | `false` |
| `follow_theme` | `true` \| `false` | `true` |

`sound: true` plays the freedesktop sound theme's `bell` event on each key
press through QtMultimedia — nothing is spawned per keystroke. It needs
`qt6-multimedia` and `ffmpeg`; the theme's Vorbis file is transcoded to PCM
once at startup (SoundEffect plays uncompressed WAV only), into
`$XDG_RUNTIME_DIR`. Without them the keyboard works and stays silent.
`follow_theme` follows the Omarchy theme today and does nothing else in v1;
the independent colour schema is v2.

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
   design: the nested-session harness bounds compositor rebuilds by threshold,
   and the claim still needs daily-use confirmation.
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

## Provenance

The shell layer is derived from abdxdev's panel and is being reimplemented
against [spec-v1](docs/spec-v1.md) until no substantive logic is shared with
upstream — measured against `e3771b6`, the last commit there before our own
PR merged into it. One script keeps the answer a number instead of an
argument:

```sh
tools/provenance.py
```

It prints shared substantive lines per file and a total. Substantive
excludes blank lines, lone braces, comments, and lines of twelve characters
or fewer — the boilerplate independently written QML still coincides on,
which should not be counted. The upstream checkout is verified against the
exact commit and the measurement is refused against anything else; pass
`--upstream DIR` to use an existing checkout, `--verbose` to list the shared
lines. The script exits `1` while the total is above zero, so the licence
change to a sole copyright can gate on it reading zero.

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

`tools/smoke-daemon.sh` owns the helper process; the assertions live in
`tools/integration/suite.py` and everything that talks to the socket, the
log or `hyprctl` lives in `tools/integration/harness.py`, so a new check is
a new `@test` and nothing else. The script waits for the control socket to
appear; the suite then checks that exactly three keymaps get compiled
(default, configured, and the model swap in the drain regression — a
byte-identical `configure` must short-circuit), that the device's group
follows `configure`/`group` commands with an assertion before every tap
(read back from `hyprctl devices`), that a client disconnecting mid-chord
leaves the helper serving, and the multi-client claim rules (foreign
releases refused, a shared press surviving one claim's release, taps
refusing to lift a claim, a re-claim after a keymap swap re-pressing). What it cannot
see is the character an app receives — that is what the VM dogfooding phase
is for.

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
