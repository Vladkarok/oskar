#!/usr/bin/env bash
# Split-watcher (ticket 64 follow-up): catch the seat-splitting in the act.
# Logs every change of the physical keyboards' group vector, with the last
# oskar/fcitx journal lines AROUND the change — so the next occurrence names
# the culprit (our helper's connect/configure/share moments, fcitx5's vkb
# churn on window focus, or Hyprland's own re-application).
# Run: tools/split-watcher.sh >& ~/.local/state/oskar/split-watch.log &
set -uo pipefail
DEVS='[.keyboards[] | select(.name|test("ite.*keyboard$|at-translated")) | .active_layout_index] | @csv'
last="$(hyprctl devices -j | jq -r "$DEVS" 2>/dev/null)"
echo "[$(date -Is)] watcher start: groups=$last"
while sleep 2; do
  now="$(hyprctl devices -j | jq -r "$DEVS" 2>/dev/null)"
  [[ "$now" == "$last" ]] && continue
  echo "[$(date -Is)] SPLIT/MOVE: $last -> $now"
  echo "--- oskar/fcitx journal, 30s before:"
  journalctl --user --since "-30s" 2>/dev/null \
    | grep -iE "oskar|fcitx|activelayout" | tail -15 | sed 's/^/  /'
  last="$now"
done
