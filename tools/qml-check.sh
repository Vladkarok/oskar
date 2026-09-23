#!/usr/bin/env bash
# Static check for the QML the suites cannot see.
#
# Every offscreen suite here drives the pure JavaScript modules. Nothing loads
# `Keyboard.qml` or `Panel.qml`, so a handler outliving the property it
# watches (QML refuses a handler for a property that does not exist,
# and the panel would not load at all) can ship with every offscreen
# check green.
#
# `qmllint` resolves Quickshell's own types (it ships .qmltypes) and says
# exactly that:
#
#   no matching signal found for handler "onPairPositionsChanged"
#
# Verified against the real defect, reintroduced in place: caught at the line.
#
# ONE message, not a category. `qmllint`'s categories are not usable as gates
# here yet:
#
#   * `unqualified` — 851 hits across the tree, almost all of them the
#     ordinary QML idiom of reaching an outer id. Gating it is a refactor,
#     not a check.
#   * `missing-property` — Quickshell types `Socket` as a bare QObject in its
#     qmltypes, so `.write`, `.flush` and `.connected` all "do not exist".
#   * `inheritance-cycle` / `unresolved-type` — `BarWidget.qml` has a root
#     named after its own file and qmllint reads that as self-inheritance.
#   * `uncreatable-type` — `PanelWindow` is creatable in a Quickshell process
#     and nowhere else, which is where it is created.
#
# Widening this is worth doing when one of those is cleaned up. Adding a
# message to FATAL is cheap; making a noisy category fatal would only teach
# everyone to ignore the output.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

qmllint=""
for candidate in /usr/lib/qt6/bin/qmllint "$(command -v qmllint || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  qmllint="$candidate"
  break
done
if [[ -z "$qmllint" ]]; then
  echo "qmllint not found; skipping the QML check (install qt6-declarative)" >&2
  exit 0
fi

# Quickshell's type information is what makes this able to tell a real handler
# from a typo. Without it every handler is unknown and the check would fail on
# everything, so skip rather than cry wolf.
if [[ ! -d /usr/lib/qt6/qml/Quickshell ]]; then
  echo "qml check: SKIPPED — Quickshell QML types not found (install quickshell)" >&2
  echo "the handler-name contract is only enforced where the types exist" >&2
  exit 0
fi

# The panel imports `qs.Commons` from the installed Omarchy shell.
imports=(-I /usr/lib/qt6/qml)
[[ -d /usr/share/omarchy/shell ]] && imports+=(-I /usr/share/omarchy/shell)

# Messages that are worth failing a build over: each one means the file cannot
# do what it says, and each one is at zero across the tree today.
FATAL='no matching signal found for handler'

status=0
found=""
# Enumerate the FILESYSTEM, not `git ls-files`: a release archive carries
# no .git, so a git enumeration would come back empty and the check would
# bless whatever it was handed. Tests, tools, the daemon's
# vendored tree and every hidden directory (a .scratch experiment must
# not gate the build) stay out; an empty enumeration is a failure, never
# a pass.
mapfile -t qml_files < <(find "$root" -type f -name '*.qml' \
  -not -path "$root/.*" -not -path "$root/tests/*" -not -path "$root/tools/*" \
  -not -path "$root/daemon/*" -not -path "$root/third_party/*" | sort)
if (( ${#qml_files[@]} == 0 )); then
  echo "QML check failed — no QML files found under $root; is this a tree at all?" >&2
  exit 1
fi
for path in "${qml_files[@]}"; do
  file="${path#"$root"/}"
  # A syntax error makes qmllint exit nonzero and print NOTHING (verified:
  # rc=255, empty output) - the 8993aad class shipped an unparseable
  # Panel.qml through this check because only the FATAL text was gated.
  # The exit code is the gate for that class; the text gate stays for the
  # handler-contract class.
  if ! output=$("$qmllint" "${imports[@]}" "$path" 2>&1); then
    found+="syntax/parse failure: $file"$'\n'
    status=1
  fi
  hits=$(printf '%s\n' "$output" | grep -E "$FATAL" || true)
  if [[ -n "$hits" ]]; then
    found+="$hits"$'\n'
    status=1
  fi
done

if (( status != 0 )); then
  echo "QML check failed — a handler names something that does not exist:" >&2
  printf '%s' "$found" >&2
  exit 1
fi

echo "qml check: no handler names a property that does not exist"

# The packaging file-set gate lives in tools/package-check.sh: it must
# run wherever git and a Makefile exist, never behind
# this script's type-availability skip.
