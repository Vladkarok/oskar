#!/usr/bin/env bash
# Host-runnable suites: the panel's pure JavaScript modules and the helper's
# Rust unit tests. Neither needs a compositor. Everything that does need one
# lives in tools/smoke-daemon.sh and runs under tools/nested-session.sh.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Qt 6's runtime, not Qt 5's: /usr/bin/qml on Arch is still the Qt 5 one, and
# it cannot load a QtQml-only document.
qml=""
for candidate in /usr/lib/qt6/bin/qml "$(command -v qml6 || true)" "$(command -v qml || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" --help 2>&1 | grep -q "Qt 6" || [[ "$candidate" == *qt6* || "$candidate" == *qml6 ]]; then
    qml="$candidate"
    break
  fi
done
if [[ -z "$qml" ]]; then
  echo "no Qt 6 qml runtime found; install qt6-declarative" >&2
  exit 1
fi

# The suites render nothing, so refuse a display rather than opening one.
export QT_QPA_PLATFORM=offscreen
# Qt routes qml logging to journald when stderr is not a terminal, which
# silently swallows every assertion message under CI or a pipe.
export QT_ASSUME_STDERR_HAS_CONSOLE=1
# tests/ui-strings.qml reads the runtime QML sources to resolve every
# tr() call site against the table — Qt disables XHR on local files by
# default, and the suite is the only consumer of the escape hatch.
export QML_XHR_ALLOW_FILE_READ=1

status=0
for suite in "$root"/tests/*.qml; do
  echo "== $(basename "$suite")"
  "$qml" "$suite" || status=1
done

echo "== qml static check"
"$root/tools/qml-check.sh" || status=1

# The packaging gate runs on its own: it must never ride
# behind the QML check's type-availability skip.
echo "== packaging file-set check"
"$root/tools/package-check.sh" || status=1

# The install script's branches, in a sandbox (a private HOME, a stubbed
# systemctl, a fake prebuilt tarball): ownership refusals, the prebuilt
# path, the no-toolchain reruns. Nothing on the machine is touched.
echo "== install script check"
"$root/tools/install-check.sh" || status=1

if [[ "${1:-}" != "--js-only" ]]; then
  echo "== helper unit tests"
  cargo test --manifest-path "$root/daemon/Cargo.toml" --quiet || status=1
fi

exit "$status"
