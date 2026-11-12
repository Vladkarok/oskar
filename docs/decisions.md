# Why the design looks like this

One line per decision: the rule, then the reason. Section numbers stay
fixed because code, tests and docs cite them as `decisions §N`. The long
form, with the measurements and every rejected variant, is in git:
`git show abc1357:docs/decisions.md` (v0.2.5). §13 is in spec-v1. §61–§90,
§92–§102 and §104 were review journals, kept in the private repo; their
lasting rules are §107.

## Open: needs the owner

- **§120 sunset.** Hand the colour fields back to Qt once Omarchy's Qt has
  the QTBUG-149610 fix: qt6-declarative 6.12.1 or later, or Arch's 6.12
  package with bcbfae6761 cherry-picked. On 2026-11-12 the host had
  6.12.0-4. Whether -4 carries the fix was not checked. Before reverting,
  run the 200 MB clipboard measurement against a writable `TextInput`.
- **§20 patch.** `patches/omarchy-shell-style-live-rounding.patch` looks
  obsolete: the stock `Commons/Style.qml` in omarchy-dev 4.0.0.r7822 now
  refreshes on `configreloaded` by itself (checked 2026-11-12, file
  unmodified). Delete the patch and its README entry, or keep it?
- **§118 upstream.** The lock-state bug belongs to Hyprland's seat-keyboard
  handling. Whether and how to report it is open.
- **§28 four rows.** A four-row compact letters page was deferred as
  future work. Still wanted, or drop it?

## Decisions

- **§1 Separate helper.** QML cannot drive `zwp_virtual_keyboard_v1`. A
  `wtype` per key cost 37.8 ms and never reached XWayland; one long-lived
  helper with a full keymap types in 0.4 ms.
- **§2 Positions, not characters.** The panel sends `AD01` and the
  compositor's layout decides the character, so the drawn cap and the typed
  one cannot disagree. Shift is a real Shift press.
- **§3 Own keymap, never the seat's.** The helper compiles from the RMLVO the
  panel sends and never subscribes to `wl_keyboard.keymap`. Mirroring the
  seat once caused 56,547 keymap rebuilds in five minutes and froze the
  desktop. All layouts are groups of one keymap, a switch is `group n`, and
  an identical `configure` must not recompile (the smoke test counts
  compiles). The most important rule in the project.
- **§4 The compositor owns the layout.** The panel follows `activelayout` and
  `configreloaded`; its button only asks Hyprland to switch.
- **§5 Device tiers.** Hyprland keeps a layout per device, including power
  buttons, mice and IME keyboards. Read from filtered `main`, then the last
  named device, then progress; switch only positively identified keyboards;
  with no evidence the button greys out.
- **§6 One language everywhere.** The owner's reason for the project: switch
  the identified set, then mirror the group to the helper's device, which
  starts at group 0.
- **§7 Held keys are per-connection claims.** First claim presses, last
  releases; a foreign `up` or a `tap` on a held code is refused; a
  disconnect releases only its own claims. This is what prevents a stuck
  Ctrl after a shell restart.
- **§8 Readiness handshake.** `hello <version>` answers only once the device
  has a keymap, so a keyboard that would drop every key never looks ready,
  and a panel/helper version mismatch shows up.
- **§9 systemd user unit.** `PartOf=graphical-session.target`, exit on
  Wayland failure instead of reconnecting, socket under
  `RuntimeDirectory=`, caps `CPUQuota=10%`, `MemoryMax=64M`, `TasksMax=20`.
  A second instance is refused by connecting to the socket, not by a lock
  file.
- **§10 Rebuild the socket, never toggle it.** Quickshell's `connected`
  cannot recover a failed connect and stays true on a dead peer. The
  `Socket` lives in a Loader and is rebuilt when a hello goes unanswered for
  5 s; the rebuild also clears what the disconnect path would
  (`SocketWatch.rebuildResets`).
- **§11 Superseded by §23.** Caps once came from `xkbcli` + awk; a missing
  parenthesis left them on the US table for days. The lesson stays: a
  correct layout label is no evidence that the caps are correct.
- **§12 Testing ladder.** cargo tests; a nested Hyprland that fails on too
  many keymap rebuilds but cannot see what an app receives; the VM lab with
  a real Omarchy and a mixed set of input devices; real hardware for
  sleep/wake (QEMU will not do S3).
- **§14 Licence by reimplementation.** The shell layer was rewritten from
  spec-v1, not renamed, until no line was shared with upstream `e3771b6`;
  only then did the copyright become sole. The provenance gate was retired
  on 2026-09-20 once it started flagging coincidental boilerplate.
- **§15 Startup evidence from udev.** A keyboard counts only with a physical
  bus and path, `ID_INPUT_KEYBOARD=1`, typing positions, and a libinput
  group shared with no pointer device (this rejects gaming mice). Missing
  metadata rejects; it never guesses.
- **§16 Only Shift locks.** A locked Super turns letters into shortcuts.
  Ctrl, Alt and Super are one-shot latches, Caps is a letters-only toggle
  that sends no Caps key, and Fn is a display toggle.
- **§17 The symbols page widens no input path.** It shows only what the
  installed keymap can type: no clipboard, IME, Unicode chord or keymap swap
  to type a symbol. Emoji are §91's separate route.
- **§18 Defaults, overrides and state are separate.** Writes are atomic, and
  a malformed external edit is kept, not overwritten. Config.js owns the key
  space: a camelCase alias gets the same validation, unknown keys ride
  verbatim, and keys like `__proto__` are dropped.
- **§19 Supervised helper, visible state.** systemd restarts the helper; the
  panel shows socket and handshake state and disables only input caps. Retry
  may start the unit; a version mismatch shows the update command. No
  status poll beyond the repair timer.
- **§20 Theme tokens come from Omarchy's Style.** OSKar adds no second
  reader of Hyprland rounding (see Open).
- **§21 Docking reserves space only.** The exclusive zone is guaranteed; how
  a client scrolls inside the smaller window is the client's business. No
  per-app hacks; floating mode is the escape hatch.
- **§22 One grid.** Every row is 15.5 units on a shared pitch, a half-unit
  lattice with the Windows touch keyboard's stagger; 12.5 units sit left of
  both ↑ and ↓. A build guard reports any row that misses 15.5. The page key
  sits bottom right and Del ends row two (owner-vetoable).
- **§23 Caps come from the helper's keymap.** The `caps` reply carries the
  install generation, and the panel accepts facts only for the generation it
  acknowledged. Typing stays off while facts are missing; it never falls
  back to a built-in table.
- **§24 Superseded.** External picker coordination (Emote, the shell
  overlay) is gone; emoji are an in-panel page (§37, §91, §103).
- **§25 Cursor hiding has one owner.** `CursorPolicy.js` serializes probe,
  override and restore of `cursor:hide_on_key_press`, tags each answer with
  its generation, restores only what it applied (after a verify read), and
  keeps the restore obligation when a write's outcome is unknown.
- **§26 The paste chip pastes what the user copied.** It never writes or
  previews the clipboard. Terminals get Ctrl+Shift+V, others Shift+Insert,
  and an unknown class gets the CLIPBOARD chord, never PRIMARY.
- **§27 Omarchy mark mechanism (choice moved to §38).** U+E900 from the
  omarchy font, drawn only if `/usr/share/fonts/omarchy/omarchy.ttf` exists;
  Qt's family checks miss this font, so the file is the gate.
- **§28 Five rows.** The owner chose a dedicated digit row over a shorter
  keyboard (2026-09-07). The pair-cap plan was replaced by §30; four-row
  compact is deferred (see Open).
- **§29 Settings on a second overlay.** A full-screen overlay with the
  keyboard band cut out of its input region, so keys still type and other
  clicks dismiss; placed in the centre of the leftover space. Colour fields
  take a brief Exclusive focus, then OnDemand, on that overlay, never on the
  keyboard surface.
- **§30 `&123` is one Windows-style page.** Shift shows its second half.
  Every character comes from the helper's reserved block (§33), so the page
  never borrows a `us` group. The terminal paste chord uses V (AB04); AB06
  is N, a new window in kitty and ghostty.
- **§31 Caps facts belong to the install, not to a group.** All groups are
  fetched once per generation, so a language switch picks from memory
  without dimming the board. Typing waits only for a configure that drains
  keys. The "starting service" notice waits 400 ms before it shows.
- **§32 The helper's keymap may add symbols.** Allowed as long as no
  existing definition changes (where they go: §33; how the seat stays on
  one map: §35).
- **§33 The reserved block lives on levels 5–8 of ordinary positions.**
  Chromium drops unknown keycodes (only AB11 and AE13 of the free ones
  survive) and Wine substitutes them. Levels 1–4 stay identical, checked per
  keycode, group and modifier. Positions that answer to Lock, Ctrl, Alt or
  Super are not used. Probe the modifier, never a key (`grp:caps_toggle`
  moved the group). The built map must prove LevelFive reaches the block.
  Cost: hosted positions consume LevelThree and LevelFive; some layouts host
  fewer slots (`de(neo)` two).
- **§34 What the panel reads is what the button moves.** One filter picks
  both. A split seat converges to the keyboard that typed, by majority, not
  by the highest index. The logic is in `LayoutDevices.js` with tests, not
  in a jq string.
- **§35 One keymap on the seat, the extended one.** The helper publishes
  `$XDG_RUNTIME_DIR/oskar/keymap.xkb` and points `input:kb_file` at it, at
  runtime only. Two keymaps swapped on every focus change and reset clients'
  group: Telegram typed the old layout until a modifier was pressed. The
  panel still sends the configured RMLVO. Check: over six focus changes a
  traced client sees one distinct keymap.
- **§36 Static QML check.** No test loads Keyboard.qml or Panel.qml, so
  `tools/qml-check.sh` fails on chosen qmllint messages, one at a time, each
  added once the tree has none; whole categories are too noisy to gate on.
- **§37 Vendored emoji data.** The catalogue is generated offline from
  emoji-test 16.0 and CLDR 46 in `third_party/emoji/` (Unicode License V3),
  not read from the system. Search lowercases both sides. Upgrading is a
  deliberate step.
- **§38 Super says "Super" by default.** `super_mark`: word, omarchy,
  windows, macos, penguin. The other marks are drawn vectors, no vendored
  art; Tux keeps the supplied SVG's geometry in fixed black and white. An
  unknown value or a missing font falls back to the word.
- **§39 Superseded by §91.** Typed emoji through a transient keymap. Lesson:
  XWayland translates queued keys against the live keymap, so the restore
  must not share a flush with the taps.
- **§40 Superseded by §91.** Chromium cuts an astral key character to 16
  bits, which is why a Ctrl+Shift+U route existed.
- **§41 The paste chip always sends the chord.** No liveness probe (owner,
  2026-09-11).
- **§42 Superseded by §91.** The clipboard was an opt-in mode. What carried
  over: verify the publication before the chord, and on success replace the
  clipboard rather than restore it.
- **§43 Sole copyright.** Since 2026-09-12; the README no longer tells the
  history (§14).
- **§44 One pick owns clipboard and chord.** Later picks queue in order;
  usage and close-after-pick fire only on real completion; an aborted chord
  releases what it pressed; a pick carries the client class it was clicked
  for.
- **§45 One command owns activation.** The package only installs files (root
  hooks cannot reach the user's session); `oskar setup` / `teardown`
  activate and deactivate. A registration that is a real directory (a git
  clone) is never touched; config and state survive teardown.
- **§46 The helper remembers the user's `kb_file`.** It writes
  `user-keymap-source` in its runtime directory, so a crashed shell cannot
  lose it; the published path is compared by exact identity. The record
  lives as long as the session. §114 replaces its missing-file rule.
- **§47 A remembered group must fit the current map.** Otherwise the
  consensus answers. The helper refuses an out-of-range group (`err bad
  group`).
- **§48 The usage view is a snapshot.** Taken on entry, so tiles do not move
  while clicking; the store updates per delivery.
- **§49 Language control shapes.** One layout: no chip. Two: a toggle. Three
  or more: a chooser inside the card, because the input mask is the card.
  Hidden means nothing to switch; grey means no safe device.
- **§50 No prediction or autocorrect.** They fight drawn-is-typed and add
  moving targets. Revisit only if a heavy mouse typist asks for fewer
  clicks.
- **§51 Hold for levels 3–4.** Holding a character cap ~320 ms offers its
  keymap levels 3–4. Such caps type on release, so a hold types nothing;
  levels 5–8 stay on `&123`.
- **§52 The emoji search borrows the keyboard.** The settings overlay takes
  focus with a 75 ms Exclusive prime, then OnDemand, so a click on any app
  takes the keys back. Every disarm drops one flag, and a pick disarms
  before it delivers.
- **§53 Settle guard.** For 10 s after a new helper connection, an
  uncommanded group flip is held until it stays for 1 s; the user's click is
  never held (`SettleGuard.js`; amended by §115).
- **§54 Dwell.** Off by default, 400–2000 ms, default 800. It types through
  the cap's own click path, once per rest, and cancels on leave. Command
  caps and chrome never dwell; hold-menu entries do.
- **§55 UI words live in `UiStrings.js`.** en/ru/uk. The language follows the
  active layout (ua → uk, ru → ru, anything else → en) unless `ui_language`
  pins it. An unknown id throws, and the suite checks every call site.
  Keymap text and diagnostics are data, not translated.
- **§56 The mode chip is in the header.** Owner, 2026-09-15: he switches
  docked/floating more than expected.
- **§57 Input profile.** auto/mouse/touch in `InputProfile.js`; the default
  is mouse since 2026-09-24, because touch is proven only in emulation. Auto
  turns to touch on the first touch-synthesized press and stays for the
  panel's life. Touch types on release, cancels on slide-off, never dwells,
  and gets larger invisible hit areas.
- **§58 Name.** `oskar` for everything machine-facing, OSKar for people.
  `OSK_*` test variables stay; `OMARCHY_OSK_*` became `OSKAR_*`. The
  old-name migration was later deleted (§112).
- **§59 The mover breaks a split.** When the keyboard that moved is the
  anchor, its group answers; keyboards that never type get no vote against
  it.
- **§60 Layouts are named in their own language.** Endonyms in
  `LanguageControl.js` (~45 codes), falling back to the base.lst title, then
  the code.
- **§91 Every emoji pick goes through the clipboard.** Publish, verify, paste
  chord. Typed delivery and client detection were deleted (−3032 lines, the
  owner's call): no list can enumerate every client. Cost: each pick
  replaces the clipboard.
- **§103 Draggable emoji page.** Behind `emoji_drag` (default off: the old
  centring, unchanged). One `DragLine` component for both bars; the centre
  is saved as `emoji_center`.
- **§105–§106 Split by moves.** Keyboard.qml and Panel.qml lost HelperLink,
  PasteChords, PrivateSaves, EmojiDelivery, SettingsLayer and HoldMenu, each
  a checked pure move. Split further only when a feature asks for it.
  HoldMenu deliberately ignores the pointer source.
- **§107 Rules the review rounds left behind.**
  - Helper input: an interior NUL or a keycode above 4096 is refused before
    xkbcommon; a custom `kb_file` is opened non-blocking, checked as a
    regular file of ≤ 2 MiB, and read once.
  - The group ceiling comes from the compiled map, not the declared list.
  - Nothing but a matching `hello` runs before negotiation; handshake
    window, hold cap and frame cap hold on every iteration; every reply
    write is bounded.
  - One reply line per command line, in order, empty lines included.
  - Commands run under the shared lock, held only for bounded work.
  - Liveness is traffic: the panel pings every 15 s, and the helper drops a
    connection silent for 60 s.
  - The protocol version moves whenever the command set does.
  - Panel: every command takes one `ChordAcks` slot and every reply pops the
    oldest; a chord fails only on an `err` for one of its own key lines.
  - A handoff completes when the counterpart answers, not when the write
    returns; a verdict carries the sequence it was armed for.
  - A killed process is never re-armed inline; a row rebuild releases any
    held key.
  - Every refusal is visible (`flashRefused`); silence is the worst defect
    class here.
  - Saves are private (umask 077, temp + rename), queued per target, and
    failures are reported per path.
  - Tests: pin overlaps on the live socket; derive expected values
    independently; a gate that enumerates nothing fails; every runtime
    module must be in `PLUGIN_RUNTIME`.
- **§108 Helper modules; comments state invariants.** `daemon/src/` is split
  by responsibility. Comments carry the current invariant and its evidence,
  not tickets or history; `tools/comment-only.py` proves a prose pass left
  the code alone.
- **§109 The helper owns the seat.** Protocol 7 (`seat`, `switch`, `share`,
  `events`) talks to Hyprland's IPC sockets from Rust with no shell; the
  panel spawns nothing for the seat. `hello 6` is still served, so the
  helper can be updated before the panel. Rejected: a uinput/root path.
- **§110 Reply meaning is a pure module.** `HelperReplies.js` returns
  actions; Keyboard.qml runs them in order against live state, because an
  earlier action can release a key or drop the connection.
- **§111 Windows map after the output is known.** No frame on the wrong
  monitor; a short fallback keeps the panel from staying hidden.
- **§112 The install record decides what OSKar may replace.**
  `~/.local/state/oskar/install-record` holds the sha256 or link text of the
  unit, the helper and `~/.local/bin/oskar`; anything else is left alone,
  and `--force` moves it aside, never deletes. systemctl acts only on the
  recorded unit, and `systemctl disable` is never used. The old-name
  migration was deleted: nobody else ever had the old name.
- **§113 Who changes it restores it, and it is listed.** The helper puts
  `input:kb_file` back (on SIGTERM too); a failed pick restores the previous
  clipboard text. README "What OSKar changes on your system" is the
  contract: a change missing from it is a bug.
- **§114 Restore only what is still OSKar's.** A copy the user made during a
  pick is not overwritten. `wl-copy` reads stdin and runs without
  `--foreground`, so the text survives a shell restart. Restore times are
  bounded. A missing user `kb_file` keeps its value; foreign settings keys
  are capped at 64 KiB.
- **§115 A keyboard that moved alone becomes the anchor.** "Alone" means: no
  other device moved within 150 ms, it is not the panel's own echo within
  500 ms, and it is the only identified keyboard that changed. Needed
  because fcitx5 and the helper hold `main`. Inside the settle window such a
  move is followed when it is the keyboard the panel already reads and no
  click was made (0.1.2). Limits: README known problem 3.
- **§116 Follow theme means all of it.** On, the theme answers all eight
  appearance fields and overrides lie dormant; editing a field turns
  following off. The frozen theme is saved as `theme_snapshot`.
  `panel_border` follows Hyprland's `general:border_size`. The text colour
  drives every foreground.
- **§117 The popover looks like an Omarchy panel.** Shell controls, four
  sections, Look: Omarchy theme | Custom, reset only where it changes
  something. Its chrome always uses the Omarchy theme, so a bad custom
  colour cannot hide the controls that undo it.
- **§118 The helper reports no lock state.** It always sends `locked = 0`.
  Sending real locks makes Hyprland turn Caps Lock back on in each window it
  focuses (README known problem 6).
- **§119 A colour field's paste chord is the paste chip.** Qt's own paste
  reads the whole offer before trimming it; the chip's read is bounded. This
  stays after the Qt fix.
- **§120 Colour fields are read-only to Qt.** A writable `TextInput` read the
  whole clipboard on every clipboard change and every focus-in (+193 MB for
  a 200 MB offer; QTBUG-149610, Qt 6.10.3–6.12.0, fixed in 6.12.1). Typing
  goes through `ConfigFile.fieldKeyEdit`, one text assignment per key; undo,
  redo, dead keys and the IME are lost. Guarded by `tools/qml-check.sh` and
  `tests/quick/colour-field-typing.qml`. Revert (see Open): remove
  `readOnly`, the cursor delegates, the `fieldKeyEdit` branch, the guard and
  that test; keep §119's paste branch and restore its middle-click
  MouseArea; re-check typing 2 over the selected 1 of "100" gives "200".

## Dead ends — do not retry

- Mirroring the seat keymap, or rate-limiting its symptoms (§3).
- `wtype` or any process per keystroke (§1).
- `hyprctl switchxkblayout all`, advancing a guessed device, unfiltered
  `main` (§5).
- Toggling `Socket.connected` to reconnect (§10).
- `hyprctl keyword` under the Lua config: it refuses; use `hyprctl eval`
  with `hl.config({...})`.
- IME or text-input routes: they never reach XWayland and fight layout
  toggles. Blaming the IME was measured wrong twice (§35).
- A helper keymap that differs from the compositor's without handing the
  compositor the same file (§35).
- Running the helper against the session you work in.
- Exotic free keycodes, or levels 3–4 where the layout leaves room, for the
  reserved block; gating it on `foot` or `x11cat`, which resolve keysyms
  themselves (§33).
- Delivering the block to Wine or Proton: Wine knows only Windows VK plus
  modifiers (§33).
- Recommending `grp:caps_toggle`: it breaks layout switching behind fcitx5.
