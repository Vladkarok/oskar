#!/usr/bin/env bash
#
# Runs INSIDE the Omarchy VM (not on the host):
#
#   bash /mnt/osk-src/tools/omarchy-vm-provision.sh
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

if [[ ! -d "$SRC/tools" ]]; then
    echo "mounting host repo share" >&2
    sudo mkdir -p "$SRC"
    sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 osk-src "$SRC"
fi

# rust builds the daemon; pkg-config + libxkbcommon link the xkbcommon crate;
# rsync syncs; openssh lets the host drive this machine afterwards.
if ! command -v cargo >/dev/null || ! command -v rsync >/dev/null || ! command -v jq >/dev/null; then
    sudo pacman -Sy --needed --noconfirm rust pkg-config rsync openssh jq
fi

# Guest-local copy: building on 9p is possible but painfully slow, and the
# daemon target dir is excluded from the sync anyway.
mkdir -p "$HOME_SRC"
rsync -a --delete \
    --exclude .git --exclude 'daemon/target' --exclude tools --exclude 'core.*' \
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

# Same layouts the real machine runs, so the layout zoo looks familiar.
if ! grep -q "kb_layout" "$HOME/.config/hypr/input.lua" 2>/dev/null; then
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

# The service is left disabled until you choose to turn it on: the whole
# point of this VM is deciding whether it earns a place in autostart.
omarchy plugin enable "$PLUGIN_ID" 2>/dev/null || true

cat <<'NEXT'

Provisioning done.
  - plugin installed (enabled), daemon built and installed (service still disabled)
  - enable typing:   systemctl --user enable --now omarchy-osk
  - host access:     ssh -p 2222 into this machine works
  - re-sync + rebuild after host edits: rerun this script
NEXT
