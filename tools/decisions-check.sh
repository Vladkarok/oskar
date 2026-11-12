#!/usr/bin/env bash
# Every `decisions §N` citation in the tracked tree must name an entry that
# docs/decisions.md still has. Entries are never renumbered, so a citation
# that stops resolving means an entry was deleted while something still
# leans on it.
#
# Two citation shapes are checked:
#   * explicit: "decisions §N", "decisions.md §N", "[decisions.md §§1–3]",
#     "decisions §119, §120", "decisions §39/§40/§42", "§N of decisions";
#   * bare: "§N" with N >= 14 outside decisions.md. Only decisions.md has
#     sections that high; spec-v1.md (15 sections) is left out, and so is
#     a number written after "v1 " or "v1.1 ".
#
#   tools/decisions-check.sh            check, exit 1 on a dangling citation
#   tools/decisions-check.sh --uncited  also list entries nothing cites
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

python3 -I - "${1:-}" <<'PY'
import re, subprocess, sys

def expand(a, b):
    a, b = int(a), int(b) if b else int(a)
    return range(a, b + 1)

entries = set()
for line in open("docs/decisions.md", encoding="utf-8"):
    m = re.match(r"- \*\*§(\d+)(?:[–-]§?(\d+))?", line)
    if m:
        entries.update(expand(m.group(1), m.group(2)))

files = subprocess.run(["git", "ls-files", "-z"], capture_output=True,
                       check=True).stdout.decode().split("\0")

num = r"§§?(\d+)(?:[–-]§?(\d+))?"
explicit = re.compile(
    r"decisions(?:\.md)?\]?\)?\s*((?:" + num + r")(?:\s*(?:,|/|and)\s*§?\d+(?:[–-]§?\d+)?)*)",
    re.I)
of_decisions = re.compile(r"§(\d+) of decisions", re.I)
bare = re.compile(r"(?<![\w.§])(?<!v1 )(?<!v1\.1 )§(\d+)(?:[–-]§(\d+))?")

cited = {}
dangling = []

# decisions.md's own cross-references, from the first section on (the intro
# names the numbers that are deliberately absent).
body = open("docs/decisions.md", encoding="utf-8").read()
body_start = body.index("\n## ")
for lineno, line in enumerate(body.splitlines(), 1):
    if sum(len(l) + 1 for l in body.splitlines()[:lineno - 1]) < body_start:
        continue
    refs = set()
    for a, b in re.findall(r"§(\d+)(?:[–-]§(\d+))?", line):
        refs.update(expand(a, b))
    for n in sorted(refs):
        if n not in entries:
            dangling.append(f"docs/decisions.md:{lineno}: §{n} has no entry")

for path in files:
    if not path or path == "docs/decisions.md":
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for lineno, line in enumerate(text.splitlines(), 1):
        found = set()
        for m in explicit.finditer(line):
            for a, b in re.findall(r"§?§?(\d+)(?:[–-]§?(\d+))?", m.group(1)):
                found.update(expand(a, b))
        for m in of_decisions.finditer(line):
            found.add(int(m.group(1)))
        if path != "docs/spec-v1.md":
            for m in bare.finditer(line):
                for n in expand(m.group(1), m.group(2)):
                    if n >= 14:
                        found.add(n)
        for n in sorted(found):
            cited.setdefault(n, []).append(f"{path}:{lineno}")
            if n not in entries:
                dangling.append(f"{path}:{lineno}: §{n} has no entry")

print(f"decisions check: {len(entries)} entries, "
      f"{sum(len(v) for v in cited.values())} citations of "
      f"{len(cited)} distinct sections")
for d in dangling:
    print(d, file=sys.stderr)
if sys.argv[1:] == ["--uncited"]:
    print("uncited entries:", " ".join(f"§{n}" for n in sorted(entries - cited.keys())))
if dangling:
    print(f"decisions check failed — {len(dangling)} dangling citation(s)", file=sys.stderr)
    sys.exit(1)
print("decisions check: every citation resolves")
PY
