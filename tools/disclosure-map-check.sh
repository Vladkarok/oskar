#!/usr/bin/env bash
# docs/disclosure-map.md cites the lines that make each disclosure true, as
# `path:line` followed by `the text on that line`. A citation holds only if
# that text is still on the cited line or within three lines of it; a map
# whose citations drifted from the code proves nothing, and fails here.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
map="$root/docs/disclosure-map.md"
[[ -f "$map" ]] || { echo "disclosure map missing: $map" >&2; exit 1; }

python3 - "$root" "$map" <<'PY'
import re, sys
root, map_path = sys.argv[1], sys.argv[2]
text = open(map_path, encoding="utf-8").read()
cited = re.findall(r"`([A-Za-z0-9_./-]+):(\d+)`", text)
pairs = re.findall(r"`([A-Za-z0-9_./-]+):(\d+)` `([^`]+)`", text)
if not cited:
    sys.exit("disclosure map cites nothing; is it the map at all?")
bad = []
if len(pairs) != len(cited):
    bad.append(f"{len(cited) - len(pairs)} citation(s) carry no quoted snippet")
for path, line, snippet in pairs:
    try:
        lines = open(f"{root}/{path}", encoding="utf-8").read().split("\n")
    except OSError:
        bad.append(f"{path}:{line} — no such file")
        continue
    n = int(line)
    window = lines[max(0, n - 4):n + 3]
    if not any(snippet in candidate for candidate in window):
        bad.append(f"{path}:{line} — `{snippet}` is not within three lines")
for problem in bad:
    print("disclosure map: " + problem, file=sys.stderr)
if bad:
    sys.exit(1)
print(f"disclosure map: {len(pairs)} citations hold")
PY
