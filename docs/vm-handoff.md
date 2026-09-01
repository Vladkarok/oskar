# Dogfooding handoff — VM phase

State as of 2026-09-01, session end. Read this instead of re-deriving.

## Where things are

- Repo: `~/Projects/omarchy-osk`, branch `master`, all work committed
  (HEAD `0ebcde3`). Not pushed.
- Phases 0–1 done and review-hardened: 4 Codex rounds + parallel subagent
  audits, final verdicts "ship". Held-key ownership is claim-based
  (first-claim-down / last-release-up), device selection reads `main:true`
  (filtered) first and only advances devices with positive evidence.
- Polygon: `tools/nested-session.sh tools/smoke-daemon.sh` — green
  (group asserted before every tap, 3 compiles, ownership matrix).
  Never run the daemon on the working session.

## The VM

- `tools/omarchy-vm.sh` launches it (KVM, UEFI, qcow2 disk at
  `~/.local/share/omarchy-vm/`). Guest = Omarchy 4.0.2, user `vladkarok`,
  hostname `testprod`. SSH: `ssh omarchy-vm` (host port 2222, key
  `~/.ssh/id_ed25519`, already authorized in guest).
- Over SSH, export `XDG_RUNTIME_DIR=/run/user/$(id -u)` and
  `HYPRLAND_INSTANCE_SIGNATURE=$(ls $XDG_RUNTIME_DIR/hypr | head -1)`
  or hyprctl/journalctl won't reach the session.
- Guest is provisioned: rust/jq/rsync/openssh installed, plugin
  `io.github.vladkarok.osk` enabled, daemon built at
  `~/.local/libexec/omarchy-osk-daemon`, service **enabled and active**,
  `us,ua` + `grp:caps_toggle` applied to `~/.config/hypr/input.lua`
  (that config was the provision bug — fixed in `0ebcde3`).
- Device zoo in guest: 2× QEMU USB keyboards, power-button, PS/2, plus
  fcitx5 virtual keyboard holding `main:true` — faithful replica of host.
- Re-sync after host edits: rerun `tools/omarchy-vm-provision.sh` in the
  guest (needs the 9p mount; or rsync over ssh and rebuild).
- Networking is SLIRP: guest IP unreachable from host, only 2222→22.
- Boot shows a text LUKS prompt (installer encrypted the disk; cosmetic).

## What to test now (the actual dogfooding)

1. OSK panel in the guest: bar widget → open; click keys into foot/alacritty.
2. Caps Lock switch with OSK open: caps must flip to the other alphabet.
3. Language button on the OSK: must advance the physical device (bar
   indicator should agree), and refuse (grey) when no safe target.
4. XWayland target: type into an XWayland app (xterm via XWAYLAND).
5. Hotplug: QEMU monitor at `~/.local/share/omarchy-vm/monitor.sock` —
   `device_add usb-kbd,id=kbd2` / `device_del kbd2` while typing.
6. Sleep/wake if feasible; fcitx5 running vs not.

## Upstream queue (Phase 4, after dogfooding is clean)

- Hyprland discussion (not issue — they migrated): `switchxkblayout current`
  excluding virtual keyboards; event on seat keyboard change; seat-level
  layout concept. Prior art: Sway keyboard groups. Cite #6298, #6589,
  #8409, #15897 + omarchy #8964/#9129/#9552/#9565.
- wayland-protocols #209 comment; revive #296 with the OSK use case.
- Omarchy: bar widget `main:true` preference; share selection module with
  this plugin.

## Rules of engagement

- Codex review loop on every commit batch: full context brief (idea,
  problem, constraints), findings resolved, verdict recorded.
- Same brief to a parallel review subagent.
- Keep sessions short — context is re-billed every turn.
