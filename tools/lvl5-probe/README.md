# Levels 5-8 probe — ticket 20's first task

Measured answer, 2026-09-09: **a native Wayland client honours
`ISO_Level5_Shift`.** Electron 43 (native Ozone/Wayland, the ticket's
consumer class) received every level 5-8 chord on ordinary alphanumeric
positions, three runs, 12/12 steps each. The fix shape this decides:
the reserved catalogue moves to **levels 5-8 of ordinary positions**;
the levels 3-4 route stays rejected as layout-dependent.

This directory is retained as the historical design probe. It is not the
product regression gate: the ordinary VM nested integration suite now drives
Electron 43 with the helper's shipping generated/published keymap, including
the ordinary control and exotic-keycode negative control below.

## The question and the rig

The reserved block sat on exotic free keycodes that Chromium's
Ozone/Wayland DomCode table drops (ticket 20). The candidate fix needs
levels 5-8 of ordinary positions, which needs `<LVL5>` — already in every
compiled keymap as `ISO_Level5_Shift`, `modifier_map Mod3 { <LVL5> }`
(verified in a compiled `us` dump, `<LVL5> = 203`; `<LVL3> = 92` is
`modifier_map Mod5`). Measured, not reasoned: the chords below were typed
by the helper's virtual keyboard into focused probe windows inside the
nested session, in the VM, with an ordinary-letter control gating every
leg.

Files (this directory, host) → `~/lvl5-probe/` (VM, `scp -r`):

- `make_keymap.py` — builds `probe.xkb` (`include "pc+us+inet(evdev)"`,
  eleven positions AD01–AD10 + AE01 retyped to an eight-level type `OSK8`)
  and compiles it to `lvl5-probe.keymap`, the serialized text the helper's
  `kb_file` consumes. Level 5 carries the ten real `&123` page glyphs
  (`£ € ¥ ¢ ° ± × ≈ ÷ ≠`), levels 6-8 distinct Latin-1 families so a
  character names its level. Levels 3-4 are filled with the stock
  level-1/level-2 pair, reproducing what a TWO_LEVEL key does when a
  level-3 modifier is held. Both compiles are verified before any helper
  sees the file.
- `drive.py` — one leg: configures the helper with the keymap, checks
  `caps` for the glyphs on levels 5-8, launches and focuses the probe
  window, then runs the chord battery reading answers off the window
  title (or, for foot, off what `cat` flushed). Control key first; a leg
  whose control never lands records NO VERDICT instead of a finding.
- `probe-way.html` / `probe-x11.html` — the title recorder: every keydown
  appends `key·code` to `document.title`.
- `electron/main.js` — one BrowserWindow over the probe page; the
  wayland leg runs **this**, not chromium (below).
- `run.sh` — entry point, owned by the nested session:

```sh
scp -r tools/lvl5-probe omarchy-vm:~/
ssh omarchy-vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-1; cd ~/oskar && tools/nested-session.sh bash ~/lvl5-probe/run.sh'
```

The steps: control (`tap AB01` → `z`), negative (`tap I219`, a keycode
ticket 20 measured as dropped — must type nothing in Electron), levels
5/6/7/8 on AD01 (`down LVL5`, `+LFSH`, `+LVL3`, `+both` around the tap),
level 5 again on AD10 and AE01, then stock 1-4 sanity on AD01.

## Results

`result-wayland.txt`, Electron 43 `--ozone-platform=wayland` (three runs,
identical verdicts):

```
PASS  control z (AB01) — 'z·KeyZ'
PASS  negative: I219 — ''                      # not even a keydown fires
PASS  level 5  LVL5 + AD01 — '£·KeyQ'
PASS  level 6  Shift+LVL5 + AD01 — '¡·KeyQ'
PASS  level 7  LVL3+LVL5 + AD01 — 'á·KeyQ'
PASS  level 8  Shift+LVL3+LVL5 + AD01 — 'â·KeyQ'
PASS  level 5  LVL5 + AD10 — '≠·KeyP'
PASS  level 5  LVL5 + AE01 — '¤·Digit1'
PASS  stock 1-4 — q/Q/q/Q unchanged
```

`result-foot.txt` (discriminator: a terminal resolves keysyms itself),
12/12 — the compositor's Mod3 mask reaches a native client's xkb state
through the standard protocol. `electron-wayland-screenshot.png` shows the
rendered Electron window.

Chromium's X11 path passed every glyph step as well (`£·KeyQ`, `á·KeyQ`,
`â·KeyQ`, `≠·KeyP`, `¤·Digit1` — rounds 1-3), but that leg turned
environment-flaky later (empty title reads); XWayland delivery is already
gated by the product suite's x11cat leg, so it was not chased further.

## What the rig learned about the environment (do not rediscover)

- **Nested sessions over ssh now need `WAYLAND_DISPLAY=wayland-1`
  exported** or the nested Hyprland dies in `CBackend::create()` — libwayland's
  default is `wayland-0`, the live session publishes `wayland-1`, and an ssh
  shell has neither. Fixed in `tools/nested-session.sh`.
- **Plain Chromium 152 cannot run in the nested session at all**: fresh
  profile — no window inside 30s; warm profile — window maps, page JS runs,
  title updates, but no frame ever composites and every input event is
  rejected (`blink.mojom.WidgetHost`), under `--disable-gpu`,
  `--use-angle=swiftshader`, `--disable-gpu-compositing`, `--in-process-gpu`
  alike. The QEMU std VGA has no DRM driver and chromium's software paths
  do not recover. **Electron 43 renders and takes input fine** — use it as
  the native-Wayland consumer probe.
- `hyprctl dispatch focuswindow class:X` is refused by this Hyprland's Lua
  dispatch (`')' expected`); focus by waiting on `activewindow` instead.
- The old traps still apply (handoff 2026-09-09): control key in every leg,
  `kb_file` under `$HOME` never `/tmp` (`PrivateTmp=yes`), experiments in
  the nested session only — the live panel reconfigures its helper on any
  layout event.

## Design notes for the fix (measured facts only)

- Levels 5-8 deliver to Electron/Wayland, X11-path Chromium, and foot with
  the panel's own press shape (`down LVL5` / `down LVL3` / `down LFSH`
  around a tap). No `mods` hand-mask needed — the helper's per-group
  modifier probe already credits `<LVL5>` with Mod3, exactly as it does
  `<LVL3>` with Mod5.
- The `OSK8` type above preserves level 1-4 behavior of a TWO_LEVEL key by
  filling levels 3-4 with the stock pair (verified: `LVL3+AD01` still types
  `q`). For ALPHABETIC (letter) positions a CapsLock mapping would still be
  lost — the shipped type needs `map[Lock]` handling or the catalogue must
  sit on non-letter rows; the digits row is the natural first target.
- `I219` remains fully silent in Electron (no keydown at all) — the same
  rig re-proved the ticket-20 drop while proving itself sensitive.
