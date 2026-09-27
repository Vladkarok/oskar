#!/usr/bin/env bash
# docs/disclosure-map.md cites the lines that make each disclosure true.
# Every `path:line` it cites must still exist — the file present and the
# line within its length — or the map has rotted and says so.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
map="$root/docs/disclosure-map.md"
[[ -f "$map" ]] || { echo "disclosure map missing: $map" >&2; exit 1; }

mapfile -t refs < <(grep -oE '`[A-Za-z0-9_./-]+:[0-9]+`' "$map" | tr -d '`')
if (( ${#refs[@]} == 0 )); then
  echo "disclosure map cites nothing; is it the map at all?" >&2
  exit 1
fi
bad=0
for ref in "${refs[@]}"; do
  file="${ref%:*}"
  line="${ref##*:}"
  if [[ ! -f "$root/$file" ]]; then
    echo "disclosure map: $ref — no such file" >&2
    bad=1
    continue
  fi
  length=$(wc -l < "$root/$file")
  if (( line < 1 || line > length )); then
    echo "disclosure map: $ref — $file has $length lines" >&2
    bad=1
  fi
done
(( bad == 0 )) && echo "disclosure map: ${#refs[@]} citations resolve"
exit "$bad"
