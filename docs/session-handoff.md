# Handoff — 2026-09-09, one keymap on the seat

Newest first. Everything below this heading is the current state; sections
further down are history.

## Where things stand

**Ticket 20 (`&123` symbols in Electron) and ticket 21 (the language button)
are both accepted by the owner on the host.** The symbols type where they
never did — «в клодкоде они работают, гуд» — and the switch moves the actual
typing, not only the indicator — «работает».

The two turned out to be one problem. Ticket 18's symbol block made the
helper's keymap differ from the compositor's, and a seat with two keymaps
hands a focused client whichever keyboard is active: every focus change swaps
them and every swap resets the client's group. Clients that re-read the group
were fine (Discord, browsers, terminals); the ones that do not typed the
previous alphabet until any modifier key arrived. Decisions **§35** ends the
divergence — the helper publishes what it installed and the panel points
`input:kb_file` at it, so the compositor compiles the same keymap for
everyone.

Three things worth carrying, all of them the same lesson in different clothes:

- **The measurement has to aim at the failure.** §32 allowed the divergence
  after counting keymap events while two typists alternated. Sound
  measurement, wrong target: the cost lands on focus changes, not on typing.
- **Two hypotheses died on the way, both plausible, both wrong.** That
  `switchxkblayout` does not reach clients — it does, measured on the device
  that actually receives the keys. And fcitx5 — stopping it changed nothing,
  twice. Both are in the dead-ends list now, because they will look plausible
  again.
- **Logic that cannot be called cannot be tested.** The device selection lived
  in a jq program inside a QML string and broke three times. It is
  `LayoutDevices.js` with fifteen cases now.

## Automated regression update

Both missing VM gates landed 2026-09-09 in the ordinary
`tools/nested-session.sh tools/smoke-daemon.sh` run:

- Ticket 20 launches Electron 43 as a native Ozone/Wayland consumer using the
  helper's shipping generated/published keymap. It gates an ordinary control,
  I219 as the known dropped negative control, and a product-discovered `£`
  with a real DomCode (`AE11` level 7 → `£·Minus`).
- Ticket 21 maps a tiny public Wayland observer under `WAYLAND_DEBUG`, hashes
  the actual `wl_keyboard.keymap` fd payload, performs exactly six verified
  focus transitions ending on the observer, and requires no intervening
  keymap event plus preserved group-1 typing (`й`) without repairing it.

VM result: **25 passed**, with **20** compositor keymap rebuild log lines
under the derived ceiling of 30. Host result: **328/0** panel assertions and
**25/25** helper tests. Red was replayed in the same nested VM against the
pre-§35 helper at `46a70f4`: it failed at the public boundary because no
`$XDG_RUNTIME_DIR/omarchy-osk/keymap.xkb` was published. The current tree then
passed the payload/focus/group gate above. That historical replay proves the
publication half only; it does not reconstruct the old alternating two-map
tail, whose nine-event trace remains the direct evidence for that failure.

## What is still open

Ticket 20 is closed and ticket 21 with it. The nested suite in the VM runs
**25 tests** and two of them are the ones this work owed: Electron 43 on the
published keymap (with the dropped `I219` as its negative control), and six
focus changes against one keymap payload. Wine is a recorded limit, not an
open item — it knows Windows VKs and no xkb level above the second.

Nothing here is blocked. The next things worth doing are the tickets that were
deliberately left alone during this run: 05, 06 and 13, and the owner's own
feel notes on `&123`.

## Tests

Helper 25/25 (`cargo test --manifest-path daemon/Cargo.toml`), panel 328/0
across nine offscreen suites (`./tools/run-tests.sh --js-only`), and nested
guest integration 25/25 with both consumer regressions above.

## Environment notes from this session

- The helper logs `group -> N` on every group move. This class of failure is
  invisible from both ends and the owner is the only one who finds out.
- The panel logs one line per press and per reading (`[osk] switch:` /
  `[osk] read:`). Left in deliberately; they are what turned four rounds of
  guessing into one measurement.
- `ls -t` is aliased on the host and eats `-t`. Use `command /bin/ls -t` when
  finding the Hyprland instance signature.

## How to measure this without wasting an evening

Three traps, all hit on 2026-09-08:

1. **Put a control key in every run.** A scan of all fourteen positions
   returned fourteen "no"s because the probe window was not focused. An
   ordinary letter typed first turns that into an obvious "NO — probe not
   receiving" instead of a false finding.
2. **`kb_file` under `/tmp` is invisible to the helper** — the unit sets
   `PrivateTmp=yes`. `ProtectHome=read-only`, so a path under `$HOME` works.
3. **The live panel overwrites an experimental `kb_file` within seconds**; it
   reconfigures on every layout event. Run keymap experiments in the nested
   session, where no panel is running — the way ticket 18's gate did.
4. **A nested session launched over ssh needs `WAYLAND_DISPLAY=wayland-1`
   exported** — libwayland defaults to `wayland-0`, the live session publishes
   `wayland-1`, and without it the nested Hyprland dies in
   `CBackend::create()` before any socket exists. `tools/nested-session.sh`
   now handles this itself (2026-09-09).
5. **Probe Electron, not chromium** (rig README has the flags): plain
   Chromium 152 in the nested VM session maps its window, runs the page JS,
   and composites no frame under any flag combination — every input event is
   rejected — while Electron 43 renders and takes input fine. The levels-5-8
   probe drove Electron through the panel's own press shape and read answers
   off the window title.

The probe that works: a page that appends every `keydown`'s `event.key` to
`document.title`, read back with `hyprctl clients -j`. Launch chromium with
`--user-data-dir=/tmp/chromeprobe --ozone-platform=wayland|x11` from a script
with `setsid nohup … & disown` (a bare `&` inside a tool call does not
survive). Do this in the VM: the host is the owner's working desktop and the
probe steals focus.

`foot` and `x11cat` both resolve keysyms themselves, so **no test built on
them can catch a DomCode-table drop.** That gap is ticket 20's acceptance
criterion.

## What shipped and is installed

Nothing is committed. HEAD is still `2247945`; the working tree carries all of
it. Both helpers are installed and running (`./install.sh` on host and guest).

- **Ticket 16 — language switch no longer flickers.** Keycap facts are held per
  group for a keymap generation and every group is pre-fetched, so a switch is
  a lookup; a group-only configure no longer closes the typing gate; the symbol
  map is cached per configure line; both layout pipelines run under `bash -c`;
  `updateLayoutRows` compares before reassigning the Repeater model. Verified
  on host and guest, including four groups: a second cycle through all four
  produces no process spawn and no caps request.
- **Ticket 17 — a stopped helper releases what it holds.** SIGTERM/SIGINT/
  SIGHUP are blocked just before the threads and consumed by a `sigwait`
  thread that lifts every held code, zeroes the mask and **round-trips** —
  `flush` alone lost the race against the disconnect, measured. Verified with
  a held Enter that runs the stop itself, a held Shift, and a whole chord.
- **Ticket 18 — layout-independent symbols.** The helper appends a reserved
  block to every keymap it installs; the panel discovers it through the `caps`
  facts it already requests (protocol stays 4) and resolves caps **by
  character**, not by keysym. Works in terminals and XWayland; ticket 20 is the
  part that does not.
- **Ticket 19 — the temporary-`us` group switch is gone**, every `&123`
  character is a glyph cap, and `cycleLanguage` moves a **filtered** device set
  (12 devices before, 3 after — the Razer that decisions §5 names, both power
  buttons, both `video-bus`, and the helper's own virtual keyboard are all out).
- The §11 xkbcli pipeline is **removed** — no cap used `lvl`/`token` any more.
  That took ~50 ms of process spawn per keymap identity and a false "Keymap
  unavailable" state with it. The caps redraw moved from `onPairPositionsChanged`
  to `onCapsFactsChanged`, which is the trap that removal sets.
- **decisions §32** records the measured answer to §3's byte-identity worry:
  six real alternations between the helper and QEMU's emulated PS/2 keyboard
  (`virsh send-key` from the host) left the client's `wl_keyboard.keymap` count
  at **one**. The divergence costs a single keymap push, not one per
  alternation.

## Review state

Two adversarial Opus 5 reviews ran. The first returned do-not-ship on four
findings; all four are fixed and confirmed by the second. The second returned
do-not-ship on the `cycleLanguage` device set, the helper's own device being in
it, and §3's byte-identity — the first two are fixed above, the third is
answered by §32. Everything else it raised (four MEDIUM, six LOW, the churn
ceiling) is closed; the ceiling is now **derived** in `tools/nested-session.sh`
(11 installs x 2 lines = 22, ceiling 24) rather than copied from a measurement.

One review finding was **rejected on evidence** and the reviewer agreed the
conclusion while correcting the reasoning: `typingReady`'s exposure is the
`inputReady` latch, not the queue test. Do not re-add a group check there
without reading that exchange in ticket 16.

## Tests at this tree

- Helper: `cargo test --manifest-path daemon/Cargo.toml` — **19 passed**.
- Panel: `./tools/run-tests.sh --js-only` — **309 checks, 0 failed**, eight suites.
- Guest: `tools/nested-session.sh tools/smoke-daemon.sh` — **23 passed**, 22
  compositor rebuilds against the derived ceiling of 24. The nested session
  fails to publish a monitor roughly a third of the time; re-run before
  believing a failure.

## Environment

- Host `kb_layout = us,ua`. VM `us,ua,it,ru` — deliberately more groups than
  the host, because a two-group session cannot exercise the per-group
  pre-fetch. XKB carries at most **four** groups; a fifth is dropped with one
  line on stderr and the layout simply is not there.
- Host plugin is a symlink to this repo: `omarchy restart shell` picks up
  QML/JS. Helper changes need `./install.sh`.
- The guest plugin is a **copy**, not a symlink — `rsync` the repo to
  `~/omarchy-osk` then to `~/.config/omarchy/plugins/io.github.vladkarok.osk`.
- Both shell patches in `patches/` are no longer applied anywhere; the orphan
  `PickerFit.js` the emoji patch left in `/usr/share/omarchy` is deleted.

## Owner acceptance still open

Click the language button on host and VM and confirm physical typing, the bar
indicator and the OSK caps move together. Mid-hold `hyprctl reload` and hotplug
are structurally free of the deleted restore path but were never replayed
through a real mouse button. `PartOf=graphical-session.target` teardown is
untested; a 500 ms guard thread bounds it either way.

# Latest implementation update — 2026-09-08

Owner reported the OSK language button changed its caps while a physical VM
keyboard stayed on another group; the shell bar switch worked everywhere.
Ticket 19 implementation now mirrors the bar: every device carrying the same
layout list moves serially to one absolute group. The temporary `us` switch for
ASCII punctuation was deleted. All `&123` characters resolve through the
reserved block, whose 56 entries now prioritize the complete visible page.

Checks: JS 307/0 host+guest, helper 18/18, guest nested 22/22. Six deliberately
divergent guest devices converged to one index with the new algorithm. Helper
and QML are installed on host and guest. Owner click/feel check and independent
re-review remain. Do not call ticket 19 shipped yet.

The VM LUKS key was enrolled, embedded in the UKI and proved by a real reboot:
SSH returned unattended after 15 seconds; the user graphical-session target
and helper were active. The older auto-unlock progress notes below are history.

---

# VM auto-unlock progress — 2026-09-08

General passwordless sudo now verified working on guest testprod. Generated
root-only `/crypto_keyfile.bin` (64 random bytes, never printed) and backed up
LUKS header to `/root/osk-lab-autounlock/luks-header.before.img` in guest.
Key is NOT enrolled yet; active dm-crypt key is kernel-keyring backed.
Owner must run in VM terminal:
`sudo cryptsetup luksAddKey /dev/vda2 /crypto_keyfile.bin`
and enter existing disk passphrase. Next agent steps after enrollment:
verify with `cryptsetup open --test-passphrase --key-file ...`, include the
key via a mkinitcpio FILES drop-in, backup current UKI/limine config, rebuild
using `limine-mkinitcpio` (not wrapper mkinitcpio -P), verify key inclusion,
then reboot and prove unattended SSH and graphical session recovery.
Guest uses encrypt hook whose default key path is /crypto_keyfile.bin.
Do not claim auto-unlock configured before reboot proof. No host disk changes.

---

# VM access update — 2026-09-08

VM is now running under `virsh -c qemu:///session`, SSH works (`ssh -x omarchy-vm`).
Root is still LUKS; general `sudo -n true` fails (password required), and no
QEMU guest agent is configured. Owner explicitly wants unattended VM boot
and authorises agents to start the test VM themselves. If stopped, use
`virsh -c qemu:///session start omarchy-osk`; never start the standalone
launcher concurrently against the same disk. LUKS auto-unlock/removal remains
unfinished, not disabled. Prepared and visudo-validated guest sudoers file:
`/tmp/99-osk-lab-sudo`; installing it requires one sudo-authenticated action.
Unicode VM proof can resume now; host keymap remains unchanged.

---

# Latest: shared Unicode map experiment — 2026-09-08

Owner approved the permanent shared-keymap approach for layout-independent
special symbols, rejecting clipboard/IME backends. VM was unavailable
(SSH port 2222 refused); owner asked to start/unlock it, no response yet.
Compile-only proof in `.scratch/unicode-symbols/README.md`: five symbols
resolve identically in US/UA; one I248 eight-level candidate preserves all
233 occupied <=255 symbol inventories. Runtime delivery/modifiers/XWayland
and keymap churn remain untested. No host configuration or product edits
for this experiment. Continue with VM proof, not host installation.

---

# Current update — 2026-09-08, Astra/Sol session

This update supersedes conflicting instructions in the evening snapshot below.
Agent execution/review policy: [agents/workflow.md](agents/workflow.md).
Host tests are offscreen only; run nested Hyprland / graphical fixtures in
the VM to avoid opening windows and stealing the owner's focus.

Owner authorised implementation of the revised `&123`: five rows, direct
ASCII punctuation, digits via Shift on ! through ), useful central slots,
no dead £/¥/×/÷ caps, media controls moved out of the ordinary symbols page.
Preserve the main page's exact Backspace, Delete, Enter, both Shift, Up and
command-row geometry. Implementation is complete; 299 offscreen JS checks passed. Independent
product review hit account quota without a verdict; owner trial and review
remain. Workflow and test-launch guards received independent ship reviews. The old instruction to wait for a feel note is
superseded by this explicit request.

Ticket 04 accepted by owner: «04 все гуд вроде, да»; marked resolved.
Tickets 05/06 remain unscheduled; 13 stays last.
Preserve existing dirty work, including paste AB04/agterm. No push requested.

---

# Handoff — 2026-09-08 evening

For a **completely fresh session**. Older `docs/live-host-handoff.md` and
`docs/next-iteration-handoff.md` are historical; this file is what to do
next. No prior chat is required.

## Paste this

> Read `docs/session-handoff.md` and continue. Do not reset, revert, or
> stage the planning dirt. Uncommitted `Keyboard.qml` / `KeyboardLayout.js`
> / `ModifierReducer.js` + their tests + `docs/decisions.md` §30 are the
> live paste + `&123` work — preserve them. Host plugin is a symlink; you
> may `omarchy restart shell` after QML/JS changes. Helper via
> `./install.sh` only. Adversarial subagents (`Verdict: ship` / `do not
> ship`), not Codex. Compact four-row is not this release. Ticket 13 last.
> Do not start 05/06/13 unless asked. Owner is dogfooding `&123` (one page,
> Shift = Windows page 2); wait for the next feel note before inventing
> more symbols packing.

## Start here

Workspace: `/home/vladkarok/Projects/omarchy-osk`.
Branch: `spec/v1.1-fixes`, **ahead 6 of origin**, HEAD `2247945`.

```sh
git log -1 --oneline
git status -sb
```

Do not reset. Two layers of dirt:

1. **This session (uncommitted, live on the host via symlink + shell
   restart).** Must survive. Not reviewed, not committed, not pushed.

   | Path | Why |
   |---|---|
   | `ModifierReducer.js` | paste chord AB06→AB04 (V, not N); `agterm` in terminal CLIPBOARD classes |
   | `KeyboardLayout.js` | one five-row Windows `&123`; Shift layer = old page 2 |
   | `Keyboard.qml` | main↔symbols only; latin `group` switch around US punctuation; Shift picks `sk`/`slvl` |
   | `tests/modifier-reducer.qml` | AB04 + agterm |
   | `tests/keyboard-layout.qml` | one-page duals |
   | `tests/config.qml` | dual count 18 + 10 digits |
   | `docs/decisions.md` | §30 |

2. **Pre-existing planning dirt** (do not revert or stage wholesale):
   `CONTEXT.md`, `docs/orientation.md`, `patches/README.md`, untracked
   `docs/live-host-handoff.md`, `docs/next-iteration-*.md`,
   `docs/research-input-upstream.md`, **this file**.

Host: plugin
`~/.config/omarchy/plugins/io.github.vladkarok.osk` → this repo.
Helper: `~/.local/libexec/omarchy-osk-daemon`. QML is live after
`omarchy restart shell`. Helper only via `./install.sh`.

Then: `CONTEXT.md`, `docs/decisions.md` §17 §26 §30, this file.

## What the owner just confirmed

1. **Paste of clipboard emoji into the terminal.** Was opening a new
   terminal. **Fixed. Owner: «отлично, починил!»**
2. **`&123`.** First pass was two Windows pages. Owner: progress, but
   **do not want two pages** — keep five rows, overflow through Shift.
   One-page duals are what is on the host now. Owner: «уже лучше!»
   *before* the collapse; the one-page packing has had no second grim.
   Next feel note from the owner is the authority, not ticket 12.

## Paste (done)

Bug: `pasteChordForClass` sent Ctrl+Shift+**AB06**. AB06 is **N**
(z x c v b **n**). kitty / ghostty / agterm bind Ctrl+Shift+N to a new
window. V is **AB04**.

Fix (uncommitted):

- `ModifierReducer.js`: position `AB04`; add `"agterm": true`
  (reverse-DNS last component covers `com.umputun.agterm`).
- Empty/stale class still uses the terminal CLIPBOARD chord, now V.
- Tests updated. `tools/run-tests.sh --js-only` green.

Do not “fix” this again by sending AB06 or by classifying agterm as
Shift+Insert.

## `&123` (in progress, one page)

Owner photos:
`.scratch/next-iteration/references/windows-symbols-{one,two}.png`.

**Supersedes** ticket 12 / `docs/compact-control-map.md` pair-cap packing
and the two-page cycle. Spec-v1.1 dual-keymap-caps language is also
stale for this page. Decisions **§30** is the current rule.

Cycle: letters `↔` symbols. Labels `&123` / `ABC`. Command row, Fn,
header, paste **unchanged** (not the Windows abc/Ctrl/Win/comma row).

Five rows, 15.5 units, `↑` at 12.5 on the Shift row:

| Row | Content |
|---|---|
| 1 | Esc 1.5, digits 1–0 (exact L1), Backspace 4.0 |
| 2 | Tab 1.5, ten duals, Enter 4.0 |
| 3 | ◀ ▶ 1.5, eight duals, Home 1.5, End 2.0, spacer 1.0 |
| 4 | Shift 2.5, Del, Ins, six spacers, PgUp, PgDn, ↑, Shift 2.0 |
| 5 | command row |

Dual pairing (base / Shift) — Windows page 1 over page 2:

- `!%` `@[` `#]` `${` `^}` `&<` `_>` `-€` `=£` `+¥`
- `;*` `` :` `` `(°` `)×` `/÷` `'~` `"|` `?\`

Cap shape: `{ t, s, k, baseLvl, sk, slvl, latin, fixedGlyph, dual }`
or `shiftToken` instead of `sk`/`slvl`. **No `lvl` on duals** — `isDualKey`
treats `lvl` as a single-level cap.

Typing:

- ASCII: exact US chord. `latin: true` → helper `group <usIndex>` around
  the press, restore on release / panel close. Needed because ua AE02 L2
  is `"` not `@`.
- Digits, media (I173/I171), Euro (I443): no group switch.
- `£ ¥ ° × ÷`: `shiftToken` via `buildTokenIndex` of the **current**
  group. Miss: glyph still drawn, Shift press is a no-op. On owner
  `us,ua`: `°` works on ua; `£ ¥ × ÷` are dead on both.

Press path: `Keyboard.qml` `pressChar` — if Shift is active and `sk`
exists, send that chord with `exact: true` (latch already chose the
layer). Unresolved shift token + Shift held → return without typing the
base.

Likely leftover if the owner is still unhappy:

- Pairing of page-2 glyphs onto those bases (agent chose the Windows
  column stack; do not reshuffle unless asked).
- Dead `£ ¥ × ÷` on us/ua (§17: no Unicode injection, no extra keymap).
- Six spacers on the Shift row (Del/Ins/PgUp/PgDn are extras vs Windows).
- Esc 1.5 / Bksp 4.0 vs letters Esc 1.0.

## Tests at this tree

`./tools/run-tests.sh --js-only` after the one-page change:

| Suite | Result |
|---|---|
| config | 41/0 |
| keyboard-layout | 35/0 |
| modifier-reducer | 88/0 |
| settings-placement | 8/0 |
| cursor-policy | 35/0 |
| keyboard-session | 16/0 |
| picker-fit | 50/0 |
| picker-session | 27/0 |

Helper cargo tests not re-run this evening (no daemon change). Guest
`qml` coredumps are the offscreen runner, not the panel.

## Binding owner policy (still)

- **Fixes first** while the installed panel feels wrong. Ticket **13 last**.
- Reviews: adversarial subagent, `Verdict: ship` / `do not ship`. Not Codex
  (quota). Do not recreate Codex-retry automation.
- You **may restart the shell yourself** after host-visible QML/JS.
- Compact **four-row is not this release.** Five-row letters stay.
- Settings: leftover-centre; card **must scroll**; must not cover keys
  (that “covering is accepted” line was **superseded** — `67797b5`).
- Paste chip: text preview as-is; no clipboard pictogram required.
- Emoji overlay patch on host `/usr/share/omarchy` until an in-panel
  emoji page exists. `omarchy update` wipes it.
- Do not guess a new `&123` map. The photos + the one-page/Shift note
  are the map. `docs/compact-control-map.md` is **not**.

## HEAD vs this session

Pushed tip is **not** current. Origin is 6 commits behind HEAD.
HEAD `2247945` is settings/paste-chip work. The 6 unpushed commits
are settings (scroll, custom Apply, RGB/HSV z, opaque menus, image
clipboard classification). **Do not push unless asked.**

This session’s paste/`&123` sits **on top of HEAD, uncommitted.**

Earlier host dogfood the owner already liked: custom colour Apply
(`eec2c97`, «бомба»), leftover scroll, RGB/HSV above fields, hover not
white, L/XL radius 24, header no Dock.

## Boards (do not blindly `/board`)

`.scratch/` is gitignored.

**Live-host** `.scratch/live-host/` — 01–07 implemented, grim’d,
ready-for-human. Custom Apply closed later at `eec2c97`. Not the
active work.

**Next-iteration** `.scratch/next-iteration/` — 15 tickets. Snapshot
from the previous orchestrator (statuses drift; read the files):

| Ticket | Note |
|---|---|
| 01–03, 08, 11, 14, 15 | landed earlier; leftovers in Comments |
| 04 | ready-for-human; 05/06 blocked on that human |
| 07 | superseded by live-host settings |
| 09, 10 | ready-for-human; picker leftovers |
| **12** | pair-cap packing **superseded by `&123` above** |
| 13 | last; do not start |
| 05, 06 | blocked; do not start unless asked |

## Host / VM

Host:

```sh
cd ~/Projects/omarchy-osk
# QML: omarchy restart shell
# helper: ./install.sh
```

Guest (`ssh omarchy-vm`, clone `~/omarchy-osk`): env in
`docs/vm-handoff.md`. Discover compositor/display from answering
sockets. Nested harness: **four** `..` from `harness/`, never five
(five rsynced `$HOME` into the guest plugin). Live `click-at` often
only moves the cursor; nested `click-at` or QMP tablet. Guest sudo
often fails.

## Dead ends (do not retry)

Full list at the bottom of `docs/decisions.md`. Relevant here:

- Clipboard / Unicode-entry / extra keymap to type `£ ¥ × ÷` (§17).
- Sending paste as AB06, or Shift+Insert into kitty/agterm.
- Codex as the reviewer.
- Four-row compact this release.
- `wtype`; mirroring the seat keymap; `switchxkblayout all`.
