# The VM — dogfooding lab

Updated 2026-09-17 (the ticket-59 rename round; see the as-found note at
the end). Why the VM exists and what it cannot do is in
[decisions.md §12](decisions.md#12-testing-ladder-and-what-each-rung-cannot-see);
this is the operating manual.

## Repo state

- Historical snapshot (2026-09-02, names pre-rename): host checkout under
  `~/Projects/`, polygon green, plugin hot-reloading. The 2026-09-17
  state: work happens in worktrees off `spec/v1.1-fixes`; the guest's
  tree is `~/oskar` (rsync'd, not a clone); the lab runs the packaged
  product (see the as-found note).
- Polygon green: `tools/nested-session.sh tools/smoke-daemon.sh`.
- Host: plugin installed and hot-reloading; user service **disabled** on
  purpose until daily use proves it.

## Driving the VM

- `tools/omarchy-vm.sh` launches it — KVM, UEFI, qcow2 disk under
  `~/.local/share/omarchy-vm/`. First run boots the ISO for the
  interactive install; later runs boot the disk.
- The same guest is also defined in libvirt as domain `oskar` (renamed
  from the pre-rename `omarchy-osk` with `virsh -c qemu:///session
  domrename` on 2026-09-17; the xml copy moved with it) on the
  **user session** connection, so it can be started from
  virt-manager. Add the connection once with File → Add Connection →
  QEMU/KVM user session; it appears beside the system connection that
  holds `win11`. The domain xml copy lives at
  `~/.local/share/omarchy-vm/oskar.xml`; redefine after editing
  with `virsh -c qemu:///session define ~/.local/share/omarchy-vm/oskar.xml`.
  It is the system connection that cannot host this VM: QEMU there runs
  as `libvirt-qemu`, which cannot traverse `$HOME`.
- **One at a time.** The script and the libvirt domain open the same
  qcow2; running both at once corrupts it.
- Differences under libvirt: the display is SPICE rather than a QEMU GTK
  window (virt-manager opens it), and libvirt owns the QEMU monitor, so
  hotplug goes through
  `virsh -c qemu:///session qemu-monitor-command --hmp oskar 'device_add usb-kbd,id=kbd2'`
  instead of `monitor.sock`. Everything else — 6 vCPU, 8G, the input
  zoo, the read-only 9p mount of the repo at `osk-src`, ssh on 2222 — is
  the same, including S3 being requested.
- Guest: Omarchy 4.0.2, user `vladkarok`, hostname `testprod`.
  `ssh omarchy-vm` (host port 2222 → guest 22, key `~/.ssh/id_ed25519`,
  already authorised). Networking is SLIRP: only the forwarded port
  reaches the guest. The guest's throwaway sudo password (a venue
  repair set it to `z`; change it and this note together) feeds the
  QMP legs' strace oracle via `OSK_LAB_SUDO_PASSWORD` on the host —
  never a literal in the tree.
- **Every SSH command that touches the session needs the environment**,
  or hyprctl/journalctl will not find it:

```bash
ssh omarchy-vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u); export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1); export WAYLAND_DISPLAY=wayland-1; hyprctl devices -j | jq -c ".keyboards[] | {name, main, active_layout_index}"'
```

- **Autologin is a deliberate lab setting.** After a logout the SDDM
  greeter used to strand the VM (autologin fired only at sddm startup,
  and the session password is not automatable) — so
  `/etc/sddm.conf.d/zz-osk-lab-autologin.conf` now sets
  `[Autologin] User=vladkarok, Session=hyprland-uwsm.desktop,
  Relogin=true`: every sddm start AND every logout autologs straight
  into the uwsm-wrapped Hyprland session. `hyprland-uwsm.desktop` is
  the one to name — plain `hyprland.desktop` bypasses uwsm, which
  leaves graphical-session.target (and the OSK service with it) down.
  Revert by deleting that file (the pre-existing
  `autologin.conf` boot autologin remains). Written 2026-09-05 by the
  v1.1-fixes guest sweep.
- QEMU monitor socket: `~/.local/share/omarchy-vm/monitor.sock` — used
  for hotplug (`device_add usb-kbd,id=kbd2` / `device_del kbd2`).
- Screenshots: `grim` in the guest (needs `WAYLAND_DISPLAY`), then `scp`
  back. Screenshot evidence beats log lines for anything about
  characters on screen.
- Getting the source into the guest — a clone is the plain way, and the
  provision script builds whichever copy it was run from:

```bash
git clone https://github.com/vladkarok/oskar   # then: git pull
bash oskar/tools/omarchy-vm-provision.sh
```

- The 9p share is the other way, and the only one that can test **work
  that is not pushed yet**: it is the host's working tree as it stands.
  A guest with no clone and no mount has to be bootstrapped at the
  console, because the share is what carries the repo in and the script
  is what turns sshd on:

```bash
sudo mkdir -p /mnt/osk-src
sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 osk-src /mnt/osk-src
bash /mnt/osk-src/tools/omarchy-vm-provision.sh
```

  That run writes an `/etc/fstab` entry, so from the next boot the mount
  is just there. Run from the share, the script rsyncs to `~/osk-src`
  and builds there — 9p is far too slow for a cargo target dir.
- Re-sync after changes: `scp` the QML (the plugin hot-reloads on save),
  or `git pull` and rerun the provision script for a full rebuild — it
  restarts the service. From the host, needing nothing on the guest:

```bash
ssh -tt omarchy-vm 'bash -s' < tools/omarchy-vm-provision.sh
```

  Piped in it has no path of its own, so it falls back to the share.
- The integration suite in the guest, against the daemon the guest built:

```bash
cd ~/oskar && tools/nested-session.sh tools/smoke-daemon.sh
```

  From the tree that was built — the clone, or `~/osk-src` if the source
  was the share. Never from `/mnt/osk-src`: the script finds the daemon
  relative to the repo root, and the share is the host's tree, read-only
  and carrying the host's build output if any.
- **`smoke-daemon.sh` runs the binary it finds, and never builds one.** A
  `git pull` in the guest changes the source and nothing else, so the
  suite silently keeps testing the previous build. Run `cargo build
  --release --manifest-path daemon/Cargo.toml` after every pull that
  touched `daemon/`. A daemon fix that reads as still-broken here, with
  the suite otherwise healthy, is this first.
- **The nested session comes up without an output perhaps a third of the
  time in the guest**, and roughly as often does not come up at all. The
  suite's typing target is the first test that needs one, so it is where
  this shows: `the nested compositor never published a monitor`, or
  foot's own `no monitors available`. It is the VM, not the helper —
  re-run. Best guess is the guest's Virtual-1 having no viewer attached,
  so a nested Hyprland's window sometimes never activates. Nothing else
  in the suite needs an output, which is why it only appeared now.
- Every SSH command needs the **live** instance signature, and
  `ls -t $XDG_RUNTIME_DIR/hypr | head -1` no longer gives it: each nested
  run leaves a directory behind and they are all newer than the session's
  own — the live one is usually the oldest. Ask the sockets which one is
  still answering (Hyprland's own environ does not carry it):

```bash
ssh omarchy-vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u); for d in $XDG_RUNTIME_DIR/hypr/*/; do printf "j/version" | socat - UNIX-CONNECT:"$d.socket.sock" >/dev/null 2>&1 && basename "$d"; done'
```
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
- The integration seam runs in the guest: 25 passed, 20 compositor keymap
  rebuild log lines (ceiling 30). It now includes Electron 43 on native
  Ozone/Wayland for the DomCode regression and a compiled public Wayland
  observer for the one-keymap/focus regression. The observer build needs
  `cc`, `pkg-config`, `wayland-scanner`, `wayland-client`, `xkbcommon`, and
  `wayland-protocols`; all are installed in the lab VM.
- Three-group cycling (ticket 10): with `kb_layout = us,ua,de` and the
  physical Caps Lock, the caps walked us → de → us (wrapped) → ua with
  the panel untouched, the helper's device following each switch and
  zero compiles after the config change. The de caps matched a plain
  `xkbcli compile-keymap --layout de` for AD01–AD11, AC10, AC11, BKSL,
  AE11 and AB01. A real click on the language button advanced the
  physical device (1 → 2) with the caps following; with `main` on the
  helper's own virtual keyboard after a shell restart the button drew
  muted and clicking it moved nothing. Physical devices and the
  `power-button` pseudo-device never left group 0 unless a switch
  targeted them.

## Still to do here

1. Actual daily use — open the panel, click keys, work in it for a while.
2. XWayland target: type into an XWayland window (xterm under XWAYLAND).
3. fcitx5 running vs stopped, both ways.
4. Longer hotplug storms while typing.

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

## As found — 2026-09-17 (ticket 59, the rename round)

- The lab entered the round with the pre-rename package
  (`omarchy-osk` 0.1.0-4) installed, set up and active; the round's
  package-test walked it old → new: the old package came out first
  (`pacman -Rdd omarchy-osk` — a plain `pacman -U oskar` refuses on
  conflicts; `replaces=` only walks the replacement on -Syu),
  `oskar setup` migrated registration, config and state, and a second
  leg proved bare `oskar upgrade` completes the walk on its own.
- The lab was left healthy under the NEW name: package `oskar`
  (0.1.0-2) installed, `oskar setup` active (registration →
  `/usr/share/oskar/plugin`, unit enabled and running, `oskar doctor`
  green), the guest's working tree at `~/oskar`. The old registration
  was a symlink here and was unlinked by the migration; a registration
  that is a real DIRECTORY (the provisioner's shape) would be moved
  aside as `io.github.vladkarok.osk.migrated-<ts>`. The old-name clone
  at `~/omarchy-osk` is inert and unregistered — delete it whenever.
- The libvirt domain was renamed `omarchy-osk` → `oskar` (user-session
  connection) so the QMP legs' `virsh` commands match the tree.
