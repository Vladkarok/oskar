# Handoff — updated 2026-09-13 (evening, pre model-switch)

**START HERE — this section supersedes everything below it.**

The owner is switching the session model; no new agents are to be
launched until he says so. Both in-flight background agents have since
completed.

Landed since the block below, all reviewed `ship` unless said:
- **39** — "языки сломаны" root-caused LIVE: the §43 rename left ONE
  stale `.k` reader in `capsPositions` (Keyboard.qml), the caps
  request degraded to RALT alone, 26 letter caps fell back to the
  built-in tables — invisible on us (built-in IS qwerty), a broken
  ЙЦУКЕН on ua. Fixed in 6bcf8c5 (KeyboardLayout.declaredPositions,
  pin-tested); the owner confirmed it works.
- **40** — field-contract pins on every module-built family + the
  live-panel canary leg (panel_canary.py). Review round 1 block:
  the canary's venue guard passed on the working HOST; fixed in
  1d8a32d (OSK_PANEL_CANARY_LIVE=1 + lab hostname `testprod`, both
  refusals reproduced). Re-review ship. The canary's first live run
  caught the ticket-39 bug surviving in the lab's installed package
  (upgraded 0.1.0-1→0.1.0-2).
- Emoji search UX (5f272e3, ticket-29 follow-up): a field click now
  ALWAYS arms (the old toggle disarmed exactly when the owner clicked
  to focus); placeholder speaks the active layout (Пошук/Поиск/
  Search) and hides while armed. Owner asked for all three.
- **42** (5460dea + ae12035, review `ship`) — armed emoji search
  accepts the PHYSICAL keyboard: settingsLayer keyboardFocus primes
  Exclusive 75ms then OnDemand while emojiSearchActive (None→OnDemand
  never grants focus on a mapped surface — read from Hyprland 0.56.2
  source), FocusScope routes events through the pure
  `EmojiPage.searchKeyAction`; every disarm path restores None by
  binding. §52 + spec-v1.1 §5 amendment. Review round 1 block: the
  chord gate gated 0x08000000 as Meta (it is Alt) — Super chords
  leaked; fixed to Ctrl|Alt|Meta with AltGr explicitly typing
  (GroupSwitchModifier on Wayland). Its VM focus leg is STILL OWED
  (armed QMP typing lands in the query, Escape hands keys back,
  record the honoured mode).
- The ticket-35 chooser was lab-verified in the VM (green through the
  real UI path on us,ua,ru; screenshots in
  `.scratch/next-iteration/evidence/35/`) — and the same leg found a
  DEPLOYMENT defect, fixed in 56d7601: the Makefile's PLUGIN_RUNTIME
  missed LanguageControl.js/HoldColumn.js so a make-installed panel
  could not load; qml-check.sh now gates the packaged file set.
- SKIN_TONES pin (9b9fd07) — the last unpinned EmojiPage family.

Queue after the switch (owner decides order): **38 SHIPPED**
(73fe3e6/c422a43 + e7c5c83: SettleGuard.js pure seam, 14 tests, both
VM legs green — the incident's bounce repro prevented; ticket 42's
owed focus leg discharged by the same agent: armed QMP typing builds
the query incl. Cyrillic, Escape hands keys back); next is 41
(hold-menu accent layer via the §33 reserved block — design-first; a
good pass for a heavier model), then the publish decision (owner).

---

# Handoff — updated 2026-09-13 (late night)

**START HERE (previous round) — superseded by the block above.**

Since the RC close below, in order: **34** (usage-view snapshot —
implemented by a bounded subagent, verified twice, `ship`; owner's
click-through pending), README rewritten (derivation story removed by
the owner's decision, §43 amended; "How this compares" table against
GNOME OSK / plasma-keyboard / squeekboard-Stevia / wvkbd / onboard
added), the branch PUSHED to the private origin (`spec/v1.1-fixes`,
force-with-lease, synchronized). Off-product: a `plasma-osk` VM in
virt-manager (qemu:///session, user session) runs openSUSE Tumbleweed
KDE live, Plasma 6.7.5, with `plasma6-keyboard` 6.7.3 installed and
enabled for the owner's own look at the QtVKB/maliit stack — LIVE
session in RAM: a reboot loses the package and the kwinrc key (the
three restore commands are in the conversation log; KWin's InputMethod
key takes the .desktop path, not the binary).

**35 (language control shapes) — implemented + reviewed `ship`**
(commits 2fa745e, 86a57b7): one layout hides the chip (width and
margin collapse — hintText anchors its right edge), two keep the direct
toggle, three or more open a chooser dropping INTO the card over the
grid; `LanguageControl.js` (8-test suite, red first),
`Keyboard.switchToGroup` is the one primitive both shapes use;
review round 1 `block` (menu outside the input mask above the top bar;
panel-close race) → fixed → round 2 `ship`. Residuals on record in the
ticket: 8+ layouts would overflow (cap-and-scroll if ever needed).
Decisions §49. Owner's eyes on his three-layout seat pending, with the
standing round.

**36 (emoji search ru/uk) — implemented + reviewed `ship`** (commit
b52fecc): CLDR 46 ru/uk keyword vocabularies vendored (Unicode-3.0,
sha256-pinned) into the generated catalogue; the tiered search matches
them at identical tiers behind a per-term beyond-ASCII gate, so
pure-ASCII queries are structurally byte-identical (independently
reproduced on a 4,191-query battery, 0 diffs). Catalogue 573 KB →
1.0 MB (1.75x, under the 2.5x guard; the 1.4 MB derived-keyword
alternative measured and declined, on record). Battery 325 JS cases +
helper 45 + provenance 0, twice over (orchestrator + reviewer).
Accepted limitation on record: the uk apostrophe split (U+02BC vs
U+2019, 130 keywords) is not folded — recall-only, AND-safe. Decisions
§50's sibling call: predictions declined, search vocabulary taken.

**37 (hold-a-cap column menu) — implemented + reviewed `ship`** (commit
09ca4c3, decisions §51): hold a character cap ~320 ms and its keymap
position's levels 3-4 open a card-local column popover; a pick types
the level through the &123 glyph caps' exact chord. Column caps type on
RELEASE (a hold types nothing, starts no repeat, cancels clean);
everything without a column — stock two-level letters, Space,
BackSpace, modifiers, exact caps, searchMode — keeps press-types +
compositor repeat untouched. Level 2 deliberately excluded (the cap's
own Shift face); levels 5-8 stay &123-only (§33). Pure seam
`HoldColumn.js` (18 tests, red first); battery 343 JS + helper 45 +
clippy + provenance 0, twice over. VM-proven in the LIVE lab (venue
finding on record: the nested polygon cannot host the panel — its seat
exposes only the parent's wl_keyboard and LayoutDevices.isSafe refuses
it by design): hold typed nothing, level-3 pick typed §, quick click
typed 3, cancel/dismiss typed nothing. Review verdict ship; LOW
residuals on record in the ticket (menu-gap clicks dismiss; no fold
under a later-opened overlay; level-4 proven at the seam). Owner's
feel pass pending: threshold, digit-row fallback, gap-click.

One crash-recovery note: a ZCode crash killed both background agents
mid-flight; both were relaunched with identical briefs — 36's work was
already committed (lost nothing), 37 restarted from zero and landed
clean.

Owner gates otherwise unchanged from below: mouse/eyes acceptance of
the round — now including 34's click-through, 35's three-layout menu,
36's emoji search in ru/uk ("кот"/"кіт"/"яблуко"), and 37's hold feel
(threshold, digit-row fallback, gap-click) — and the publish decision.

---

# Handoff — updated 2026-09-13 (night)

**START HERE (previous round) — superseded by the block above.**

The external audit's execution round is COMPLETE and the RELEASE
CANDIDATE has passed its closing fresh adversarial review: **Verdict:
ship** (at be4b12e; the RC findings — two comment/doc staleness MINORs
and five NITs — are fixed in the round's last commit). All five tickets
implemented and committed on `spec/v1.1-fixes` (never pushed — the repo
has no public remote). Per-ticket verdicts: 28, 32, 06, 31 — `ship`;
33 — `do not ship` on its first tree, every finding applied verbatim in
its closing commit:

- **28 (f5bd4d6)** — clipboard emoji delivery is one serialized
  transaction (queue, real completion, compensations). VM wine leg
  proved two rapid picks byte/order-correct.
- **32 (42e4655)** — the `omarchy-osk` package lifecycle:
  /usr/bin/omarchy-osk setup/upgrade/status/teardown, honest dependency
  contract, stable tag-pinned PKGBUILD (publish-gated), full VM
  choreography green, decisions §45.
- **06 (a7acbb3)** — the custom kb_file survives shell SIGKILL and
  helper restarts (helper-owned sidecar, RuntimeDirectoryPreserve,
  observed-flag seed, exact path identity), 18/18 VM choreography,
  decisions §46.
- **31 (93bb161)** — the remembered layout group is bounded by the map
  that carries it (panel seam + daemon refusals), decisions §47.
- **33 (55a2513)** — lost tests restored (floatingAnchor,
  usesWinePasteChord with the original discriminating negative), Stage E
  preserved with the rerun caveat, external-picker text swept from code
  and spec, docs reconciled (orientation, release-plan banner,
  compatibility matrix in README), board statuses truthful.
- **be4b12e + the RC close** — the choreography scripts hardened (three
  set -e/pipefail traps the RC sweep caught live), the full
  release-candidate evidence run recorded (package phases 39/39,
  coldboot 4/4, recovery 18/18, nested exit 0 at 92 ≤ 142 —
  `.scratch/next-iteration/evidence/rc/`), and the RC review's residual
  findings fixed (stale comments, README's publish-day Status paragraph,
  status wording for a down helper).

Host: ten JS suites (config 39, modifier-reducer 96, clipboard-paste
22, keyboard-session 24, layout-devices 18, …) + 45 Rust tests, clippy
-D warnings, qml-check, provenance 0 — all green. The VM lab runs the
PACKAGED product (package installed, `omarchy-osk setup` active; the
synced source tree at ~/omarchy-osk feeds the choreographies).

## What is left, and whose it is

- **Owner gates**: mouse/eyes acceptance for the round's behavior
  changes (clipboard-mode rapid picks; kb_file recovery is
  background-honest; the matrix's claims), and the publish decision
  (push public, tag, .SRCINFO — the PKGBUILD documents the three steps).
  Owner-pending board items: 07/12/16/17/18/23/24/26/27/29 are
  ready-for-human.
- **Next agent work** (post-release backlog, audit's own list):
  three/four-layout chooser, long-press accents, localization,
  accessibility/touch, full-QML load gate, delivery policy seam,
  protocol hardening, catalogue loading — in that priority.
- Upstream notes queue (not blocking): the Electron-version issue
  (ticket 30 evidence), Hyprland same-window-click event absence
  (ticket 29's gesture workaround).

## Verification shortlist for a cold start

```sh
./tools/run-tests.sh          # ten suites
./tools/provenance.py         # exit 0
./tools/qml-check.sh
cargo clippy --manifest-path daemon/Cargo.toml --all-targets -- -D warnings
```
VM: `ssh omarchy-vm` — packaged product installed; `omarchy-osk status`;
phases via `tools/package-test.sh <phase>`; recovery choreography
`tools/keymap-recovery-test.sh run|cleanup`; nested suite
`tools/nested-session.sh tools/smoke-daemon.sh` (92 ≤ 142 rebuilds).
Known lab hazard: overlay-layer clicks can die while the emoji page is
open in THIS guest (rare-state; a shell restart clears it) — drives
that need clicks go through the seams instead.

---

# Handoff — 2026-09-13 (morning, ticket 28)

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
2. **After the domain power-cycle the nested suite's Electron leg died**
   (SIGTRAP; nested Hyprland logs "EGL setup failed", guest on llvmpipe;
   the domain video model is plain `vga`, no GL). **Recovered by itself
   after the next cold boot** (exit 0, 88 rebuilds ≤ 142) — transient
   environment state, not a regression; see the evening note above.

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
