#!/usr/bin/env bash
# Removes the input helper and its service. Leaves the plugin itself alone —
# use `omarchy plugin remove io.github.vladkarok.osk` for that.
set -euo pipefail

systemctl --user disable --now omarchy-osk.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/omarchy-osk.service"
rm -f "$HOME/.local/libexec/omarchy-osk-daemon"
systemctl --user daemon-reload

echo "Helper removed."
