# Handoff — live host polish + next-iteration board

**Superseded.** A later session continues from
[`docs/session-handoff.md`](session-handoff.md) (paste fix + one-page `&123`).

Written 2026-09-08 ~02:05 for a fresh session. Owner asked for leftover-centre
(covering keys is the user's problem), remaining fixes, reviews, VM grim
judgement, and this document before usage died.

## Start here

Workspace: `/home/vladkarok/Projects/omarchy-osk`.
Branch: `spec/v1.1-fixes`. HEAD `46ea0cc`.

1. `git log -1 --oneline` and `git status -sb`. Do not reset. Planning
   dirt (`CONTEXT.md`, `docs/decisions.md`, `docs/orientation.md`,
   untracked `docs/next-iteration-*.md`, `docs/research-input-upstream.md`,
   this file) predates workers; never revert or stage it wholesale.
2. Read this file, then `.scratch/live-host/spec.md` and ticket Comments.
3. Live-host 01–07 are implemented and grim-reviewed except the custom
   colour editor, which has no usable screenshot. Then leftover
   next-iteration tickets (human leftovers; 05/06/13 still blocked).

Paste for the next runner:

> Read `docs/live-host-handoff.md` and continue. Grim the WinUI custom
> colour editor in the VM (HS square + V slider + hex). Nested harness
> is `.scratch/live-host/evidence/harness/custom-editor.sh` — `root` is
> four `..` from `harness/`, not five (five rsynced `$HOME` into the
> guest plugin; restored). Live QEMU tablet clicks miss overlay
> surfaces; use nested `click-at` or click the gear on the OSK layer
> first. Then remaining unblocked next-iteration tickets. Do not guess
> compact four-row. Do not call Codex.

## Binding owner directives

- **Fixes first**, not ticket 13, while the installed panel feels wrong.
- **Reviews:** adversarial subagent (`Verdict: ship` / `do not ship`),
  not `codex exec`.
- **Host** dogfood: plugin is a symlink
  `~/.config/omarchy/plugins/io.github.vladkarok.osk` → this repo.
  Helper: `~/.local/libexec/omarchy-osk-daemon` →
  `daemon/target/release/omarchy-osk-daemon`. `./install.sh` rebuilds
  the helper. `omarchy restart shell` if the bar icon is dead.
- **VM** for suites and grim (`ssh omarchy-vm`, guest `~/omarchy-osk`,
  `git pull --ff-only`). Env preamble in `docs/vm-handoff.md`; discover
  compositor/display from answering sockets. Guest sudo often fails;
  rsync QML without the provision script's sudo tail.
- **Settings placement:** leftover-centre. Covering keys is accepted.
  Keys not under the card must still type. Custom/hex overlapping the
  band must still receive clicks (own overlay windows as of `b4c737c`).
- **Custom colour:** WinUI mock
  `.scratch/live-host/references/custom-colour-winui.png`. Big HS square,
  thin V slider, hex + RGB/HSV. No hex pad. Main OSK types into the
  focused field. Hex: select-all; stock right-click cut/copy/paste
  (Controls `TextField` as of `46ea0cc`).
- **Emoji:** keep the overlay patch until an in-panel emoji page exists.
  Patch is applied on the host `/usr/share/omarchy`. `omarchy update`
  wipes it.
- **Compact four-row is not this release.** Five-row letters, pair caps
  on `&123`.
- Do not recreate daily Codex-retry automation.

## HEAD and commits this session

| SHA | What |
|---|---|
| `19245a2` | paste chip hidden until a non-empty preview |
| `b4c737c` | popover + editor as own Ignore overlay windows |
| `46ea0cc` | editor hex is Controls `TextField` (stock menu) |

Pushed. Guest clone pulled. Guest plugin rsync restored after a nested
harness bug copied `$HOME` into it.

Adversarial: `19245a2` **ship**; `b4c737c`+`46ea0cc` **ship**. Logs in
`.scratch/live-host/evidence/adversarial-review-*.log`.

Host `tools/run-tests.sh` at `46ea0cc`: settings-placement 8/0, helper
15/0, rest unchanged.

## Live-host board (`.scratch/live-host/`)

All seven tickets **ready-for-human**.

| Ticket | Status | Judgement from VM grim |
|---|---|---|
| 01 hover | ready-for-human | `hover-on-f.png`: cursor on `s`, modest theme lift, not white. Usable. |
| 02 paste | ready-for-human | `paste-url.png` URL chip usable. `paste-empty-now.png` hidden. Mid-clear glyph flash residual. Ukrainian unshot. |
| 03 header | ready-for-human | Gear, language, paste, Close. No Dock, no Shift-lock hint. Usable. |
| 04 radius | ready-for-human | `radius-xl.png` stored 24 at XL: letter caps are circles. L unshot. |
| 05 leftover | ready-for-human | Settings sits in leftover and covers keys (accepted). Overlay windows shipped; Custom click in live QEMU still misses. |
| 06 colour rows | ready-for-human | Per-row swatches + hex + check + Custom. Usable. |
| 07 custom colour | ready-for-human | `custom-final.png`: HS+V+hex+RGB+✓/×. Usable. Missing WinUI current-colour strip. Hex OSK typing unshot. |

`Process crashed: qml` toasts on the guest are `/usr/lib/qt6/bin/qml`
test runs with no display, not the panel.

## What is still unusable / unproven

1. **Custom colour editor in pixels.** Open Custom, grim HS+V vs the
   WinUI mock, click hex, type A–F on the OSK, grim. Nested harness
   path is fixed to four `..`. Do not rsync `$HOME`.
2. Live-session virtual-pointer **clicks** often move the cursor but
   do not activate overlay controls. Gear (OSK layer) sometimes works.
   Nested `click-at` is the reliable clicker.
3. Empty CLIPBOARD can flash a glyph during `wl-copy --clear`; settled
   empty hides. Confirm on the host.
4. Colour-row hex is still raw `TextInput` (editor hex is `TextField`).
5. Header anchor warnings: `Panel.qml` ~1969 / ~2001 (hint/service
   chips vs paste). Pre-existing, not this session.

## Next-iteration board (`.scratch/next-iteration/`)

Do not start 05/06/13 while live-host 07 is ungrim'd.

| Ticket | Status | Note |
|---|---|---|
| 01–03, 08, 11 | resolved | |
| 04 | ready-for-agent | implemented; human daily-use leftover; KeyboardSession third-seam residual |
| 05 | needs-triage | blocked on 04 human |
| 06 | needs-triage | blocked on 04 |
| 07 | ready-for-human | superseded by live-host 05–07 |
| 09 | ready-for-human | Emote `57fbc27`; XWayland paste leftover |
| 10 | ready-for-human | `ba838c7`; live insert grim leftover; host patch applied |
| 12 | ready-for-human | `4f77e43`; pair-cap pointer-feel |
| 13 | needs-triage | last |
| 14 | ready-for-human | `ffe6dc7`; picker-search paste leftover |
| 15 | ready-for-human | `929880a` |

## Host / VM recipes

Host:

```sh
cd ~/Projects/omarchy-osk
git pull
./install.sh                 # helper only
omarchy restart shell        # if bar icon dead
```

Guest:

```sh
git push
ssh omarchy-vm 'cd ~/omarchy-osk && git pull --ff-only'
# rsync QML — source is the clone, never $HOME:
ssh omarchy-vm 'rsync -a --delete --exclude .git --exclude daemon --exclude tools \
  --exclude core.\* --exclude .scratch \
  ~/omarchy-osk/ ~/.config/omarchy/plugins/io.github.vladkarok.osk/'
```

Nested custom-editor grim (after the four-`..` fix):

```sh
ssh omarchy-vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=wayland-1
# discover live HYPRLAND_INSTANCE_SIGNATURE from answering sockets
cd ~/omarchy-osk
tools/nested-session.sh bash .scratch/live-host/evidence/harness/custom-editor.sh'
# pngs in guest /tmp/osk-live-custom/
```

`hyprctl dispatch movecursor` is lua on this guest and rejects
`movecursor 400 640`. Use the virtual-pointer `MOVE_ONLY=1` binary
built at `/tmp/osk-live-host/move-at` instead.
