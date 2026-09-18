# OSKar — on-screen keyboard for Omarchy

OSKar (say it "OS-car", Оскар in Cyrillic) is a mouse-driven on-screen
keyboard for Omarchy Quattro. OSKar is not Oscar — no statuettes; it's
the OSK, ar. The key caps follow the active keyboard layout, so what is
drawn is what gets typed, and the panel takes its colours and geometry
from the Omarchy theme.

## Status

**v0.1.1 — released 2026-09-18** (v0.1.0 went public 2026-09-17;
0.1.1 lands the two-lab security audit's hardening — see
SECURITY.md). The audit round and the
polish round behind it are complete: every ticket implemented,
independently reviewed (`ship` verdicts), and proven in the lab VM on
the exact release artifacts — host suites, the packaged-product
lifecycle choreography, the crash-recovery choreography, the nested
integration suite, and a live regression wall that drives the real
panel with real pointer events. The owner daily-drives it on his own
machine (that is how most of it was found). An AUR package (`oskar`)
follows as soon as AUR registration reopens; until then the source
install below is the way.

Known-untested, honestly: real-hardware sleep/wake, and real-finger
touchscreens (the touch profile is emulator- and Qt-synthesis-proven
— see Input profile).

## Layout

| path | what it is |
|---|---|
| `manifest.json` | plugin manifest (`io.github.vladkarok.oskar`) |
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
`$XDG_CONFIG_HOME/oskar/config.json`; floating geometry is separate in
`$XDG_STATE_HOME/oskar/state.json`. Both files reload on change without
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

## Input profile (mouse and touch)

**Touch is beta.** OSKar's design centre is the mouse; the touch
profile is new and usable but not yet polished — expect small targets
in the emoji and settings chrome, and set Input profile to Mouse in
Settings if
a stray touch switches behaviour you did not want. Mouse behaviour is
unchanged in every particular.

One setting, three values (**Auto** by default, or pinned to
Mouse/Touch):

- **Mouse** (the design centre): hover tooltips everywhere,
  dwell-to-type (rest on a cap and it types — the accessibility
  slice), hold-a-key column menus, press-typing with the compositor's
  own key repeat.
- **Touch** re-answers what a finger cannot do: a touch cannot hover,
  so dwell never arms and tooltips show on touch-and-hold
  (gear/close/paste) or stay hidden where a label already states the
  thing; fingers drift, so character caps **type on release** and
  sliding off cancels; long-press opens the same hold-column menus
  (the mobile idiom); chrome hit areas grow toward comfortable size
  where the geometry allows; Space/BackSpace keep press semantics, so
  holding BackSpace repeats exactly as on a hardware keyboard, and
  the close cap answers a release like every character cap.
- **Auto** observes the pointer's source: the first touch-drawn event
  switches to the touch affordances **for that summon** (a hidden
  panel forgets), and the settings row says `Auto (touch)` while it
  stands — the manual Mouse pin is the deliberate escape. One guard
  is absolute: with **dwell enabled, auto never flips** — a chosen
  access method is not disarmed by a stray touch.

Known rough edges, named: the emoji group tabs and settings segments
remain small targets; pen input is untested (a pen receives the touch
affordances); the observation is panel-wide — a touch on one monitor
switches the caps on all of them until the panel hides. Touch is
proven against an emulated multitouch device end to end (evdev →
libinput → the compositor's wl_touch) and Qt's own touch synthesis on
the shipping Qt version; real-finger hardware has not been in our
hands yet.

## Security posture

One sentence: OSKar is a **same-user** tool. Everything it owns lives
under your `/run/user/<uid>/oskar/` and `~/.config/oskar/` with
`0700`/`0600` permissions, the daemon runs as your user without
privileges, and the control socket is connectable only by processes
running as you — other users on the machine cannot inject keystrokes
or read your keymap.

Honest edges: root can do what root always can (no same-user tool
draws that line); the daemon trusts its same-user callers on a line
protocol (hardening candidates live in docs/audit-2026-09-13.md item
7); there is no network listener, no telemetry, no accounts — the
vision document calls the product a system utility and means it.

## Languages

One product, four languages, each with a job:

- **QML** (the Quickshell panel) — what the panel is and where it draws.
- **JavaScript** (sixteen pure modules beside the QML) — every decision
  the panel makes: what each keycap types, which modifiers a
  hold-column pick needs, how the emoji search ranks, whether the panel
  follows a layout-group change. Pure, stateless, and covered by 446
  offscreen test cases — the repo's main regression net.
- **Rust** (the `oskar-daemon` helper) — everything at the seat: it
  compiles and mirrors the XKB keymap, owns the virtual keyboard, and
  speaks the versioned socket protocol. 45 unit tests.
- **Python and one C file** (`tools/integration/`) — not part of the
  product: the lab harness that drives a real panel with real pointer
  events inside a throwaway VM, and a tiny Wayland client that spies on
  keymap deliveries. Development-only.

## Why there is a helper at all

QML cannot drive `zwp_virtual_keyboard`, so typing has to go through a separate
process. The first version spawned `wtype` once per keystroke, which cost 37.8ms
a key (measured) and never reached XWayland clients, because `wtype` uploads a
small synthetic keymap that XWayland ignores — keystrokes vanished into Proton
games and Electron apps. A single long-lived helper with a complete keymap
brought that to 0.4ms average and does reach XWayland.

## How this compares

Surveyed September 2026. No other on-screen keyboard follows the system
layout; most ship their own layout lists that only their own key switches.

| | This keyboard | GNOME OSK | plasma-keyboard (6.6) | squeekboard / Stevia | wvkbd | onboard |
|---|---|---|---|---|---|---|
| Mouse-driven desktop use | yes — the design centre (a touch profile ships; see below) | touch activation only | touch-first (mouse use still a known gap) | touch-first | touch-first | yes (its niche) |
| Caps follow the system layout | both directions — switch with the physical shortcut and the caps follow; switch from the panel and the physical keyboard follows | partial, one-way, ibus-coupled | Qt Virtual Keyboard's own layout lists | its own layout files | static keycap sets | own definitions |
| What is drawn is what is typed | yes, including non-Latin and per-group variants, proven byte-exact | within GNOME's input stack | within Qt's stack | within Phosh | — | X11 only |
| XWayland / wine-Proton | proven (paced paste chord) | — | — | — | types, no layout coupling | X11 only |
| Chromium/Electron emoji | proven (Unicode-entry route; clipboard mode for the rest) | — | — | — | — | — |
| Host | Omarchy (Hyprland + Quickshell), Wayland | GNOME (mutter/ibus) | Plasma 6.6+, input-method-v1 | Phosh | wlroots mobile shells | X11 |
| State (2026) | active | active | new (Feb 2026) | squeekboard replaced by Stevia in postmarketOS | active | abandoned |

Notes from the survey:

- **wvkbd** types through the same virtual-keyboard protocol but ships
  static keycap sets switched only by its own key, and its auto-show
  occupies the single input-method slot.
- **plasma-keyboard** wraps Qt Virtual Keyboard and rides
  input-method-v1 — a protocol Hyprland does not implement — and
  **maliit**, the previous Plasma option, spoke the same one.
- **IME/text-input routes** (fcitx5, maliit, GNOME apps) never reach
  XWayland, which is a hard requirement here, and would fight Caps-Lock
  layout toggles with a second layout state.
- **GNOME Shell's OSK** is the proof the design is right — a
  compositor-owned virtual device over one system-wide input source —
  but it is welded to mutter/ibus. **Sway** already has the
  compositor-side fix (same-keymap devices share layout state, switches
  skip virtual keyboards); that is the model for the eventual Hyprland
  upstream work.

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
  The UI ships in English, Russian and Ukrainian, following the active
  layout (a settings override pins one); the emoji search understands
  English, Russian and Ukrainian keywords.
- **Not tested**: real-hardware sleep/wake (the lab VM cannot suspend);
  real touchscreen hardware (the touch profile is emulator- and
  Qt-synthesis-proven; see Input profile below).

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

## Troubleshooting

Run `oskar doctor` — it checks the service, socket and protocol,
registration, the keymap share, keycap-fallback journal lines, layouts
and theme dependencies, and names the one fix to try for each failure
(exit 0 is healthy).

## Testing

Never exercise the helper against the session you are working in. A keymap
feedback loop in an earlier version drove xkbcomp 56,547 times in five minutes
and froze the desktop hard enough to require a TTY switch.

```sh
tools/nested-session.sh ./daemon/target/release/oskar-daemon
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

From a source checkout — the primary path today. Get the repository
and run one flow of three steps:

```sh
git clone <REPOSITORY-URL> oskar && cd oskar
./install.sh           # builds the helper, installs it + its unit + the
                       # oskar command, enables and starts the service
oskar setup            # registers the checkout under the stable plugin id,
                       # enables the plugin in Omarchy, re-checks the service
omarchy restart shell  # the running shell only picks up a newly registered
                       # plugin at restart (or log out and back in)
```

`install.sh` needs `cargo` to build the helper — on Omarchy,
`omarchy pkg add rust` provides it (the script says so and stops if it is
missing). After updating the checkout, rerun both commands: the QML side
and the helper share a protocol version, and a plugin updated without its
helper reports that it needs reinstalling rather than typing nothing
(`oskar upgrade` is the same rerun under one name). The keyboard's
icon appears in the bar; clicking it (or the toggle below) shows the
panel:

```sh
omarchy-shell shell toggle io.github.vladkarok.oskar
```

An AUR package (`oskar`) will become the primary path on publish —
it does not exist yet. Until then there is no packaged channel: the
source checkout above is the only install, and it has to come from the
project's repository directly.

`oskar setup` is idempotent and also owns `status` and `teardown`
(full removal: registration, plugin enable, unit, state). For reference,
the manual equivalent of `install.sh`:

```sh
cd daemon && cargo build --release
install -Dm755 target/release/oskar-daemon ~/.local/libexec/oskar-daemon
install -Dm644 ../systemd/oskar.service ~/.config/systemd/user/oskar.service
systemctl --user daemon-reload
systemctl --user enable oskar.service
systemctl --user --quiet is-active graphical-session.target \
  && systemctl --user restart oskar.service
```

The panel alone can be enabled with `omarchy plugin enable io.github.vladkarok.oskar`.
