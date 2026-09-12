# Handoff — 2026-09-10

Written for a **cold start**: no prior chat needed. Read this, then
[decisions.md](decisions.md) §37–§39, then the ticket you are picking up.

## Paste this

> Read `docs/session-handoff.md` and continue. Ticket 24 is fully landed —
> the panel's own emoji page, keyboard-driven search, delivery through the
> helper's `text` command, external-picker machinery removed. What is left
> needs the owner: feel acceptance of the page, the marks and the settings
> colour squares, then ticket 13's mouse regression. Ticket 25 (paste chip
> vs a dead clipboard owner) is ready-for-agent with the isolation done.

## Where things are

Workspace `/home/vladkarok/Projects/omarchy-osk`, branch `spec/v1.1-fixes`,
**ahead of origin and never pushed** — do not push unless asked.

```sh
git log --oneline -8
./tools/run-tests.sh          # offscreen suites + qml check + helper unit tests
```

The host plugin is a **symlink** to this repo: `omarchy restart shell`
picks up QML and JS. The helper is a binary — `./install.sh` after any
Rust change. The nested integration suite (`tools/smoke-daemon.sh` under
`tools/nested-session.sh`, in the VM only) now carries three `text`
delivery legs; its churn ceiling is re-derived at 74 (measured 44–52) —
re-derive again if legs are added, per the script's own comment.

```sh
rsync -a --delete --exclude '.git' --exclude 'daemon/target' --exclude '.scratch' \
  ./ omarchy-vm:~/omarchy-osk/
ssh omarchy-vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u); export WAYLAND_DISPLAY=wayland-1;
  cd ~/omarchy-osk && cargo build --release --manifest-path daemon/Cargo.toml &&
  tools/nested-session.sh tools/smoke-daemon.sh'
```

The VM is running and is where anything involving a compositor belongs.
`docs/vm-handoff.md` is its manual. Two of its traps were re-paid this
session: `pkill -f` on a pattern your own command line contains killed an
ssh session, and `hyprctl dispatch movecursor` is refused by the Lua parser
— position the cursor with QMP `input-send-event` abs axes (0–32767 over
the screen) instead; `virsh -c qemu:///session qemu-monitor-command
omarchy-osk '{"execute":"input-send-event",...}'` clicks and moves for any
UI proof, and `omarchy-shell shell toggle io.github.vladkarok.osk` needs
`OMARCHY_PATH=/usr/share/omarchy` exported or the panel never appears.

## What landed since the last handoff (all on this branch, unpushed)

- **23 — a colour row shows the colour it is set to.** Each row opens with
  a non-clickable indicator square: checkerboard underlay for alpha, two-
  contrast edge for near-black/near-white, bound to a row-local committed
  value (the row's `effectiveColor` binding does not notify — the row's own
  comment records why). Owner's eyes still pending.
- **22 — the Super mark is a setting.** Default is the word `Super`;
  word / Omarchy / Windows / macOS / penguin from the settings card. After
  the owner looked: sharp Windows panes, the macOS arm draws ⌘ (store value
  `macos`), the penguin was redrawn with a face (§38 records the
  amendment). Owner's eyes still pending.
- **24 — the panel's own emoji page, fully.** Steps 1–5: vendored CLDR
  catalogue (§37); the page on the settings card's mechanism, never
  covering the keys; search typed on our own keys — nothing reaches the
  helper while it is open; delivery through the helper's `text` command
  (§39: transient keymap swap, the settle is before the restore — the
  restore upload was the race, XWayland resolved picks against the
  previous map until it was measured); external-picker machinery removed,
  the configured app remains available from a page chip with no
  cooperation from us (§24 stays as the history). The paste-chip symptom
  the owner reported under this ticket is isolated as **ticket 25** — a
  dead clipboard owner, not a chip defect, reproducible with plain
  `wl-clipboard`.
- Nested suite: three delivery legs (foot byte-exact once + clipboard
  hash, §35 invariants across a pick, x11cat byte-exact after the fix).
  Cargo tests 36. QML suites 302 checks across nine files.

## Traps this project paid for again this session

- **A fixture set of easy cases, third occurrence.** The emoji search
  shipped with a case-insensitivity test run against a lowercase-named
  entry while 388 capitalised names (every flag) were unfindable. The
  awkward shape is the test.
- **Measure the named consumer.** foot passing said nothing about
  XWayland: the x11cat delivery leg failed deterministically (`🙂` typed
  `й`) while every Wayland-side check was green. The daemon's own header
  had warned that wtype-class keymap swaps lose to XWayland — the warning
  was about the restore, and only the leg found which end raced.
- **A wrong first fix can be worse than no fix.** Applying §33's
  permanent-hosting refusals to the *transient* pick refused all 26 letter
  positions on the stock layout — `err no slots` on every pick. Permanent
  gates protect the install's lifetime; a pick lasts ~60 ms. §39 records
  which gates transfer.
- **Guest env over ssh:** `omarchy restart shell` needs
  `OMARCHY_PATH=/usr/share/omarchy` exported *before* it runs, or the
  shell "fails to restart" and the session looks dead. It isn't.

## Next

1. **Owner acceptance** (mouse and eyes, host + VM): the emoji page feel,
   delivery into real apps, the Super marks at M/L/XL both themes, the
   colour-row squares, the external-app chip.
2. **Ticket 25** — paste chip vs a dead clipboard owner; isolation and
   recipe are in the ticket.
3. **Ticket 13** — the combined mouse regression; its list grew by the
   page and the marks.
4. **Maybe**: an electron43 `text` leg — the named three consumers are
   covered, but the DomCode history makes Chromium's stack the suspicious
   one; the ordinary letter positions and §33's chord measurements say it
   should work.
5. **A refactor, deliberately deferred** — `main.rs` is now ~2400 lines;
   the agreed criterion stays "split by what can be tested at a seam",
   inside feature work that touches the files anyway.
