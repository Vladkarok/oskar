# Handoff — updated 2026-09-13

**START HERE — this section supersedes everything below it.**

The tree was in a clean, working state at `d01ee62` (branch
`spec/v1.1-fixes`, 10 commits, suites green, provenance 0, panel
live-verified). Since then, **ticket 28's audit reopen is fixed,
reviewed `ship`, committed** — see below. `backup/pre-squash` still
holds the original 247-commit history for reference; delete it when
confident.

## Ticket 28 (P1) — landed 2026-09-13, reviewed `ship`

The audit's clipboard race is fixed: one pick owns publish→verify→
chord→completion (`ClipboardPaste.txn*`, pure); later picks queue in
order and never replace the owner an unfinished paste depends on;
`Keyboard.pasteCurrent(wmClass, completed)` reports the real outcome
(paced completion after the final dispatched line, immediate after the
writer accepts every line, synchronous false on refusal); usage/settle/
close only from `completed`; an aborted chord pays pure
`compensatingReleases` and converges by lifting. Decisions §44,
spec-v1.1 §1 amended, evidence in `.scratch/next-iteration/evidence/28/`
(VM wine leg: 😀 then 🔥 120 ms apart → journal shows the queue line and
two serialized Ctrl+AB04 chords; notepad reads exactly 😀🔥, each once,
in order). Host: 10 suites / 299 cases, 40 Rust, clippy, qml-check,
provenance 0, plugin-validate. Independent adversarial review:
**Verdict: ship**; its two actionable MINORs (empty-payload queue wedge,
abort sent-prefix overcount) fixed before the commit. Owner mouse/feel
acceptance remains a separate gate.

## VM lab faults found during the leg (both pre-date the fix; not code)

1. **Overlay input dies while the emoji page is open in THIS guest**:
   every pointer click (tiles, toggles, toast, keys) stops registering
   until the shell restarts; reproduced identically on the dd7b0c6
   packaged plugin. Same quickshell 0.3.1 / Hyprland 0.56.2 / scale 2 as
   the host, where the owner daily-drives the page — so guest-specific.
   Workaround used: drive `pickViaClipboard` through a guest-only
   FileView hook (removed after the run). If it recurs, bisect against
   the overlay layer's input mask.
2. **After the domain power-cycle the nested suite's Electron leg dies**
   (SIGTRAP; nested Hyprland logs "EGL setup failed", guest on llvmpipe;
   the domain video model is plain `vga`, no GL). All other legs pass
   and the daemon source is byte-identical to dd7b0c6 — an environment
   regression. Re-provisioning the domain with virtio-gpu+virgl would
   likely restore the leg.

## NEXT WORK — docs/audit-2026-09-13.md is the execution brief

Work its remaining tickets in order, one board ticket at a time:

1. **32 (P1)** — the AUR lifecycle: /usr/bin/omarchy-osk
   setup/upgrade/status/teardown, real dependencies (libxkbcommon,
   wl-clipboard are hard), .SRCINFO, clean-chroot build, the full VM
   choreography.
2. **06 (P2)** — a shell SIGKILL loses the custom kb_file;
   helper-owned runtime sidecar, exact-path identity.
3. **31 (P2)** — bound the remembered layout group to the current
   keymap (panel seam + daemon defence in depth).
4. **33 (P2)** — restore the lost tests, sweep stale picker text,
   reconcile the docs, add the compatibility matrix.

The audit's post-release backlog (#1-#8) stays post-release. Omarchy
first, direct emoji delivery the default, one coherent package.

## Standing owner decisions

- **Publish gate**: push + tag + AUR when the owner says so. The AUR
  PKGBUILD is committed and honest about its gates (public push, tag,
  .SRCINFO). The repo currently has no public remote.
- `backup/pre-squash` branch retention.
- Upstream notes to file (not blocking): Electron-version issue for the
  docked-content verdict (ticket 30 has the lab evidence); Hyprland
  same-window-click event absence.

## Verification shortlist for a cold start

```sh
./tools/run-tests.sh          # 10 suites (config 38/0, reducer 96/0,
                              # clipboard-paste 22/0 ...)
./tools/provenance.py         # exit 0
./tools/qml-check.sh
cargo clippy --manifest-path daemon/Cargo.toml --all-targets -- -D warnings
```
VM lab: `ssh omarchy-vm`, scripts /tmp/vmclean.sh (bottomtest fixture
in ~/bottomtest), signature via the socat probe (see vm-handoff). The
host panel is a symlink to this tree; `omarchy restart shell` after
QML edits; `./install.sh` after Rust edits. NOTE the two lab faults
above before trusting click choreography in this VM.

## History — what just happened (2026-09-12 evening → 09-13)

1. **Provenance zero**: the tree shares ZERO substantive lines with the
   upstream sketch (tools/provenance.py, gate = exit 0). Sole copyright
   in LICENSE. The forced-line exclusions (imports, shell type names,
   QML anchor idioms, the shell-IPC surface) are enumerated in the tool
   with reasons. The vocabulary was renamed throughout (chr/chrShift/xkb,
   cellGap, capGlyphSize, capCorner, capData, ...).
2. **History squashed**: 247 commits → 8 milestone commits (+2 fixes).
   Built via commit-tree (exact trees), verified identical to the
   pre-squash tip.
3. **Three contract bugs from the renames, all found by the owner, all
   fixed** — the lesson: never rename what is actually someone else's
   interface:
   - Quickshell `onExited`'s 2nd arg is **ExitStatus (0 = normal)**, not
     a boolean — `!ok` treated every clean exit as a crash (b98c520,
     folded into the squash tip).
   - The base.lst awk lookup: `$1=""; sub(/^ +/,"")` rebuilds the record
     (drops code AND separator); my `sub()` rewrite left garbage in the
     language-button label (670d6f2).
   - The **Omarchy shell-IPC contract**: the shell reads
     `loader.item.opened` and invokes `close()` BY NAME (shell.qml
     invokeIfLoaded). Renaming opened→shown / close→hide made the bar
     icon unable to hide the panel (dd7b0c6). All contract sites are now
     annotated and enumerated in provenance.py's forced set.
4. **Emoji-app machinery removed** (670d6f2): settings row, page chip,
   PATH probes, the emoji_app override — the panel's own page is the
   only picker. Spec §1 records the removal.
5. Audit round 1 landed (dead code, duplication); audit round 2 is the
   NEXT WORK.

---

# Handoff — updated 2026-09-11

**Start the next session with [release-readiness-plan.md](release-readiness-plan.md).**
It consolidates this session's findings, implementation/review evidence, owner
feedback (emoji now arrive in Codex; Proton remains broken), packaging options,
unfinished cleanup and the ordered release gates. It also corrects stale counts
and overstatements below; proposals are distinguished from approved behavior.

Written for a **cold start**: no prior chat needed. Read this, then
[decisions.md](decisions.md) §37–§40, then the ticket you are picking up.

**2026-09-11:** the plan to a first release is
[release-readiness-plan.md](release-readiness-plan.md). It synthesizes two code
reviews, kept as its evidence appendices:
[review-2026-09-11.md](review-2026-09-11.md) and
[review-astra-2026-09-11.md](review-astra-2026-09-11.md). Start with its §1 and
stage A; the two behaviour bugs it lists (R1, R2) come before the acceptance
work below. Where this handoff and the plan disagree, the plan is newer.

**2026-09-11 (stage A done):** the checkpoint is committed — `7baafee`
(runtime, tests, assets) and `9c2cd97` (plan and reviews); the tree is clean.
A2 followed (`3a2f55f`): board statuses reconciled with the cancelled
external-picker directions closed as history, and the two behaviour bugs
filed where they belong — **R1 on ticket 27** (a Recent tile re-applies the
current skin tone: drawn `👍`, inserted `👍🏿`) and **R2 on ticket 25** (paste
with the emoji search open goes to the focused external client). Both are
stage B of the plan and gate their tickets' acceptance. The owner confirmed
emoji arrive in Codex with the short `U+…` preedit acceptable (ticket 26);
the Proton case stays open (plan §6).

**2026-09-11 (stage B done):** R1 and R2 are fixed with regressions that are
red on the pre-fix tree (`cca9d17`), plus the plan's small fixes: F5
(protocol-4 dead err arms; `inputStatus` deleted — write-only; `sendText`'s
comment now states the protocol-5 reply contract), delivery-failure feedback
(a refused emoji pick raises the transient hint "Emoji could not be
delivered"), F6 (`hello` is exactly `hello <u32>`, fixed-arity verbs refuse
a third word; helper reinstalled via `./install.sh`) and F7 (README
autostart wording). Independent fresh-context review: **Verdict: ship**;
its two actionable LOWs fixed in `3723bcc`, the third (external probe does
not re-derive its target at arrival, ≤500 ms window) recorded on ticket 25
as an owner decision. Host: 286 QML/JS cases in ten suites, qml check
clean, 40 helper tests, clippy clean.

**2026-09-11 (stage C, automated half done):** R4 — the guest shell loads
the current tree with zero QML errors; the panel, the emoji page and the
settings card open and render (`evidence/13/r4/`). The nested suite grew
to 33 legs — the two text routes' modifier isolation pinned on the
observer's serialized mask, a focus split mid-Unicode-delivery, and a
SIGTERM landing mid-delivery: F4's scenario, which found and fixed a real
gap (the delivery now polls an atomic shutdown flag between scalars and
aborts within one beat, so the release wins the race the 500 ms guard was
losing; red on the pre-fix helper, green after; independent review
Verdict: ship). Churn ceiling re-derived 74 → 142. Ticket 25's
live/dead-owner recipe ran in the VM (`evidence/25/`). F11 measured:
Electron under app id `code` receives U+F601 for U+1F601 via the `text`
route (`evidence/13/f11/`).

**2026-09-12 (stage D2 complete; verdicts on 22/28/30):** the owner
accepted: Proton paste-on-click (28 resolved), the Super marks with the
CurveRenderer ⌘ (22 resolved), and the docked investigation's verdict
(30 resolved — the content clipping is old-Chromium Electron, fixed
upstream between ~118 and 152, lab-proven; the owner declined XWayland
and will wait for app updates). **The D2 choreography ran green in the
VM**: install → setup×2 (idempotent) → upgrade → teardown×2 (second
refused cleanly, no dangling enable symlink) → reinstall, protocol
verified at every step. **/usr/share registration proven**: the
packaged payload symlinked into ~/.config/omarchy/plugins loads — panel
renders, emoji page opens from the packaged tree (the plugin rescan
accepts a top-level symlink to system files). **AUR PKGBUILD ready**
(`-git` prototype, pkgver from commits, publish-gated to the owner:
public push, tag, .SRCINFO). The dead workspace-nudge code is removed.
Still owed: the accumulated independent review round (layout fix
e79d884, Proton pacing d9b42df, Esc aec2ffd, pkg work), the ticket-19
upstream notes, and stage E's cold-boot/E2E pass.

**2026-09-11 (stage C closed by owner acceptance):** ticket 13 is
**resolved** — the owner ran every owner leg and signed off ("r1 good,
r2 good", "все работает", "закрывай"). The verdict also decided three
things (decisions §41): the paste chip attempts unconditionally — ticket
25's liveness probe, watchdog and gone-hint are removed from the
external path, the R2 target determination and the panel-local read
stay; the stage-B delivery-failure hint is removed (the lifecycle hint
already covers a stopped helper); multilanguage emoji search is declined
for now. New work opened by the same verdict: **ticket 28** —
clipboard-compatibility emoji delivery (ZCode corrupts supplementary
emoji to PUA U+F8F7–F8FA; the owner named Emote/omarchy-menu-emoji's
clipboard route as the thing that works; release plan §6's proposed
ticket, awaiting the owner's one-word answers on default/switch/per-app
memory); **ticket 29** — the emoji search's visible active state and
focus-following typing (owner request); **ticket 30** — docked mode
hides the bottom edge of some windows (chats, TUI agents; investigation);
**ticket 22 reopened** — the macOS ⌘ renders pixelated; fixed with
layer MSAA on the Shape, needs the owner's eyes.

## Paste this

> Read `docs/session-handoff.md` and continue. Ticket 24 is fully landed —
> the panel's own emoji page, keyboard-driven search, delivery through the
> helper's `text` command, external-picker machinery removed. The owner accepts
> the page generally and requested ticket 27's icon categories, tooltips and
> one skin-tone selector. Tickets 25 and 27 are implemented and independently
> reviewed `ship`, but each now carries an open behaviour bug from the second
> review — R2 on 25 (paste with the search open goes to the external client)
> and R1 on 27 (a Recent tile re-applies the current skin tone) — so fix those
> (plan stage B) before pointer/eyes acceptance. The marks, colour squares
> and ticket 13's combined mouse regression still need the owner.

> Ticket 26 is implemented, VM-proven and independently reviewed `ship`:
> Chromium-family clients route
> through `text-unicode`, the page defaults to keep-open, has independent
> M/L/XL sizes, and persists one Most Frequent row plus Recent rows. Protocol
> is version 5. It awaits owner mouse/eyes.

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
delivery legs plus the Electron `text-unicode` leg; its churn ceiling is
74, derived in the script's own comment from the seat identities the
suite installs (ticket 26's 30-test VM run measured 68 rebuilds) —
re-derive, never re-measure, if legs are added.

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
  `macos`); the penguin now uses the owner's original SVG geometry without
  lettering, with fixed black/white colours and a white exterior outline
  (§38 records the amendment). Owner's eyes still pending.
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
- **26 — Chromium delivery and repeated-pick flow.** Chromium receives the
  correct supplementary-plane keysym but its editor narrows it to U+Fxxx;
  known Chromium-family classes now use a paced `text-unicode` route (§40),
  proven byte-exact in Electron 43 for plain supplementary emoji, skin tone,
  flag and ZWJ family with the clipboard unchanged. The picker defaults to
  keep-open; settings add independent M/L/XL page sizes and close-after-pick;
  a bounded persisted usage model draws one Most Frequent row and separated
  Recent rows, updating only after helper `ok`. Protocol advanced to 5.
- **25 — stale clipboard previews fail closed.** A paste-chip click first runs
  a bounded liveness probe. Timeout force-kills the probe; selection generations
  prevent a stale success from pasting newer content. Independently reviewed
  `ship`; the real live/dead-owner recipe awaits owner/VM acceptance.
- **27 — emoji categories, tooltips and skin tone.** Category tabs are emoji
  icons with accessible hover names; ambiguous icon controls share one tooltip;
  one persisted hand popup selects the default or five skin tones. Tone families
  occupy one catalogue tile and resolve to exact existing Unicode sequences.
  Independently reviewed `ship`; pointer feel and rendering await owner eyes.
- Nested suite: three `text` delivery legs (foot byte-exact once + clipboard
  hash, §35 invariants across a pick, x11cat byte-exact after the fix) plus
  the Electron `text-unicode` leg — ticket 26's VM run: 30 passed, 68
  compositor keymap rebuilds. Host suites after stage B: 286 QML/JS
  cases across ten files, 40 helper tests, qml static check clean.

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
2. **Tickets 25 and 27 acceptance** — live/dead clipboard recipe; category
   tooltips, skin-tone popup and rendered emoji.
3. **Ticket 13** — the combined mouse regression; its list grew by the
   page and the marks.
4. **Ticket 26 acceptance:** Chromium/Codex delivery and picker workflow on
   the host. Independent Sol review is complete with verdict `ship`; owner
   acceptance remains a separate gate.
5. **A refactor, deliberately deferred** — `main.rs` is now ~4600 lines;
   the agreed criterion stays "split by what can be tested at a seam",
   inside feature work that touches the files anyway.
