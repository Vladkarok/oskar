#!/usr/bin/env bash
# Builds and installs the input helper, then enables it for the graphical
# session. Run again after updating the plugin: the QML side and the helper
# share a protocol version, and a plugin updated without the helper will report
# that it needs reinstalling rather than typing nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$HOME/.local/libexec/oskar-daemon"
unit="$HOME/.config/systemd/user/oskar.service"

if ! command -v cargo >/dev/null; then
  echo "cargo is required to build the helper. Install it with:" >&2
  echo "  omarchy pkg add rust" >&2
  exit 1
fi

echo "Building the input helper..."
cargo build --locked --release --manifest-path "$here/daemon/Cargo.toml"

install -Dm755 "$here/daemon/target/release/oskar-daemon" "$binary"
install -Dm644 "$here/systemd/oskar.service" "$unit"

# The lifecycle command: same script the package installs as
# /usr/bin/oskar, exposed under the user's path. A symlink, so a
# checkout stays its own source of truth while it is the registered
# payload.
mkdir -p "$HOME/.local/bin"
ln -sfn "$here/bin/oskar" "$HOME/.local/bin/oskar"

systemctl --user daemon-reload
systemctl --user enable oskar.service

# Only start it now if there is a session to attach to. Outside one the unit
# would refuse on ConditionEnvironment and look like a failure.
if systemctl --user --quiet is-active graphical-session.target; then
  systemctl --user restart oskar.service
  # "Running" means the new helper answers, not that systemd started it: a
  # check straight after this script would otherwise meet the old socket.
  socket="${XDG_RUNTIME_DIR:-$HOME/.run}/oskar/control.sock"
  version="$(sed -n 's/^PROTOCOL_VERSION="\(.*\)"$/\1/p' "$here/bin/oskar")"
  answered=""
  can_ask=""
  command -v socat >/dev/null && [[ -n "$version" ]] && can_ask=1
  for _ in $(seq 1 20); do
    [[ -n "$can_ask" ]] || break
    if [[ -S "$socket" ]] \
        && printf 'hello %s\n' "$version" \
          | timeout 2 socat -t1 - UNIX-CONNECT:"$socket" 2>/dev/null \
          | head -n1 | grep -q "^hello $version"; then
      answered=1
      break
    fi
    sleep 0.5
  done
  if [[ -n "$answered" ]]; then
    echo "Helper installed and running."
  elif [[ -z "$can_ask" ]]; then
    echo "Helper installed and started (install socat to have it checked)."
  else
    echo "Helper installed, but it did not answer within 10 s; see: systemctl --user status oskar.service" >&2
  fi
else
  echo "Helper installed. It will start with your next graphical session."
fi
