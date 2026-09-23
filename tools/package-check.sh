#!/usr/bin/env bash
# The packaging file-set gate, INDEPENDENT of the QML type check: living
# behind the type check's early exit-0 for missing Quickshell types would
# let a CI container without Quickshell skip both gates. This script
# needs only find, grep and the Makefile, and always runs.
#
# Every runtime module the tree ships must be on the package's list. A
# module missing from PLUGIN_RUNTIME means a make-installed panel cannot
# LOAD at all — the suites stay green because they import the tree, not
# the package, so only a real package build catches it. Here the file
# set is the gate: a new root module fails the check until it is
# declared shippable.
#
# Round eight: the enumeration is the FILESYSTEM, not `git ls-files` — a
# release archive carries no .git, the old enumeration came back empty,
# and the gate blessed whatever it was handed. An empty enumeration is a
# failure, never a pass.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

mapfile -t files < <(find "$root" -maxdepth 1 -type f \( -name '*.qml' -o -name '*.js' \) | sort)
if (( ${#files[@]} == 0 )); then
  echo "Packaging check failed — no QML/JS files found at the tree root; is this a tree at all?" >&2
  exit 1
fi

missing=""
for path in "${files[@]}"; do
  file="${path#"$root"/}"
  # Test/tool-only files are not runtime; qml-check.sh guards itself.
  case "$file" in
    tests/*|tools/*) continue ;;
  esac
  if ! grep -q "$(basename "$file")" "$root/Makefile"; then
    missing+="$file"$'\n'
  fi
done

if [[ -n "$missing" ]]; then
  echo "Packaging check failed — runtime files absent from the Makefile's PLUGIN_RUNTIME:" >&2
  printf '%s' "$missing" >&2
  exit 1
fi

echo "qml check: every runtime module is on the package list"
