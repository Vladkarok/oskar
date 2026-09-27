#!/usr/bin/env bash
# Uninstalls the SOURCE install's files: the helper binary, the user unit
# and the ~/.local/bin lifecycle symlink. Deactivation (plugin disable,
# unit stop, registration unlink) is the lifecycle command's job and runs
# FIRST, but only when this checkout's registration is the live one — a
# packaged install (or another checkout) must not be switched off by
# uninstalling this. In a mixed state (registration at this checkout
# while the packaged unit is the one systemd runs) the teardown disables
# the packaged unit — recoverable with `oskar setup`. Config and the
# panel's state are never touched; the install record under
# ~/.local/state/oskar forgets each path removed here and goes with the
# last one. Package files belong to pacman; run `oskar teardown` there
# instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reg="$HOME/.config/omarchy/plugins/io.github.vladkarok.oskar"
unit="$HOME/.config/systemd/user/oskar.service"
binary="$HOME/.local/libexec/oskar-daemon"
cli="$HOME/.local/bin/oskar"

# Every decision below asks the install record through bin/oskar; without
# it nothing can be proven, so nothing is switched off or removed.
if [[ ! -f "$here/bin/oskar" || ! -r "$here/bin/oskar" ]]; then
  echo "uninstall.sh: $here/bin/oskar is missing or unreadable, so the install record cannot be consulted; nothing was changed" >&2
  exit 1
fi
ours() { bash "$here/bin/oskar" record matches "$1" >/dev/null 2>&1; }

# The helper binary, the unit and the command are SHARED paths: whichever
# checkout installed LAST uses them, and the command symlink names that
# checkout. Removing them while another checkout's install is live would
# gut its service mid-flight, so this checkout removes them only while
# the command points here. Even then each file goes only when the install
# record proves it is what OSKar wrote and unchanged since.
cli_owner="$(readlink -f "$cli" 2>/dev/null || true)"
mine=""
[[ "$cli_owner" == "$(readlink -f "$here/bin/oskar")" ]] && mine=1
matched=()
unmatched=()
if [[ -n "$mine" ]]; then
  for path in "$unit" "$binary" "$cli"; do
    if ours "$path"; then
      matched+=("$path")
    elif [[ -e "$path" || -L "$path" ]]; then
      unmatched+=("$path")
    fi
  done
  # Decided before anything is switched off: with not one file proven,
  # a teardown would disable the plugin and leave the service running.
  if ((${#matched[@]} == 0 && ${#unmatched[@]})); then
    echo "uninstall.sh: none of these files matches OSKar's install record:" >&2
    printf '  %s\n' "${unmatched[@]}" >&2
    echo "This install was made by an OSKar version older than its install record, or the files were changed since. Nothing was removed or switched off." >&2
    echo "Run ./install.sh --force once (it moves them aside and deletes nothing), then run uninstall.sh again." >&2
    exit 3
  fi
fi

if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" ]]; then
  bash "$here/bin/oskar" teardown
else
  echo "uninstall.sh: registration does not point at this checkout; leaving the live install alone" >&2
fi

if [[ -n "$mine" ]]; then
  removed=()
  for path in ${matched[@]+"${matched[@]}"}; do
    if ours "$path"; then
      rm -f -- "$path"
      removed+=("$path")
    else
      unmatched+=("$path")
    fi
  done
  if ((${#removed[@]})); then
    bash "$here/bin/oskar" record forget "${removed[@]}" \
      || echo "uninstall.sh: the install record could not be updated" >&2
  fi
  systemctl --user daemon-reload
  if [[ -e "$reg" || -L "$reg" ]] \
      && [[ "$(readlink -f "$reg" 2>/dev/null || true)" != "$(readlink -f "$here")" ]]; then
    echo "uninstall.sh: note — the registration at $(readlink -f "$reg" 2>/dev/null || echo "$reg") relied on the shared unit just removed; that checkout must run its own install again before the next reboot or its service will be absent" >&2
  fi
  if ((${#unmatched[@]})); then
    echo "uninstall.sh: these do not match what OSKar installed, so they stay:" >&2
    printf '  %s\n' "${unmatched[@]}" >&2
    enabled="$(systemctl --user is-enabled oskar.service 2>/dev/null || true)"
    active="$(systemctl --user is-active oskar.service 2>/dev/null || true)"
    echo "uninstall.sh: oskar.service is now ${enabled:-unknown} and ${active:-unknown}" >&2
    echo "Source install partly removed: the files above stay. Config and state preserved."
  else
    echo "Source install removed. Config and state preserved."
  fi
elif [[ -e "$cli" || -e "$binary" || -e "$unit" ]]; then
  echo "uninstall.sh: the shared helper/service/CLI belong to another install${cli_owner:+ ($cli_owner)}${cli_owner:+ or to a checkout that is gone}; leaving them in place" >&2
  echo "uninstall.sh: this checkout's files are gone with the checkout itself" >&2
  if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" ]] \
      && [[ -L "$reg" ]]; then
    echo "uninstall.sh: the registration is a stale symlink to this checkout; remove it with: rm '$reg'" >&2
  fi
else
  echo "Source install already absent. Config and state preserved."
fi
