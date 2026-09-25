#!/usr/bin/env bash
# Builds and installs the input helper, then enables it for the graphical
# session. Run again after updating the plugin: the QML side and the helper
# share a protocol version, and a plugin updated without the helper will report
# that it needs reinstalling rather than typing nothing.
#
# Without a Rust toolchain: `install.sh --prebuilt <tarball>` installs the
# helper from the release page's oskar-daemon-<version>-<arch>.tar.gz
# (tools/make-release-assets.sh builds it). A tarball placed beside this
# script is picked up without the flag.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$HOME/.local/libexec/oskar-daemon"
unit="$HOME/.config/systemd/user/oskar.service"

prebuilt=""
case "${1:-}" in
  "") ;;
  --prebuilt)
    prebuilt="${2:-}"
    [[ -n "$prebuilt" ]] || { echo "usage: install.sh [--prebuilt <tarball>]" >&2; exit 2; }
    [[ -f "$prebuilt" ]] || { echo "no such file: $prebuilt" >&2; exit 2; }
    ;;
  *) echo "usage: install.sh [--prebuilt <tarball>]" >&2; exit 2 ;;
esac
if [[ -z "$prebuilt" ]]; then
  for candidate in "$here"/oskar-daemon-*-"$(uname -m)".tar.gz; do
    [[ -f "$candidate" ]] && prebuilt="$candidate"
  done
fi

if [[ -n "$prebuilt" ]]; then
  echo "Installing the prebuilt helper from $(basename "$prebuilt")..."
  # The tarball was built for one plugin version; a different plugin may
  # speak a different protocol. The panel reports a mismatch on its own,
  # so this is a warning, not a refusal — the owner of the machine may
  # know better (a dry run from a branch, say).
  version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$here/manifest.json" | head -1)"
  if [[ "$(basename "$prebuilt")" != "oskar-daemon-$version-"* ]]; then
    echo "warning: $(basename "$prebuilt") was not built for plugin version $version; the panel will say if the protocol differs" >&2
  fi
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tar -xzf "$prebuilt" -C "$work"
  extracted="$(find "$work" -type f -name oskar-daemon | head -n1)"
  [[ -n "$extracted" ]] || { echo "$prebuilt holds no oskar-daemon" >&2; exit 1; }
  install -Dm755 "$extracted" "$binary"
else
  if ! command -v cargo >/dev/null; then
    if [[ -x "$binary" ]]; then
      # A prebuilt helper is already in place and nothing here can build a
      # newer one: keep it. The panel says so if its protocol no longer
      # matches; the two ways to update are named.
      echo "No cargo: keeping the installed helper at $binary." >&2
      echo "To update it: omarchy pkg add rust and rerun, or install the release's prebuilt helper:" >&2
      echo "  bash install.sh --prebuilt oskar-daemon-<version>-$(uname -m).tar.gz" >&2
    else
      echo "cargo is required to build the helper. Install it with:" >&2
      echo "  omarchy pkg add rust" >&2
      echo "or install the release's prebuilt helper without cargo:" >&2
      echo "  bash install.sh --prebuilt oskar-daemon-<version>-$(uname -m).tar.gz" >&2
      exit 1
    fi
  else
    echo "Building the input helper..."
    cargo build --locked --release --manifest-path "$here/daemon/Cargo.toml"
    install -Dm755 "$here/daemon/target/release/oskar-daemon" "$binary"
  fi
fi
# The unit and the lifecycle command come from this checkout either way:
# they are the panel's, and the panel is what lives here.
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
  # A deliberate restart must not be refused by the crash-loop limiter
  # (five starts in 30 s): install, setup and upgrade back to back within
  # a minute are ordinary during a first install.
  systemctl --user reset-failed oskar.service 2>/dev/null || true
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
