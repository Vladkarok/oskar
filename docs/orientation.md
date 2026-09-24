# Orientation — read this first

What OSKar is and how its pieces fit. Why it looks this way is
[decisions.md](decisions.md); the current product delta is
[spec-v1.1.md](spec-v1.1.md); the test lab is [vm-handoff.md](vm-handoff.md).

## The idea

A mouse-driven on-screen keyboard for Omarchy (Arch + Hyprland +
Quickshell), modelled on the Windows touch keyboard: open it, click keys,
and **what is drawn on the caps is what gets typed** — including non-Latin
layouts, including XWayland, Proton and Electron windows.

The part nobody on Linux does today is the layout coupling. The system
layout is the single source of truth in both directions: switch with the
physical shortcut and the caps follow; switch from the panel and the
physical keyboard follows. Any number of layouts works; a two-layout seat
toggles, three or more open a chooser, and each language is named in its
own language.

Machine name `oskar`, wordmark **OSKar**. The project was born
`omarchy-osk`; older documents quote that name as history.

`grp:caps_toggle` must not be recommended: it silently breaks layout
switching for every client behind fcitx5 (decisions.md has the detail).

## The pieces

| piece | what it does |
|---|---|
| `Panel.qml`, `BarWidget.qml` | the floating or docked window and the bar toggle; saves in `PrivateSaves.qml`, the emoji transaction in `EmojiDelivery.qml`, settings in `SettingsLayer.qml` |
| `Keyboard.qml` | key grid, layout tracking, keycap pipeline; the reply dispatch in `HelperReplies.js` (pure), the socket client in `HelperLink.qml`, paste chords in `PasteChords.qml`, the hold menu in `HoldMenu.qml` |
| `*.js` (twenty pure modules) | every decision the panel makes — rows and keysyms, modifiers, emoji search, config validation, device choice, settle windows; each has an offscreen suite under `tests/` |
| `daemon/src/` | the Rust helper owning one `zwp_virtual_keyboard_v1`: `protocol.rs` (wire format), `server.rs` (socket, handshake), `events.rs` (the shared writer, pushed events), `apply.rs` (commands), `keymap.rs`, `seat.rs` (the `SeatBackend` trait), `hyprland.rs` (its Hyprland IPC implementation), `json.rs`, `state.rs`, `main.rs` |
| `systemd/oskar.service` | user unit, tied to `graphical-session.target` |
| `bin/oskar` | the lifecycle command: setup / upgrade / status / doctor / teardown |
| `tools/` | the nested-session harness, the daemon smoke suite, the package and recovery choreographies, the release checks |

## The protocol

The panel talks to the helper over `$XDG_RUNTIME_DIR/oskar/control.sock`,
one line per command, one reply line per command, version 7 (a connection
may still negotiate 6 and gets exactly the v6 verbs, so a new helper can
run under an older panel):

```
hello 6 | hello 7                         -> hello <n> | err not ready | err protocol …
keyboards                                 -> keyboards\t<safe physical name>…
configure\t<rules>\t<model>\t<layouts>\t<variants>\t<options>\t<kb_file>\t<group>
caps <group> [positions…]                 -> caps\t<generation>\t<group>\t<records>
group <n> | tap <AD01|code> | down … | up … | mods <mask> | ping
# protocol 7 only; a v6 connection answers these `err unknown command`
seat                                      -> seat\t<json> | err no seat backend | err seat …
switch\t<device>\t<group>                  -> ok | err …
share\t</absolute/kb_file> | share\t-      -> ok | err share path must be absolute | err share timed out | err …
events on | events off                    -> ok
```

Replies are `ok`, `configured\t<generation>`, `caps …`, `seat …`, `pong`,
or `err …`. `seat`'s JSON carries `keyboards` (each with the compositor's
own `name`, `main`, `active_layout_index`, `layout`, `variant`, `rules`,
`model`, `options`), `safe` (the `keyboards` verb's list), `kb_file` and
`titles` (layout code to human name). `share` clears and then sets the
compositor's `input:kb_file` and verifies it by reading it back, all inside
one 6 s deadline (below the 15 s hold cap). The helper never checks the file
itself — its `/tmp` is private — so the read-back is the verification.

A v7 connection that sent `events on` also receives unsolicited lines:
`event\tlayout\t<device>\t<group>` when a keyboard's group moves (whoever
moved it) and `event\tdevices` on hotplug or a config reload (re-ask
`seat`). An event line is written whole between replies, never inside
one, and takes no reply slot: a client correlating replies by order sets
lines beginning `event\t` aside. Without a compositor seat backend
(`$HYPRLAND_INSTANCE_SIGNATURE` unset, or its sockets gone) the seat verbs
answer `err no seat backend`, no events flow, and typing is unaffected. The generation is what the panel correlates keycap facts
against: a same-keymap reconfigure keeps it, a changed keymap bumps it.
Every emoji pick rides the clipboard transaction (publish, verify, paste
chord); there are no typed-text verbs. The parser is `parse()` in
`daemon/src/protocol.rs`; the semantics are `apply_locked()` in
`daemon/src/apply.rs`.

The helper compiles the identical RMLVO the compositor uses, so switching
between the physical keyboard and the helper sends clients no keymap
change. That is the load-bearing trick; decisions.md §1 and §23 explain it.

## Build, test, install

```sh
tools/run-tests.sh            # offscreen JS suites, qml gates, cargo test
tools/nested-session.sh tools/smoke-daemon.sh   # the helper under a throwaway Hyprland
./install.sh && oskar setup   # from a checkout; README has the plugin-manager path
oskar doctor                  # names the one fix to try for each failure
```

**Never run the helper against the session you are working in.** A keymap
feedback loop once drove xkbcomp 56,547 times in five minutes. Host suites
are offscreen; anything that needs a compositor runs under the nested
session or in the lab VM.

## Where the thinking lives

- [decisions.md](decisions.md): numbered decisions with the dead ends;
  the only place a WHY is recorded.
- [spec-v1.1.md](spec-v1.1.md) over [spec-v1.md](spec-v1.md): the product
  as specified.
- [vision.md](vision.md): the owner's goal and the strategy verdict.
- [../CONTEXT.md](../CONTEXT.md): the vocabulary — two things that sound
  alike and cost a bug when confused.
- [ime-coexistence.md](ime-coexistence.md),
  [research-input-upstream.md](research-input-upstream.md),
  [plugin-lifecycle-analysis.md](plugin-lifecycle-analysis.md),
  [package-notes.md](package-notes.md): the research behind specific
  decisions.
- [../SECURITY.md](../SECURITY.md): the same-user trust boundary and the
  audit record.

The first panel sketch grew out of abdxdev/omarchy-onscreen-keyboard;
every substantive line has since been replaced, measured to zero shared
lines, and the licence is a sole copyright (spec-v1.md §13).
