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

if [[ "$(readlink -f "$reg" 2>/dev/null || true)" == "$here" ]]; then
  bash "$here/bin/oskar" teardown
else
  echo "uninstall.sh: registration does not point at this checkout; leaving the live install alone" >&2
fi

rm -f "$HOME/.config/systemd/user/oskar.service"
rm -f "$HOME/.local/libexec/oskar-daemon"
rm -f "$HOME/.local/bin/oskar"
systemctl --user daemon-reload

echo "Source install removed. Config and state preserved."
