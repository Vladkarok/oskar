# Orientation — read this first

Written 2026-09-02 for a fresh session. The code says *what* exists; this
says what we are building, [spec-v1.md](spec-v1.md) says what v1 must do,
and [decisions.md](decisions.md) says *why* it looks the way it does.
[vm-handoff.md](vm-handoff.md) is the test lab.

## The idea

A mouse-driven on-screen keyboard for Omarchy (Arch + Hyprland +
Quickshell), modelled on the Windows touch keyboard: you open it, click
keys, and **what is drawn on the caps is what gets typed** — including
non-Latin layouts, including XWayland/Proton/Electron windows.

The part nobody on Linux does today is the layout coupling. On Windows
the on-screen keyboard and the physical keyboard share one input
language: change it once and it is changed everywhere. Here the system
layout is the single source of truth in both directions — switch with
Caps Lock and the caps follow; switch from the panel and the physical
keyboard follows.

Owner's setup: `us,ua` with `grp:caps_toggle`. It must generalise to any
number of layouts — two toggle, three or more should get a small
Windows-style chooser popup (not built yet).

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
line protocol, version 2:

```
hello 2                                   -> hello 2 | err not ready | err protocol …
configure\t<rules>\t<model>\t<layouts>\t<variants>\t<options>\t<kb_file>\t<group>
group <n> | tap <AD01|code> | down … | up … | mods <mask> | ping
```

Replies are `ok`, `configured`, `pong`, or `err …`. Everything else about
the protocol lives in `parse()`/`apply_locked()` in `daemon/src/main.rs`.

## State as of 2026-09-02

- `master` at `42017b2`, clean, pushed to the private
  [Vladkarok/omarchy-osk](https://github.com/Vladkarok/omarchy-osk).
- Phases 0–1 (design, hardening) done through seven Codex review rounds
  plus parallel subagent audits; last verdict "ship".
- Phase 2 dogfooding in the Omarchy VM: typing precision verified by
  screenshot, layout mirroring both directions with zero keymap churn,
  USB hotplug survival, cold-boot self-recovery, both socket-recovery
  directions. The VM is healthy and installed with the current build.
- Host machine: plugin installed and hot-reloading, **service still
  `disabled`** — deliberate, it does not go in autostart until it has
  survived daily use.

Not done: daily use on a real session, sleep/wake on real hardware (the
VM cannot suspend, see decisions), the 3+ language popup, long-press
accented characters, the context row (`.com` and friends), and the
upstream Hyprland/Omarchy work.

## How we work (standing directives from the owner)

- **Codex reviews before anything is called done.** Send a full context
  brief — the idea, the problem, the constraints, *why* the change was
  made — not just the diff. Codex reviews, we implement. Run a parallel
  review subagent on the same brief. Resolve the findings, record the
  verdict, repeat rounds until it says ship. This loop has caught real
  HIGH bugs in our own fixes every time; two of the last three rounds
  said "do not ship".
- **Local-first.** Build it, install it, use it, prove it in the VM.
  Temporary local patches rather than waiting on upstream merges.
  Upstream PRs only after local proof, and never at the cost of breaking
  what already works.
- **Own implementation.** The scaffold came from
  abdxdev/omarchy-onscreen-keyboard (MIT, both copyright lines kept) and
  our fixes were merged upstream. The daemon, `systemd/` and `tools/`
  share nothing with it; the QML still does, and is being reimplemented
  against [spec-v1.md](spec-v1.md#13-provenance) until it does not.
- **Never run the helper against the session you are working in** — see
  the keymap storm in decisions.md. Use `tools/nested-session.sh` or the VM.
- Ask when uncertain rather than guessing; discuss conflicts item by item.
- Keep sessions short; context is re-billed every turn.

## Suggested next steps

1. Daily use in the VM, then a supervised stretch on the real session.
2. Sleep/wake on real hardware (layout state after resume).
3. Features: 3+ language popup, long-press accents, context row.
4. Upstream queue in [vm-handoff.md](vm-handoff.md#upstream-queue).
