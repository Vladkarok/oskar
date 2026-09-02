#!/usr/bin/env bash
#
# Runs INSIDE the Omarchy VM (not on the host).
#
# A freshly installed guest has neither the share mounted nor sshd running,
# and this script is what fixes both — so the first run is typed at the guest
# console, mount included:
#
#   sudo mkdir -p /mnt/osk-src
#   sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 osk-src /mnt/osk-src
#   bash /mnt/osk-src/tools/omarchy-vm-provision.sh
#
# It adds the fstab entry, so from the next boot the mount is simply there
# and later runs are either of:
#
#   bash /mnt/osk-src/tools/omarchy-vm-provision.sh          # in the guest
#   ssh -tt omarchy-vm 'bash -s' < tools/omarchy-vm-provision.sh   # from the host
#
# -tt because the sudo calls need a terminal to prompt on: stdin is the
# script itself. Piped in that way the script needs no mount to start, so it
# also repairs a guest that lost the share.
#
# Idempotent. Installs the build toolchain, syncs the host repo from the 9p
# share to a guest-local copy (9p is far too slow for a cargo target dir),
# builds the daemon, installs the plugin and the systemd service, and turns
# on sshd so the host can drive the VM afterwards. Re-run it any time the
# host repo changed.
#
# First run wants one sudo password (packages). Every later run is silent
# unless packages are missing again.

set -euo pipefail

SRC=/mnt/osk-src
PLUGIN_ID=io.github.vladkarok.osk
HOME_SRC="$HOME/osk-src"

MOUNT_OPTS=trans=virtio,version=9p2000.L,msize=104857600

# Reachable only when the script arrived some way that did not go through the
# mount — piped in over ssh on a fresh guest, or run from the ~/osk-src copy a
# previous run left behind.
if [[ ! -d "$SRC/tools" ]]; then
    echo "mounting host repo share" >&2
    sudo mkdir -p "$SRC"
    sudo mount -t 9p -o "$MOUNT_OPTS" osk-src "$SRC" || true
fi
if [[ ! -d "$SRC/tools" ]]; then
    echo "ERROR: host repo share not reachable at $SRC" >&2
    exit 1
fi

# A mount that dies at reboot makes the documented invocation a lie every
# cold boot. nofail so a guest booted without the share still reaches a login
# prompt; the export is read-only on the host side either way.
if ! grep -q "[[:space:]]$SRC[[:space:]]" /etc/fstab; then
    echo "osk-src $SRC 9p $MOUNT_OPTS,ro,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
    sudo systemctl daemon-reload
fi

# rust builds the daemon; pkg-config + libxkbcommon link the xkbcommon crate;
# rsync syncs; openssh lets the host drive this machine afterwards; python
# runs the integration suite. The gate checks every dependency individually —
# a rerun with only some of them present must still install the rest. -Syu
# rather than -Sy: a partial upgrade is how Arch systems get broken.
if ! command -v cargo >/dev/null || ! command -v pkg-config >/dev/null \
        || ! command -v rsync >/dev/null || ! command -v jq >/dev/null \
        || ! command -v sshd >/dev/null || ! command -v python3 >/dev/null \
        || ! pacman -Q libxkbcommon >/dev/null 2>&1; then
    sudo pacman -Syu --needed --noconfirm rust pkg-config rsync openssh jq libxkbcommon python
fi

# Guest-local copy: building on 9p is possible but painfully slow, and the
# daemon target dir is excluded from the sync anyway. tools/ comes along
# because the integration suite runs here, against the daemon built below —
# and it has to run from this copy, since the paths inside it are relative to
# the repo root and the 9p mount has no build output.
mkdir -p "$HOME_SRC"
rsync -a --delete \
    --exclude .git --exclude 'daemon/target' --exclude 'core.*' \
    "$SRC/" "$HOME_SRC/"

echo "--- building daemon"
cargo build --release --manifest-path "$HOME_SRC/daemon/Cargo.toml"

echo "--- installing plugin and service"
mkdir -p "$HOME/.config/omarchy/plugins/$PLUGIN_ID"
rsync -a --delete \
    --exclude .git --exclude daemon --exclude tools --exclude 'core.*' \
    "$HOME_SRC/" "$HOME/.config/omarchy/plugins/$PLUGIN_ID/"
install -Dm755 "$HOME_SRC/daemon/target/release/omarchy-osk-daemon" "$HOME/.local/libexec/omarchy-osk-daemon"
install -Dm644 "$HOME_SRC/systemd/omarchy-osk.service" "$HOME/.config/systemd/user/omarchy-osk.service"
systemctl --user daemon-reload
# A rerun after host edits installs a new binary; a running service would
# keep serving the old one without this.
if systemctl --user is-active --quiet omarchy-osk; then
    systemctl --user try-restart omarchy-osk
fi

# Same layouts the real machine runs, so the layout zoo looks familiar.
# Keyed on our own marker comment: grepping for "kb_layout" matches the
# commented-out example in Omarchy's stock input.lua, which makes the script
# believe its block is already there and skip appending it forever.
if ! grep -q "omarchy-vm-provision.sh" "$HOME/.config/hypr/input.lua" 2>/dev/null; then
    cat >> "$HOME/.config/hypr/input.lua" <<'LUA'

-- Two layouts and Caps Lock switching, mirroring the real machine (added by
-- omarchy-vm-provision.sh).
hl.config({
  input = {
    kb_layout = "us,ua",
    kb_options = "shift:both_capslock_cancel,grp:caps_toggle",
  },
})
LUA
    hyprctl reload >/dev/null 2>&1 || true
fi

sudo systemctl enable --now sshd

# The service is left enabled or not exactly as omarchy plugin enable leaves
# it; the banner below only reports what happened.
if omarchy plugin enable "$PLUGIN_ID"; then
    plugin_state="enabled"
else
    plugin_state="NOT enabled (omarchy plugin enable failed — run it by hand)"
fi

cat <<NEXT

Provisioning done.
  - plugin installed ($plugin_state), daemon built and installed
  - enable typing:   systemctl --user enable --now omarchy-osk
  - host access:     ssh -p 2222 into this machine works
  - integration suite:
      cd $HOME_SRC && tools/nested-session.sh tools/smoke-daemon.sh
  - re-sync + rebuild after host edits: rerun this script
NEXT
