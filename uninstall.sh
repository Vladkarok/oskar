#!/usr/bin/env bash
# Uninstalls the SOURCE install's files: the helper binary, the user unit
# and the ~/.local/bin lifecycle symlink. Deactivation (plugin disable,
# unit stop, registration unlink) is the lifecycle command's job and runs
# FIRST, but only when this checkout's registration is the live one — a
# packaged install (or another checkout) must not be switched off by
# uninstalling this. Best-effort: in a mixed state (registration at this
# checkout while the packaged unit is the active one) the unit the
# teardown disables may be the packaged one — recoverable with
# `oskar setup`. Config and state are never touched. Package files
# belong to pacman; run `oskar teardown` there instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reg="$HOME/.config/omarchy/plugins/io.github.vladkarok.oskar"

if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" ]]; then
  bash "$here/bin/oskar" teardown
else
  echo "uninstall.sh: registration does not point at this checkout; leaving the live install alone" >&2
fi

# Ownership before removal (the external round's P2): the helper binary,
# the unit and the CLI symlink are SHARED paths — whichever checkout
# installed LAST owns them. The CLI symlink is the honest marker (each
# install writes it and it names its checkout's bin/oskar); removing the
# trio while another checkout owns it would gut that install's live
# service mid-flight.
cli="$HOME/.local/bin/oskar"
cli_owner="$(readlink -f "$cli" 2>/dev/null || true)"
if [[ "$cli_owner" == "$(readlink -f "$here/bin/oskar")" ]]; then
  rm -f "$HOME/.config/systemd/user/oskar.service"
  rm -f "$HOME/.local/libexec/oskar-daemon"
  rm -f "$cli"
  systemctl --user daemon-reload
  if [[ -e "$reg" || -L "$reg" ]] \
      && [[ "$(readlink -f "$reg" 2>/dev/null || true)" != "$(readlink -f "$here")" ]]; then
    echo "uninstall.sh: note — the registration at $(readlink -f "$reg" 2>/dev/null || echo "$reg") relied on the shared unit just removed; that checkout must run its own install again before the next reboot or its service will be absent" >&2
  fi
  echo "Source install removed. Config and state preserved."
elif [[ -e "$cli" || -e "$HOME/.local/libexec/oskar-daemon"
    || -e "$HOME/.config/systemd/user/oskar.service" ]]; then
  echo "uninstall.sh: the shared helper/service/CLI belong to another install${cli_owner:+ ($cli_owner)}${cli_owner:+ or to a checkout that is gone}; leaving them in place" >&2
  echo "uninstall.sh: this checkout's files are gone with the checkout itself" >&2
  if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$(readlink -f "$here")" ]] \
      && [[ -L "$reg" ]]; then
    echo "uninstall.sh: the registration is a stale symlink to this checkout; remove it with: rm '$reg'" >&2
  fi
else
  echo "Source install already absent. Config and state preserved."
fi
