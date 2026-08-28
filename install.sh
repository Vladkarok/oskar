#!/usr/bin/env bash
# Builds and installs the input helper, then enables it for the graphical
# session. Run again after updating the plugin: the QML side and the helper
# share a protocol version, and a plugin updated without the helper will report
# that it needs reinstalling rather than typing nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$HOME/.local/libexec/omarchy-osk-daemon"
unit="$HOME/.config/systemd/user/omarchy-osk.service"

if ! command -v cargo >/dev/null; then
  echo "cargo is required to build the helper. Install it with:" >&2
  echo "  omarchy pkg add rust" >&2
  exit 1
fi

echo "Building the input helper..."
cargo build --locked --release --manifest-path "$here/daemon/Cargo.toml"

install -Dm755 "$here/daemon/target/release/omarchy-osk-daemon" "$binary"
install -Dm644 "$here/systemd/omarchy-osk.service" "$unit"

systemctl --user daemon-reload
systemctl --user enable omarchy-osk.service

# Only start it now if there is a session to attach to. Outside one the unit
# would refuse on ConditionEnvironment and look like a failure.
if systemctl --user --quiet is-active graphical-session.target; then
  systemctl --user restart omarchy-osk.service
  echo "Helper installed and running."
else
  echo "Helper installed. It will start with your next graphical session."
fi
