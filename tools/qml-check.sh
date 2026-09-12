#!/usr/bin/env bash
# Static check for the QML the suites cannot see.
#
# Every offscreen suite here drives the pure JavaScript modules. Nothing loads
# `Keyboard.qml` or `Panel.qml`, and on 2026-09-09 that cost a shipped commit:
# `onPairPositionsChanged` outlived the property it watched, QML refuses a
# handler for a property that does not exist, and the panel would not load at
# all — with 300 checks green. The owner found it.
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
  echo "Quickshell QML types not found; skipping the QML check" >&2
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
while IFS= read -r file; do
  # A syntax error makes qmllint exit nonzero and print NOTHING (verified:
  # rc=255, empty output) - the 8993aad class shipped an unparseable
  # Panel.qml through this check because only the FATAL text was gated.
  # The exit code is the gate for that class; the text gate stays for the
  # handler-contract class.
  if ! output=$("$qmllint" "${imports[@]}" "$root/$file" 2>&1); then
    found+="syntax/parse failure: $file"$'\n'
    status=1
  fi
  hits=$(printf '%s\n' "$output" | grep -E "$FATAL" || true)
  if [[ -n "$hits" ]]; then
    found+="$hits"$'\n'
    status=1
  fi
done < <(cd "$root" && git ls-files '*.qml')

if (( status != 0 )); then
  echo "QML check failed — a handler names something that does not exist:" >&2
  printf '%s' "$found" >&2
  exit 1
fi

echo "qml check: no handler names a property that does not exist"
