# The VM — dogfooding lab

Updated 2026-09-02. Why the VM exists and what it cannot do is in
[decisions.md §12](decisions.md#12-testing-ladder-and-what-each-rung-cannot-see);
this is the operating manual.

## Repo state

- `~/Projects/omarchy-osk`, `master` at `42017b2`, clean, pushed to the
  private `Vladkarok/omarchy-osk`.
- Polygon green: `tools/nested-session.sh tools/smoke-daemon.sh`.
- Host: plugin installed and hot-reloading; user service **disabled** on
  purpose until daily use proves it.

## Driving the VM

- `tools/omarchy-vm.sh` launches it — KVM, UEFI, qcow2 disk under
  `~/.local/share/omarchy-vm/`. First run boots the ISO for the
  interactive install; later runs boot the disk.
- The same guest is also defined in libvirt as domain `omarchy-osk` on
  the **user session** connection, so it can be started from
  virt-manager. Add the connection once with File → Add Connection →
  QEMU/KVM user session; it appears beside the system connection that
  holds `win11`. The domain lives at
  `~/.local/share/omarchy-vm/omarchy-osk.xml`; redefine after editing
  with `virsh -c qemu:///session define ~/.local/share/omarchy-vm/omarchy-osk.xml`.
  It is the system connection that cannot host this VM: QEMU there runs
  as `libvirt-qemu`, which cannot traverse `$HOME`.
- **One at a time.** The script and the libvirt domain open the same
  qcow2; running both at once corrupts it.
- Differences under libvirt: the display is SPICE rather than a QEMU GTK
  window (virt-manager opens it), and libvirt owns the QEMU monitor, so
  hotplug goes through
  `virsh -c qemu:///session qemu-monitor-command --hmp omarchy-osk 'device_add usb-kbd,id=kbd2'`
  instead of `monitor.sock`. Everything else — 6 vCPU, 8G, the input
  zoo, the read-only 9p mount of the repo at `osk-src`, ssh on 2222 — is
  the same, including S3 being requested.
- Guest: Omarchy 4.0.2, user `vladkarok`, hostname `testprod`.
  `ssh omarchy-vm` (host port 2222 → guest 22, key `~/.ssh/id_ed25519`,
  already authorised). Networking is SLIRP: only the forwarded port
  reaches the guest.
- **Every SSH command that touches the session needs the environment**,
  or hyprctl/journalctl will not find it:

```bash
ssh omarchy-vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u); export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1); export WAYLAND_DISPLAY=wayland-1; hyprctl devices -j | jq -c ".keyboards[] | {name, main, active_layout_index}"'
```

- QEMU monitor socket: `~/.local/share/omarchy-vm/monitor.sock` — used
  for hotplug (`device_add usb-kbd,id=kbd2` / `device_del kbd2`).
- Screenshots: `grim` in the guest (needs `WAYLAND_DISPLAY`), then `scp`
  back. Screenshot evidence beats log lines for anything about
  characters on screen.
- Re-sync after host edits: `scp` the QML (the plugin hot-reloads on
  save) or rerun `tools/omarchy-vm-provision.sh` in the guest for a full
  rebuild — it needs the 9p mount and restarts the service.
- The integration suite in the guest, against the daemon the guest built:

```bash
bash /mnt/osk-src/tools/omarchy-vm-provision.sh   # syncs ~/osk-src, builds
cd ~/osk-src && tools/nested-session.sh tools/smoke-daemon.sh
```

  Run it from `~/osk-src`, not from `/mnt/osk-src`: the script finds the
  daemon relative to the repo root, and the 9p share is the host's tree,
  read-only and carrying the host's build output if any.
- Input zoo in the guest, deliberately messy: PS/2 keyboard, two USB
  keyboards, a USB tablet, a power-button pseudo-device, plus fcitx5's
  virtual keyboard holding `main:true` — a faithful replica of the host.
- S3 is requested (`-global ICH9-LPC.disable_s3=0`) but QEMU+OVMF still
  refuses to suspend. Sleep/wake testing belongs on real hardware.

## Verified in the VM so far

- Typing precision, screenshot-verified: 3 taps → exactly `qqq`;
  group 1 → `ййй`.
- Layout mirror both directions, hands-off: `hyprctl switchxkblayout`
  on the physical keyboard, no explicit `group` command, correct
  alphabet typed.
- Zero keymap churn: the daemon compiles twice ever (startup default +
  the panel's `configure`); hotplugging a keyboard adds none.
- Socket recovery both ways: daemon started under a running panel →
  configure in 2 s; daemon killed mid-flight → re-configure in 2 s;
  cold boot → panel configured 1 s after the daemon.
- Keycap pipeline green after `8c8546c` (Ukrainian symbols collected).

## Still to do here

1. Actual daily use — open the panel, click keys, work in it for a while.
2. Language button on the panel: must advance the physical device (the
   bar indicator should agree) and grey out when there is no safe target.
3. XWayland target: type into an XWayland window (xterm under XWAYLAND).
4. fcitx5 running vs stopped, both ways.
5. Longer hotplug storms while typing.

## Upstream queue

Phase 4, after dogfooding is clean:

- Hyprland **discussion** (they migrated off issues): `switchxkblayout
  current` excluding virtual keyboards; an event when the seat's current
  keyboard changes; a seat-level layout concept. Prior art: Sway
  keyboard groups. Cite #6298, #6589, #8409, #15897 and omarchy
  #8964 / #9129 / #9552 / #9565.
- wayland-protocols: comment on #209, revive #296 with the OSK use case.
- Omarchy: bar widget should prefer `main:true`; share the device
  selection module with this plugin.
