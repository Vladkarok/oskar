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
#
# Three files live outside the checkout: the user unit, the helper binary
# and the ~/.local/bin command. Each is replaced only when the install
# record (bin/oskar, `oskar record`) proves it is what OSKar wrote there
# and unchanged since; anything else under those names is someone else's.
# It is never overwritten: without consent the install stops and names it,
# and `--force` moves it aside under a free dated name before writing.
# Nothing outside the checkout is touched until the install record is
# known usable and a helper is in hand, so a failed build, a missing
# tarball or an unusable record leaves the home directory as it was.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$HOME/.local/libexec/oskar-daemon"
unit="$HOME/.config/systemd/user/oskar.service"
cli="$HOME/.local/bin/oskar"

prebuilt=""
force=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prebuilt)
      prebuilt="${2:-}"
      [[ -n "$prebuilt" ]] || { echo "usage: install.sh [--prebuilt <tarball>] [--force]" >&2; exit 2; }
      [[ -f "$prebuilt" ]] || { echo "no such file: $prebuilt" >&2; exit 2; }
      shift 2 ;;
    --force) force=1; shift ;;
    *) echo "usage: install.sh [--prebuilt <tarball>] [--force]" >&2; exit 2 ;;
  esac
done

# Any failure of the record call — a missing bash, a broken checkout —
# reads as "not ours".
record() { bash "$here/bin/oskar" record "$@"; }
ours() { record matches "$1" >/dev/null 2>&1; }

# ---- 0. the record must be writable before anything is decided by it ----
if ! record usable; then
  echo "install.sh: the install record cannot be kept (reason above); nothing was changed" >&2
  exit 1
fi

# ---- 1. the helper, obtained before anything outside the checkout moves ----
if [[ -z "$prebuilt" ]]; then
  for candidate in "$here"/oskar-daemon-*-"$(uname -m)".tar.gz; do
    [[ -f "$candidate" ]] && prebuilt="$candidate"
  done
fi

staged=""
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
  staged="$(find "$work" -type f -name oskar-daemon | head -n1)"
  [[ -n "$staged" ]] || { echo "$prebuilt holds no oskar-daemon" >&2; exit 1; }
elif command -v cargo >/dev/null; then
  echo "Building the input helper..."
  cargo build --locked --release --manifest-path "$here/daemon/Cargo.toml"
  staged="$here/daemon/target/release/oskar-daemon"
elif ours "$binary"; then
  # The helper OSKar installed is in place, unchanged, and nothing here
  # can build a newer one: keep it. The panel says so if its protocol no
  # longer matches; the two ways to update are named.
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

# ---- 2. another oskar.service that this unit would shadow ----
# A user unit takes the place of any oskar.service at a lower-priority
# path (/usr/lib, ~/.local/share) for this user. That is another
# program's unit unless it is the oskar package's own; installing over it
# needs consent, and even then its file and its enablement links are
# left alone.
resolved="$(systemctl --user show -p FragmentPath --value oskar.service 2>/dev/null || true)"
if [[ -n "$resolved" && "$resolved" != "$unit" ]] && ! [[ -e "$unit" && "$resolved" -ef "$unit" ]] \
    && ! { [[ "$resolved" == /usr/lib/systemd/user/oskar.service ]] \
      && command -v pacman >/dev/null 2>&1 \
      && [[ "$(pacman -Qqo "$resolved" 2>/dev/null)" == oskar ]]; }; then
  if [[ -z "$force" ]]; then
    echo "install.sh: a unit named oskar.service from $resolved is already on this system; installing OSKar's unit would take its place for this user." >&2
    echo "Nothing was changed. Rerun with --force to install anyway: that unit's file is not touched (it is shadowed), and its enablement links are left alone." >&2
    exit 3
  fi
  echo "install.sh: --force: OSKar's unit will shadow oskar.service from $resolved for this user; that file and its enablement links are left alone" >&2
fi

# ---- 3. ownership of the three destinations, before any write ----
foreign=()
for path in "$unit" "$binary" "$cli"; do
  if [[ -e "$path" || -L "$path" ]] && ! ours "$path"; then
    foreign+=("$path")
  fi
done
if ((${#foreign[@]})) && [[ -z "$force" ]]; then
  echo "install.sh: refusing to replace files that do not match OSKar's install record (OSKar did not install them, they changed since, or an OSKar version older than the record installed them):" >&2
  printf '  %s\n' "${foreign[@]}" >&2
  echo "Move them aside yourself, or rerun install.sh with --force: it moves each one aside under a dated name and deletes nothing." >&2
  echo "Files installed by an OSKar version older than its install record also need --force, once." >&2
  exit 3
fi
# --force is all or nothing: every move is checked possible first, and a
# move that still fails puts the ones before it back (their names are
# free — nothing has been written yet).
for path in ${foreign[@]+"${foreign[@]}"}; do
  parent="$(dirname "$path")"
  if [[ ! -w "$parent" || ! -x "$parent" ]]; then
    echo "install.sh: --force cannot move $path aside: $parent is not writable; nothing was moved" >&2
    exit 1
  fi
done
moved_from=()
moved_to=()
for path in ${foreign[@]+"${foreign[@]}"}; do
  if aside="$(record aside "$path" replaced)"; then
    moved_from+=("$path")
    moved_to+=("$aside")
    continue
  fi
  echo "install.sh: could not move $path aside" >&2
  for ((i = ${#moved_from[@]} - 1; i >= 0; i--)); do
    if mv -T -n -- "${moved_to[i]}" "${moved_from[i]}" \
        && [[ -e "${moved_from[i]}" || -L "${moved_from[i]}" ]] \
        && ! [[ -e "${moved_to[i]}" || -L "${moved_to[i]}" ]]; then
      echo "install.sh: moved ${moved_from[i]} back" >&2
    else
      echo "install.sh: could NOT move ${moved_to[i]} back to ${moved_from[i]}; it is still at ${moved_to[i]}" >&2
    fi
  done
  echo "install.sh: nothing was installed" >&2
  exit 1
done
for i in "${!moved_from[@]}"; do
  echo "install.sh: --force: ${moved_from[i]} did not match OSKar's install record; moved aside as ${moved_to[i]}" >&2
done

# ---- 4. the writes, then the record of what was written ----
if [[ -n "$staged" ]]; then
  install -Dm755 "$staged" "$binary"
fi
# The unit and the lifecycle command come from this checkout either way:
# they are the panel's, and the panel is what lives here.
install -Dm644 "$here/systemd/oskar.service" "$unit"

# The lifecycle command: same script the package installs as
# /usr/bin/oskar, exposed under the user's path. A symlink, so a
# checkout stays its own source of truth while it is the registered
# payload.
mkdir -p "$(dirname "$cli")"
ln -sfn "$here/bin/oskar" "$cli"

if ! record write "$unit" "$binary" "$cli"; then
  echo "install.sh: the files are installed but the install record could not be written; a later install will need --force for them" >&2
  exit 1
fi

# ---- 5. systemd ----
systemctl --user daemon-reload
# enable/restart act on whatever file systemd resolves for the name; a
# unit elsewhere on its search path that shadows the one just written is
# not ours to switch on.
fragment="$(systemctl --user show -p FragmentPath --value oskar.service 2>/dev/null || true)"
if [[ -z "$fragment" || "$(realpath -e -- "$fragment" 2>/dev/null)" != "$(realpath -e -- "$unit")" ]]; then
  echo "install.sh: systemd resolves oskar.service to ${fragment:-nothing}, not the unit just installed at $unit; OSKar will not enable or start that one. Remove the other unit yourself, then rerun." >&2
  exit 1
fi
# Enabling acts on the unit just proven ours. If another unit's
# enablement link already holds the same name, systemctl refuses rather
# than replace it, and so does this script.
if ! systemctl --user enable oskar.service; then
  echo "install.sh: systemctl could not enable oskar.service (its message is above); OSKar's unit is installed but not enabled, and no other unit's enablement link was changed" >&2
  exit 1
fi

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
