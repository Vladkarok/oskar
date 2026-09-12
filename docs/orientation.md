# Orientation — read this first

Written 2026-09-02 for a fresh session. The code says *what* exists; this
says what we are building, [spec-v1.md](spec-v1.md) records the v1 baseline,
[spec-v1.1.md](spec-v1.1.md) is the authoritative current delta, and
[decisions.md](decisions.md) says *why* it looks the way it does.
[vm-handoff.md](vm-handoff.md) is the test lab.

## The idea

A mouse-driven on-screen keyboard for Omarchy (Arch + Hyprland +
Quickshell), modelled on the Windows touch keyboard: you open it, click
keys, and **what is drawn on the caps is what gets typed** — including
non-Latin layouts, including XWayland/Proton/Electron windows.

The part nobody on Linux does today is the layout coupling. On Windows
the on-screen keyboard and the physical keyboard share one input
language: change it once and it is changed everywhere. Here the system
layout is the single source of truth in both directions — switch with the
configured physical shortcut and the caps follow; switch from the panel and
the physical keyboard follows.

Owner's setup: `us,ua` with `compose:caps,grp:alt_shift_toggle`. It must
generalise to any number of layouts — two toggle, three or more should
get a small Windows-style chooser popup (not built yet).

`grp:caps_toggle` was the owner's setup between 2026-08-28 and
2026-09-03 and must not be recommended: it silently breaks layout
switching for every client behind fcitx5, which types the first layout
while the panel and the bar both correctly report the second. See
`.scratch/v1-keyboard/issues/16-layout-switch-misses-fcitx5-apps.md`.

## Where the pieces are

| piece | what it does |
|---|---|
| `Panel.qml`, `BarWidget.qml` | floating window + bar toggle |
| `Keyboard.qml` | key grid, layout tracking, socket client, keycap pipeline |
| `KeyboardLayout.js` | rows, keysym tables, xkb position mapping |
| `daemon/src/main.rs` | Rust helper owning one `zwp_virtual_keyboard_v1` |
| `systemd/omarchy-osk.service` | user unit, tied to `graphical-session.target` |
| `tools/` | nested-session polygon, daemon smoke, VM launcher + provision |

Panel talks to the helper over `$XDG_RUNTIME_DIR/omarchy-osk/control.sock`,
line protocol, version 5:

```
hello 5                                   -> hello 5 | err not ready | err protocol …
keyboards                                 -> keyboards\t<safe physical name>…
configure\t<rules>\t<model>\t<layouts>\t<variants>\t<options>\t<kb_file>\t<group>
caps <group> [positions…]                 -> keycap facts for the named group
group <n> | tap <AD01|code> | down … | up … | mods <mask> | ping
text <utf8>                               -> text-ok | text-err … (a transient keymap swap; decisions §39)
text-unicode <utf8>                       -> text-ok | text-err … (Chromium Unicode entry; decisions §40)
```

Replies are `ok`, `text-ok`, `text-err …`, `configured\t<generation>`,
`caps\t<generation>\t<group>\t<records>`, `pong`, or `err …`. Version 4's
generation (decisions §23) is what the panel correlates keycap facts against;
a same-keymap reconfigure keeps it, a changed keymap bumps it. Everything
else about the protocol lives in `parse()`/`apply_locked()` in
`daemon/src/main.rs`.

## State as of 2026-09-02

- `master` at `42017b2`, clean, pushed to the private
  [Vladkarok/omarchy-osk](https://github.com/Vladkarok/omarchy-osk).
- Phases 0–1 (design, hardening) done through seven Codex review rounds
  plus parallel subagent audits; last verdict "ship".
- Phase 2 dogfooding in the Omarchy VM: typing precision verified by
  screenshot, layout mirroring both directions with zero keymap churn,
  USB hotplug survival, cold-boot self-recovery, both socket-recovery
  directions. The VM is healthy and installed with the current build.
- Host machine: plugin installed and hot-reloading. The development service
  may still be disabled; v1.1 requires installer and development provisioning
  to enable it for graphical-session autostart.

Not done: daily use on a real session, sleep/wake on real hardware (the
VM cannot suspend, see decisions), the 3+ language popup, long-press
accented characters, the context row (`.com` and friends), and the
upstream Hyprland/Omarchy work.

## How we work (standing directives from the owner)

- **Agent execution and reviews:** follow [agents/workflow.md](agents/workflow.md)
  (Astra orchestrates, Sol implements and independently reviews).
- **Local-first.** Build it, install it, use it, prove it in the VM.
  Temporary local patches rather than waiting on upstream merges.
  Upstream PRs only after local proof, and never at the cost of breaking
  what already works.
- **Own implementation.** The first panel sketch grew out of
  abdxdev/omarchy-onscreen-keyboard; every substantive line has since been
  replaced by our own, `tools/provenance.py` measures zero shared lines
  against the upstream snapshot, and the licence is a sole copyright
  (spec-v1.md §13 keeps the history).
- **Never run the helper against the session you are working in** — see
  the keymap storm in decisions.md. Run `tools/nested-session.sh` inside the VM; host suites are offscreen.
- Ask when uncertain rather than guessing; discuss conflicts item by item.
- Keep sessions short; context is re-billed every turn.

## Suggested next steps

For the consolidated 2026-09-11 release roadmap, current evidence and outstanding
decisions, read [release-readiness-plan.md](release-readiness-plan.md).

Continuing a session starts at [session-handoff.md](session-handoff.md): what
is done, what is next, and the traps this project has already paid for. For
the 2026-09-06 review that produced the current board, read
[next-iteration-plan.md](next-iteration-plan.md) — it indexes the draft
`.scratch/next-iteration/` board and is not an implementation instruction.
The board itself is worked with `/board`, one ticket at a time.

1. Implement the local v1.1 board derived from [spec-v1.1.md](spec-v1.1.md).
2. Land the shared Omarchy Style refresh needed for live rounding updates.
3. Daily use, then sleep/wake on real hardware.
4. Features: 3+ language popup, long-press accents, context row.
