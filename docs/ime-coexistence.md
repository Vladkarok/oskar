# IME coexistence — the measured matrix (ticket 51)

Measured 2026-09-14 in the lab guest (testprod, Hyprland 0.56.2,
Quickshell 0.3.1, qt6-base 6.11.2, 1280x800) against host HEAD `61931ac`
(`~/omarchy-osk` synced + built; the hosted real `Panel.qml` through the
ticket-48 frame technique with `emoji_delivery: clipboard` pre-armed,
because the packaged panel is 0.1.0-2, pre-dwell-era, and the lab's
config file must exist at panel boot to be read). fcitx5 5.1.22 with
`fcitx5-chinese-addons` (pinyin) added to the default group
(`omarchy-fcitx5.service`, Omarchy's own XCompose vehicle — the seat's
pre-existing state, kept). Pointer: QMP absolute events; observation:
kitty `--debug-input` key log + capture files, x11cat's keysym log,
chromium's `document.title` mirror, grim screenshots, the daemon
protocol under `strace -tt`, `hyprctl devices`, `fcitx5-remote`.
Evidence: `.scratch/next-iteration/evidence/51/` (matrix-run*.txt,
screenshots).

## The two seat-level questions first

**Does fcitx5 grab the seat's input-method slot and starve our vkb?**
No. fcitx5 does hold the compositor's input-method registration
(`fcitx5-diagnose`: "Group [wayland:] has 3 InputContext(s)", kitty
`frontend:wayland_v2 focus:1`, chromium and one anonymous IC) — and
every OSK path still works. Our daemon's uinput keystrokes are delivered
as real key events to the focused client; the IM only consumes them when
an input method is ACTIVE, and then only the keys its engine wants (see
the matrix): ASCII letters feeding pinyin's composition, and the Ctrl
paste chord, are swallowed; the Cyrillic й and the Level3 § chord pass
through literally. Our vkb was never starved, expelled or demoted: at
rest it holds `main:true` and `input:kb_file` stays our published
`keymap.xkb` across every phase.

**Does our keymap share disturb fcitx?** No. Language switches (the
chip's own primitive, `switchToGroup`) re-share the keymap under a
running, active, and stopped fcitx5 alike; `fcitx5-remote` stays
responsive and the active IM survives the switch. One measured,
benign interaction: a group switch makes fcitx5 (re)create its
`hl-virtual-keyboard-fcitx5` in the seat (it re-initialises on keymap
changes; the device also appears/vanishes across service stops). It
never takes `main` from our device and no OSK path regressed.

## The matrix

Verdicts per cell: PASS / BROKEN / REFUSED (the combination cannot
exist in that venue). "I" = fcitx5 running, IM inactive (the lab's — and
the host's — normal state); "A" = pinyin ACTIVE (`fcitx5-remote -s
pinyin`, state 2); "S" = `omarchy-fcitx5.service` stopped.

| Venue × action | I (running, inactive) | A (pinyin active) | S (stopped) |
|---|---|---|---|
| kitty — OSK keystroke | **PASS** — 'q' in capture, one protocol down | **PASS** (as composition) — 'q' enters fcitx's preedit, never a literal key event in kitty's log; by IME design the committed candidate arrives via the IM's commit | **PASS** — 'q' |
| x11cat (XWayland) — OSK keystroke | **PASS** — 'q' keysym+text | **REFUSED** — the venue has no IM integration (bare GTK X11 client, no XIM env): activation impossible | PASS* — 'q' (measured under I/S conditions; X11 path unaffected by fcitx5's state) |
| chromium — OSK keystroke | **PASS** — 'q' in the title mirror | **PASS** — 'q' literal (chromium's text-input context passes it through) | **PASS** — 'q' |
| wine notepad — OSK keystroke | **PASS** — protocol down + screenshot | **REFUSED** — no IM module in notepad | PASS* — as I |
| kitty — emoji clipboard path | **BROKEN** — clipboard publishes '🥰' ✓, but the chord reached kitty as bare Ctrl+V (no Shift; the panel's own log carries no `paste chord for kitty` line) and kitty does not paste on Ctrl+V. Target-class resolution at pick mis-named the window (wine-shaped chord) — a known recorded residual shape (ticket 25 review, ≤500 ms window); filed, not fixed here | **BROKEN** — publish ✓, chord swallowed whole by the IM grab (no key events reach kitty at all) | n/m (as I) |
| x11cat — emoji clipboard path | **PASS** (by proxy) — publish ✓, chord dispatched; the venue itself cannot display pasted text (a GTK X11 client's translation layer drops chord text — it is a keysym-only observer) | REFUSED (no IM integration) | n/m |
| chromium — emoji clipboard path | **PASS** — '🥰' pasted via Shift+INS, title mirror | not measured (activation was established last; one cell left for a rerun) | n/m |
| wine — emoji clipboard path | **PASS** — '🥰' via the paced Ctrl+AB04 wine chord; screenshot | REFUSED (no IM module) | n/m |
| language switch (chip primitive) | **PASS** — panel group→1, `qemu-qemu-usb-keyboard` layout idx 0→1, CAP_Q typed й, kb_file still ours | **PASS** — same, and `fcitx5-remote` stays 2 through the switch; й lands literally even under the active IM | **PASS** — same |
| hold-column chord (menu §) | **PASS** ×4 — kitty/x11cat/chromium capture '§', wine screenshot: hold 450 ms opens the column menu, the level-3 entry pick sends the exact `ISO_Level3_Shift`+3 chord (ticket 37's own verdict reproduced) | **PASS** — kitty: '§' literal through the active IM | n/m |

\* measured once per state where the venue supports it; the X11 and wine
paths showed zero dependence on fcitx5's state.

## What the measurement forces (all doc-level; no product code changed)

1. **The non-goal stands, now with evidence.** Becoming an input method
   (input-method-v2) would buy nothing for coexistence: with fcitx5
   holding the slot, every OSK path except IM-composition keys already
   reaches clients. We stay a virtual keyboard.
2. **Graceful-refusal rule adopted (documented, not coded): under an
   ACTIVE composition IM, the clipboard paste chord cannot reach the
   app** — the IM grab consumes it. The chord remains correct for the
   IM-off state that is the feature's contract (the owner's Chromium
   use case); if an IM-aware delivery is ever wanted, that is new
   ticket work, not a silent swap.
3. **Filed, not fixed: the kitty pick's chord came out wine-shaped**
   (Ctrl+V, no Shift, no `paste chord for kitty` log line) while
   chromium and wine picked correctly minutes later — the pick's target
   resolution at arrival, the exact residual ticket 25's review named.
   A rerun with a focused re-measure is wanted before calling it
   product-vs-harness.

## Venue and lab facts paid for on the way

- fcitx5 rewrites `~/.config/fcitx5/profile` on stop/start and once
  dropped the pinyin entry after a racing duplicate start ("another
  fcitx already running" in the unit journal); a clean stop-kill-start
  with the profile re-applied gives a working `pinyin` (state 2 via
  `fcitx5-remote -s pinyin`). Ctrl+Space did NOT toggle in this lab
  (HMP `sendkey ctrl+spc` reaches the guest; the grab never activated
  it) — programmatic `-s` is the reliable lab lever.
- The emoji page grows the panel window upward (~y 60); the first
  catalogue cell sits at ≈(481,300) on this 1280x800 medium preset.
  The bottom command row is `[Ctrl][Fn][Super][Alt][☺][Space]…` — the
  emoji cap is the FIFTH slot (x 426–479); a misclick on the Super cap
  latches Super and poisoned an early run (and crashed one kitty
  `--debug-input` instance mid-torture — venue artifact, not product).
- The hold menu for a row-0 cap opens BELOW the cap (a row-0 hold has
  no room above): entries at ≈(450,625), a vertical column — the menu
  swallows clicks on the caps it covers (ticket 37's own behavior).
- fcitx5's virtual keyboard holds `main:true` when it is the last
  keyboard to touch the seat; our daemon's device takes `main` back on
  its next configure. Nothing measured depends on the flag.

## fcitx5's state after this run (deliberate)

fcitx5, fcitx5-gtk/qt and fcitx5-chinese-addons stay installed;
`omarchy-fcitx5.service` active with the default group
[keyboard-us, pinyin] (DefaultIM keyboard-us — the as-found default);
the OSK service and daemon restored; the venue clients and the hosted
panel are gone. ibus was not installed — the fcitx5 half already
answers the council's question, and one session should not flip
session-wide IM env between two frameworks.
