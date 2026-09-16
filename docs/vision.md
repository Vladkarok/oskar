# Vision — what this keyboard is for

**Owner's words (2026-09-14), kept as the anchor:**

> Цель — сделать экранную клавиатуру для Linux-десктопа, чтоб она была
> красивая, функциональная, приятная, быстрая, удобная — чтоб,
> допустим, разработчики KDE или GNOME посмотрели на неё, выкинули
> свои клавиатуры и советовали пользователям: «вот установите
> клавиатуру владкарока, и будет вам счастье».

This document is the goal and the strategy conversation around it.
(Paths under `.scratch/` name the maintainers' local board and
evidence — deliberately not part of the shipped tree.)
It is not a spec; specs and decisions live where they live
(docs/spec-v1.1.md, docs/decisions.md).

## What exists today (the honest inventory)

A WORKING product on Omarchy (Hyprland + Quickshell), daily-driven by
its owner — a mouse-driven on-screen keyboard whose core promise is
**drawn-is-typed**: every cap draws what the seat's real compiled
keymap carries, and typing goes through the same keymap via a Rust
helper owning `zwp_virtual_keyboard_v1`.

- Rust core (daemon): keymap compilation/mirroring incl. the reserved
  symbol block (§33), the `text` transient-swap path (§39), clipboard
  transactions for XWayland/wine/Proton/Chromium (§44), group
  discipline, recovery choreography. ~5k LOC, 45 tests, VM lab legs.
- QML/Quickshell panel (the Omarchy frontend): layout-following caps,
  emoji picker with EN/RU/UK search, hold-column menus from the live
  keymap (§51), the three-shape language control (§49), themes,
  settings, docked/floating, settle guard (§53). ~17k LOC QML+JS,
  13 offscreen suites (377 cases), the regression wall, provenance gate.
- The architecture is ALREADY two-tier: the Rust daemon IS the
  backend-magic (everything compositor/protocol/keymap), the panel IS
  a frontend speaking a versioned line protocol over a unix socket.
  The seam exists and is tested; today it has exactly one frontend.

## The strategic question

The owner's ambition implies users beyond Omarchy (a niche distro).
The known tension: every existing OSK is welded to one shell
(GNOME's to mutter/clutter, plasma-keyboard to KWin's input-method,
wvkbd to touch-first Phosh). None is a cross-shell product. The gap is
real; so is the cost of N frontends. Options on the table:

- **A. Deepen Omarchy-first** (current course): be the best keyboard
  for one ecosystem; expansion is someone else's fork.
- **B. Rust core + N thin frontends**: keep the daemon, write
  frontends per shell (Quickshell now; a GTK4 layer-shell app for
  GNOME-adjacent; a Plasma/QML applet for KDE; X11 via its own
  leg or not at all).
- **C. One self-contained Rust binary** (slint/egui + wlr-layer-shell
  directly): no shell dependency on Wayland at all, tiny, fast,
  themable; X11 as a stretch. One product, every Wayland compositor.

Open sub-questions: theme-following per desktop, distribution
(one binary vs per-distro packages), IME cooperation vs coexistence,
accessibility/touch, and the marketing reality of "KDE devs
recommending it" (they ship their own).

## The council (Codex + Claude, consulted 2026-09-14)

Round 1 — independent answers; round 2 — each shown the other's
verdict for rebuttal; synthesis below. Full transcripts:
`.scratch/next-iteration/evidence/vision-council/`.

### The orchestrator's position (GLM-5.3, third voice, written before
reading Codex; Claude's round 1 is in hand)

I carry what neither consultant has: eight months of this repo's scar
tissue. Two fact-corrections that reshape the debate, then my verdict.

**Correction 1 — GNOME is out at the PROTOCOL level, not the political
one.** Mutter does not implement zwp_virtual_keyboard_v1 (GNOME/mutter
issue #4124, open for years; wtype is broken on GNOME Wayland through
Shell 48; ydotool's uinput+root workaround is the only path). Our
daemon cannot exist on mutter. Any "GTK4 frontend for GNOME" plan —
including Claude's month-2 milestone — is technically impossible
without a root daemon, which is a different product with a different
trust model. The real cross-shell frontier where the protocol EXISTS:
the wlroots family (sway, wayfire, river…) and KWin.

**Correction 2 — the differentiator is compositor-coupled in the
frontend, not the daemon.** The magic Claude wants to reuse (exact
seat-keymap mirroring, group discipline) is read today through
hyprctl in the PANEL: devices inventory, activelayout events,
switchxkblayout moves. A second frontend does not just "speak the
socket protocol" — it needs the same seat reading, which on sway is
swaymsg IPC and on KWin is neither. The honest B-work is abstracting
a seat-reader/seat-writer seam into the daemon (per-compositor
backends), and THAT is the portability project nobody has priced.
Also: Quickshell itself is Hyprland-first; its sway support is
partial — verify in a VM before betting the cheapest-frontend path
on it.

**My verdicts.** Q1: retarget — agree with Claude; north star "the
correctness on-screen keyboard for the wlroots Wayland world", with
the KDE-dev fantasy retired. Q2: B, but sequenced B0→B1: first make
the CURRENT frontend compositor-honest (move seat reading behind the
daemon seam; strip Omarchy coupling where cheap), then a sway proof
of life in a nested-sway VM (Quickshell if it holds, else
gtk4-layer-shell). KDE later — the protocol exists but KWin ships its
own keyboard and an applet is the trap Claude named. GNOME:
documented as protocol-unsupported (link the mutter issue in the
README); a uinput mode is an explicit non-goal (root). Q3: Claude's
five, plus UI-string localization (our audit's own item 3 — the
multilingual niche is our audience and the UI is English-only). Q4:
his three months, with month 2 replaced by the seat-reader seam +
sway proof; falsification metric agreed, with one addition — the
signal that matters most is an unsolicited issue in a non-Latin
layout.

## The recommendation (the synthesis — three strategists, unanimous)

Council: GPT-5.6 (Codex), Claude Opus 5, GLM-5.3 (the orchestrator).
Two rounds; full transcripts in
`.scratch/next-iteration/evidence/vision-council/`. Round 2 was
unanimous on every disputed axis.

**The honest verdict on the owner's dream.** "KDE/GNOME developers
throw away their keyboards and recommend yours" is fantasy — they own
privileged input stacks and ship their own (Opus: "'fine' beats
'better' there"; Codex: they will always favor first-party). It is NOT
"go watch YouTube": the problem is real, unserved, and the
drawn-is-typed + XWayland/wine delivery engineering is genuinely
unmatched. But the process-to-users ratio is upside down (1,725 lines
of decisions, 45 tickets, zero outside users — Opus's blunt reading):
the next unit of value is a stranger installing it, not ticket 46.
The REACHABLE version of the dream, unanimously: **the Quickshell
shell maintainers (DankMaterialShell, Noctalia, Caelestia, end-4) and
Omarchy ship or recommend it** — they live exactly where our frontend
already rides. Honest first-year ceiling: 50-300 users Omarchy-only;
500-3,000 with wlroots reach; 10,000 would be a breakout.

**Architecture — "A+" (unanimous, kills A/B/C as written).**
Compositor seat-backends INSIDE the Rust daemon (today's hyprctl
reading moves from the panel: device inventory, activelayout,
switchxkblayout; then a niri IPC backend; a degraded generic mode
keying off wl_keyboard.keymap with manual group pick) + ONE
Quickshell/QML frontend, forever. The unix-socket seam stays versioned
and documented — as a TEST seam and a door for an outside maintainer
to build their own frontend someday; we never build a second one.
Killed: C (a Slint/egui rewrite cannot make Mutter or KWin grant
protocols; it discards 377 tested cases and re-solves placement),
plain A (welded to Omarchy's slice), B's N-frontends (every feature
costs N times, solo). GNOME: protocol-impossible (mutter lacks
zwp_virtual_keyboard_v1; uinput/libei are root/permission traps) —
documented as unsupported, with the mutter issue linked. X11:
permanent no (Onboard's revived fork owns it). KWin: technically open,
strategically closed (plasma-keyboard enters via input-method; we do
not fight for that single slot).

**Product target order (after the gate): niri, then touch, then
depth.** niri-first because the Quickshell shells our frontend rides
live there and its crowd is the fastest-growing in exactly our
demographic; nested-sway stays as the CI/test seat, not a product
target (Codex's concession accepted, product claim conceded to the
majority). Touch is a PASS, not a redesign, in the first year:
nothing that requires hover, hold-that-works-under-a-finger, a size
slider — explicitly NOT swipe typing or prediction (Sonnet's scope,
kept).

**The functional gaps (consolidated, in order):**
1. Install from zero — doctor command, clean-VM README pass, AUR,
   90-second demo video, compatibility matrix with the honest
   "GNOME/X11: no, and here is why" section.
2. Accessibility that is TESTED, not claimed — dwell-to-type (the
   first thing onboard refugees ask for), sticky/slow/repeat controls,
   scale slider, high-contrast, AT-SPI/Orca validation with real
   disabled users. This is the actual underserved market.
3. IME coexistence contract — fcitx5/ibus matrix across native
   Wayland/XWayland/Chromium/Wine; never compete for the seat's one
   input-method slot.
4. UI localization — EN/RU/UK strings (the multilingual niche is our
   audience and the UI is English-only), RTL proof locale.
5. The seat-backend seam itself (the portability work nobody had
   priced: the reading layer, not the drawing layer).
6. Touch pass (as scoped above).

**The traps (unanimous):** prediction, autocorrect, swipe, handwriting,
voice, becoming an input-method, layout editor, theme marketplace,
X11, GNOME-via-uinput/libei, a second frontend, a Slint/egui rewrite.

**The gate (unanimous shape).** After a public v1.0 announcement:
actively recruit ~20 target users (r/omarchy, r/hyprland, the Omarchy
and Quickshell Discords — passive waiting proves nothing). At day 30
(week 6 at the latest): **≥5 distinct strangers who installed it AND
reported back (issue/message/AUR comment — stars and votes do not
count) and are still using it after a week** → fund portability (the
seat-backend seam, niri, touch). Below that → portability is
cancelled for good: it stays an excellent Omarchy-first tool in
maintenance mode, and new decision records stop.

**The owner's first move (unanimous):** boot a fresh Omarchy VM
WITHOUT the owner's dotfiles and try to install and run the keyboard
using only the README. File every failure as the next ticket —
"install from zero". Nothing else starts until a stranger could get
through that.

*(The council's Monday move implies the public release is NOT far —
it is the next unit of value. The owner currently defers the release;
this document records the council's recommendation. The owner
decides.)*
