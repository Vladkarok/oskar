# On-Screen Keyboard for Omarchy

A mouse-driven on-screen keyboard for Omarchy Quattro. The key caps follow the
active keyboard layout, so what is drawn is what gets typed, and the panel takes
its colours and geometry from the Omarchy theme.

Every line of this tree is our own: `tools/provenance.py` verifies against
the upstream project that once seeded the first panel sketch that zero
substantive lines are shared, and the licence is a sole copyright.

## Status

**Work in progress. Not ready to enable on a machine you rely on.**

The QML panel works and the input helper passes its unit tests, the
nested-session smoke, and first dogfooding in a disposable Omarchy VM:
typing precision (screenshot-verified), layout mirroring in both
directions with zero keymap churn, USB hotplug survival, and cold-boot
self-recovery. The installer already enables and starts the service for
the graphical session (see Install). Still ahead of a first public
release: daily use on a real session, sleep/wake on real hardware, and
the release gates listed in
[docs/release-readiness-plan.md](docs/release-readiness-plan.md).

## Layout

| path | what it is |
|---|---|
| `manifest.json` | plugin manifest (`io.github.vladkarok.osk`) |
| `Panel.qml` | the keyboard window: a docked full-width strip or a floating overlay |
| `Keyboard.qml` | key grid, layout tracking, socket client |
| `KeyboardLayout.js` | key rows, keysym tables, xkb position mapping |
| `EmojiPage.qml`, `EmojiCatalog.js` | the panel's own emoji page over the keys; catalogue generated from vendored Unicode data (`third_party/emoji/`) |
| `ClipboardPaste.js` | the paste chip's target rule (colour field, emoji search, external client) |
| `HoverTooltip.qml` | one shared hover tooltip for ambiguous icon controls |
| `ModifierReducer.js` | the modifier state machine (pure, tested) |
| `Config.js` | maintained defaults plus override/state validation and serialization |
| `Theme.qml` | the panel's one reader of Omarchy's shared style tokens |
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
reserves nothing and is dragged by its bar. Mode is chosen in Settings.

Maintained defaults ship in `Config.js`. Deliberate user choices are sparse in
`$XDG_CONFIG_HOME/omarchy-osk/config.json`; floating geometry is separate in
`$XDG_STATE_HOME/omarchy-osk/state.json`. Both files reload on change without
polling and GUI writes replace them atomically. Invalid external text stays
untouched while the panel keeps the last valid runtime value.

| key | values | default |
|---|---|---|
| `mode` | `docked` \| `floating` | `docked` |
| `size_preset` | preset name | `medium` |
| `sound` | `true` \| `false` | `false` |
| `follow_theme` | `true` \| `false` | `true` |
| `emoji_close_after_pick` | `true` \| `false` | `false` |
| `emoji_page_size` | `medium` \| `large` \| `x-large` | `medium` |
| `super_mark` | `word` \| `omarchy` \| `windows` \| `macos` \| `penguin` | `word` |
| `key_radius` | whole-pixel integer ≥ 0, 0–24 relative to M | `8` |
| `panel_radius` | whole-pixel integer ≥ 0 | `12` |
| `key_background` | hex colour (`#RGB`, `#RGBA`, `#RRGGBB`, `#AARRGGBB`) | `#303030` |
| `panel_background` | hex colour (`#RGB`, `#RGBA`, `#RRGGBB`, `#AARRGGBB`) | `#202020` |
| `text_color` | hex colour (`#RGB`, `#RGBA`, `#RRGGBB`, `#AARRGGBB`) | `#f5f5f5` |
| `accent_color` | hex colour (`#RGB`, `#RGBA`, `#RRGGBB`, `#AARRGGBB`) | `#7aa2f7` |
| `border_color` | hex colour (`#RGB`, `#RGBA`, `#RRGGBB`, `#AARRGGBB`) | `#5a5a5a` |

`state.json` contains the floating placement as `center` — the card centre in
output-local coordinates — or `null`, bounded emoji usage continuity, and the
emoji skin-tone selection (state, not an override).
Restores rederive
the top-left from that centre, clamped only enough to keep the complete card
on its output (the deterministic anchor of spec-v1.1 §4), so a saved
placement cannot jump near an edge when the preset or output changes. An
absent override follows the maintained value, so a later release can change
its default without rewriting the user's sparse file.

`sound: true` plays the freedesktop sound theme's `bell` event on each key
press through QtMultimedia — nothing is spawned per keystroke. It needs
`qt6-multimedia` and `ffmpeg`; the theme's Vorbis file is transcoded to PCM
once at startup (SoundEffect plays uncompressed WAV only), into
`$XDG_RUNTIME_DIR`. Without them the keyboard works and stays silent.
Colours, fonts and corner radius all come from the shared Omarchy style tokens,
so switching the theme redraws the keyboard where it stands — no restart of the
shell or the plugin, and nothing on the typing path is touched. `follow_theme:
false` stops it tracking theme changes: the keyboard keeps the theme that was in
force when it was first opened. Each of the seven appearance fields in the table
above can also be pinned on its own — the settings popover's Appearance section,
or a sparse entry in `config.json`: an explicit override wins over the theme for
that field alone, with precedence override → live (or frozen) token → shipped
default, while every unpinned field keeps following or staying frozen as
`follow_theme` says. Overrides are the whole of the v1.1 appearance surface, not
an independent colour schema — that remains v2.

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

## Compatibility

- **Desktop**: Omarchy (tested against Omarchy 4.0.x with its own
  `omarchy`/`omarchy-dev` packages; the shell's plugin surface is a
  moving target — current as of Quickshell 0.3.1 and Hyprland 0.56.2,
  both pinned by nothing more than Omarchy's own versions). Wayland
  only; there is no Xorg, GNOME or KDE host, and GTK/KDE portability is
  explicitly post-release.
- **Typed-into consumers, verified**: native Wayland clients (foot),
  XWayland windows (wine/Proton get the paced plain Ctrl+V paste), and
  Chromium-family editors (Electron receives supplementary-plane emoji
  byte-exact through the Unicode-entry route). Other toolkits are
  untested.
- **Language coupling**: any number of configured XKB layouts; typing
  and the caps follow the compositor's layout state in both directions.
  The UI and the emoji search are English-only for now.
- **Not tested**: real-hardware sleep/wake (the lab VM cannot suspend).
  The on-screen keyboard is mouse/touchpad-driven; touch gestures
  (long-press, multi-touch) are not implemented.

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

One script keeps the "is anything still derived" question a number instead
of an argument, measured against the upstream snapshot `e3771b6` that the
first panel sketch grew out of (spec-v1 §13 records the history):

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
appear; the suite then bounds the compositor's keymap rebuilds by a ceiling
derived from the seat identities the run installs (a byte-identical
`configure` must short-circuit; the derivation lives in
`tools/nested-session.sh`), checks that the device's group
follows `configure`/`group` commands with an assertion before every tap
(read back from `hyprctl devices`), that a client disconnecting mid-chord
leaves the helper serving, and the multi-client claim rules (foreign
releases refused, a shared press surviving one claim's release, taps
refusing to lift a claim, a re-claim after a keymap swap re-pressing). VM
integration legs also verify byte-exact delivery in native Wayland, XWayland
and Electron consumers; visual feel and real-host application behavior remain
owner-acceptance work.

```sh
cd daemon && cargo test
```

## Install

From an AUR package (`omarchy-osk`): install it, then activate with the
one lifecycle command — it registers the packaged payload under the
stable plugin id, enables the plugin through Omarchy, and enables/starts
the helper service:

```sh
omarchy-osk setup      # idempotent; also: upgrade / status / teardown
```

From a source checkout, the same command manages the checkout (the
installer links it into `~/.local/bin`):

```sh
./install.sh           # helper + unit + the omarchy-osk command
omarchy-osk setup      # registration, plugin enable, service
```

The installer builds the helper, installs it and its user unit, and
enables and starts the service for the graphical session (spec-v1.1 §6:
an installed but disabled unit is indistinguishable from a broken
keyboard). Run `omarchy-osk upgrade` after updating the plugin. Manually,
the same steps are:

```sh
cd daemon && cargo build --release
install -Dm755 target/release/omarchy-osk-daemon ~/.local/libexec/omarchy-osk-daemon
install -Dm644 ../systemd/omarchy-osk.service ~/.config/systemd/user/omarchy-osk.service
systemctl --user daemon-reload
systemctl --user enable omarchy-osk.service
systemctl --user --quiet is-active graphical-session.target \
  && systemctl --user restart omarchy-osk.service
```

The panel alone can be enabled with `omarchy plugin enable io.github.vladkarok.osk`.
