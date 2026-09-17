#!/usr/bin/env bash
#
# Runs INSIDE the Omarchy VM (not on the host), from whichever copy of the
# repo the guest has. Two ways to get one:
#
#   git clone https://github.com/vladkarok/oskar   # simplest
#   bash oskar/tools/omarchy-vm-provision.sh
#
# and the 9p share the VM exports, which is the host's working tree — the
# only way to test edits that are not pushed yet:
#
#   bash /mnt/osk-src/tools/omarchy-vm-provision.sh
#
# A freshly installed guest has neither the share mounted nor sshd running,
# and this script is what fixes both, so with no clone the first run is typed
# at the console with the mount in front of it:
#
#   sudo mkdir -p /mnt/osk-src
#   sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 osk-src /mnt/osk-src
#   bash /mnt/osk-src/tools/omarchy-vm-provision.sh
#
# That run writes the fstab entry, so from the next boot the mount is simply
# there. Once sshd is up the host can also pipe the script in, which needs
# nothing on the guest and so repairs one that lost its share:
#
#   ssh -tt omarchy-vm 'bash -s' < tools/omarchy-vm-provision.sh
#
# -tt because the sudo calls need a terminal to prompt on: stdin is the
# script itself.
#
# Idempotent. Installs the build toolchain, builds the daemon, installs the
# plugin and the systemd service, enables and starts the service for the
# graphical session (spec-v1.1 §6; opt out with OSK_NO_AUTOSTART=1, which
# disables it), and turns on sshd so the host can drive the VM afterwards.
# Re-run it any time the source changed.
#
# First run wants one sudo password (packages). Every later run is silent
# unless packages are missing again.

set -euo pipefail

SHARE=/mnt/osk-src
PLUGIN_ID=io.github.vladkarok.oskar
MOUNT_OPTS=trans=virtio,version=9p2000.L,msize=104857600

# Where this script is speaks for which copy of the repo it belongs to. Piped
# in over ssh it has no path at all, and then the share is the only source
# there is.
self="${BASH_SOURCE[0]}"
if [[ -f "$self" ]]; then
    SRC=$(cd "$(dirname "$self")/.." && pwd)
else
    SRC="$SHARE"
fi

if [[ "$SRC" == "$SHARE" ]]; then
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
    # cold boot. nofail so a guest booted without the share still reaches a
    # login prompt; the export is read-only on the host side either way.
    if ! grep -q "[[:space:]]$SHARE[[:space:]]" /etc/fstab; then
        echo "osk-src $SHARE 9p $MOUNT_OPTS,ro,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
        sudo systemctl daemon-reload
    fi
fi

# Building on 9p is possible but painfully slow, so the share gets copied to a
# guest-local tree first. A clone is already guest-local and writable: build
# where it stands, and let git rather than rsync be what updates it.
if [[ "$SRC" == "$SHARE" ]]; then
    BUILD_SRC="$HOME/osk-src"
else
    BUILD_SRC="$SRC"
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

if [[ "$BUILD_SRC" != "$SRC" ]]; then
    # tools/ comes along because the integration suite runs in the guest,
    # against the daemon built below — and it has to run from this copy, since
    # its paths are relative to the repo root and the share has no build
    # output. The daemon target dir stays out: it is the reason for the copy.
    mkdir -p "$BUILD_SRC"
    rsync -a --delete \
        --exclude .git --exclude 'daemon/target' --exclude 'core.*' \
        "$SRC/" "$BUILD_SRC/"
fi

echo "--- building daemon from $BUILD_SRC"
cargo build --release --manifest-path "$BUILD_SRC/daemon/Cargo.toml"

echo "--- installing plugin and service"
mkdir -p "$HOME/.config/omarchy/plugins/$PLUGIN_ID"
rsync -a --delete \
    --exclude .git --exclude daemon --exclude tools --exclude 'core.*' \
    "$BUILD_SRC/" "$HOME/.config/omarchy/plugins/$PLUGIN_ID/"
install -Dm755 "$BUILD_SRC/daemon/target/release/oskar-daemon" "$HOME/.local/libexec/oskar-daemon"
install -Dm644 "$BUILD_SRC/systemd/oskar.service" "$HOME/.config/systemd/user/oskar.service"
systemctl --user daemon-reload

# Spec-v1.1 §6 (decisions §19): provisioning enables and starts the helper
# for the graphical session — an installed-but-disabled unit is
# indistinguishable from a broken keyboard, and systemd's restart policy
# owns it from here. OSK_NO_AUTOSTART=1 is the development opt-out: it
# leaves (or puts) the unit disabled, which was the default before §6.
# Both branches warn on systemd failure rather than dying (a helper that
# cannot start must not block provisioning) and rather than passing
# silently (a §11 silent failure).
if [[ "${OSK_NO_AUTOSTART:-}" == "1" ]]; then
    systemctl --user disable --now oskar 2>/dev/null \
        || echo "WARNING: could not disable oskar.service; see 'systemctl --user status oskar'" >&2
    unit_state="off (OSK_NO_AUTOSTART — unit left disabled)"
else
    # Enable and start each warn on failure rather than dying (a helper
    # that cannot start must not block provisioning) and rather than
    # passing silently (a §11 silent failure): what actually happened is
    # warned on stderr here and reported truthfully in the summary below,
    # never papered over with a default success.
    if systemctl --user enable oskar 2>/dev/null; then
        unit_state="enabled"
    else
        echo "WARNING: could not enable oskar.service; see 'systemctl --user status oskar'" >&2
        unit_state="NOT enabled (systemctl enable failed — run it by hand)"
    fi
    if systemctl --user --quiet is-active graphical-session.target; then
        # restart, not start: a rerun after host edits has just installed a
        # new binary, and an already-running service would keep serving the
        # old one. Without a live session the unit's ConditionEnvironment
        # refuses an earlier start — WantedBy starts it at the next login.
        if systemctl --user restart oskar 2>/dev/null; then
            unit_state+=" and started"
        else
            echo "WARNING: oskar.service did not start; see 'journalctl --user -u oskar'" >&2
        fi
    else
        unit_state+=" (no graphical session — starts at the next login)"
    fi
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

# The plugin itself is enabled through omarchy below; the helper unit is
# enabled and started here unless OSK_NO_AUTOSTART is set (see §6 above).
if omarchy plugin enable "$PLUGIN_ID"; then
    plugin_state="enabled"
else
    plugin_state="NOT enabled (omarchy plugin enable failed — run it by hand)"
    # The summary says so too, but success must never be the only voice:
    # the failure warns on stderr here, where a provision log keeps it.
    echo "WARNING: 'omarchy plugin enable $PLUGIN_ID' failed; enable it by hand" >&2
fi

# The unit branch above records what actually happened — enabled, started,
# waiting for a login, or failed with a warning — so the summary never
# reports a success it did not earn.
autostart_state="$unit_state"

cat <<NEXT

Provisioning done.
  - plugin installed ($plugin_state), helper built and installed
  - helper autostart: $autostart_state
  - host access:     ssh -p 2222 into this machine works
  - integration suite:
      cd $BUILD_SRC && tools/nested-session.sh tools/smoke-daemon.sh
  - after source changes: git pull (or rerun from the share), then rerun this
NEXT
