#!/usr/bin/env bash
# The install script's branches, in a sandbox: a private HOME and runtime
# dir, a systemctl that records and refuses "is-active", a cargo that must
# never run, and a fake prebuilt tarball. Nothing on the real machine is
# touched. Run by tools/run-tests.sh; standalone: tools/install-check.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/run"
printf '#!/bin/sh\necho "systemctl $*" >> "%s/systemctl.log"\ncase "$*" in *is-active*) exit 1;; esac\nexit 0\n' "$sandbox" > "$sandbox/bin/systemctl"
chmod +x "$sandbox/bin/systemctl"
# A toolbox PATH with the tools the script needs and NO cargo, so the
# no-toolchain branches are real; one case adds a cargo that must not run.
mkdir -p "$sandbox/toolbox" "$sandbox/withcargo"
for tool in bash sh tar sed grep find install ln mkdir readlink dirname basename uname head mktemp rm cat cmp printf cut sort seq sleep timeout gzip tr; do
  path=$(command -v "$tool" 2>/dev/null) && ln -s "$path" "$sandbox/toolbox/$tool"
done
printf '#!/bin/sh\necho "cargo must not run" >&2; exit 99\n' > "$sandbox/withcargo/cargo"; chmod +x "$sandbox/withcargo/cargo"
# A prebuilt tarball with the release's layout and a stand-in binary.
stage="$sandbox/oskar-daemon-0.0.0-$(uname -m)"
mkdir -p "$stage"
printf '#!/bin/sh\nexit 0\n' > "$stage/oskar-daemon"; chmod +x "$stage/oskar-daemon"
command cp "$root/systemd/oskar.service" "$stage/oskar.service"; command cp "$root/bin/oskar" "$stage/oskar"
tarball="$sandbox/oskar-daemon-0.0.0-$(uname -m).tar.gz"
tar -czf "$tarball" -C "$sandbox" "$(basename "$stage")"
version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/manifest.json" | head -1)
matching="$sandbox/oskar-daemon-$version-$(uname -m).tar.gz"; command cp "$tarball" "$matching"

home="$sandbox/home"
unit="$home/.config/systemd/user/oskar.service"
cli="$home/.local/bin/oskar"
helper="$home/.local/libexec/oskar-daemon"
run() { HOME="$home" XDG_RUNTIME_DIR="$sandbox/run" PATH="$sandbox/bin:$sandbox/toolbox" bash "$root/install.sh" "$@" >"$sandbox/out" 2>&1; echo $?; }
run_with_cargo() { HOME="$home" XDG_RUNTIME_DIR="$sandbox/run" PATH="$sandbox/bin:$sandbox/withcargo:$sandbox/toolbox" bash "$root/install.sh" "$@" >"$sandbox/out" 2>&1; echo $?; }
reset() { rm -rf "$home"; mkdir -p "$home"; : > "$sandbox/systemctl.log"; }
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; echo "      output: $(tr '\n' '|' < "$sandbox/out" | cut -c1-300)"; fail=1; fi; }

reset; check "fresh home: prebuilt install succeeds" "$(run --prebuilt "$matching")" 0
check "fresh home: the helper is the tarball's" "$(cmp -s "$stage/oskar-daemon" "$helper" && echo same)" same
check "fresh home: the command points at this checkout" "$(readlink -f "$cli")" "$(readlink -f "$root/bin/oskar")"
check "fresh home: the unit is ours" "$(grep -c oskar-daemon "$unit")" 1
check "fresh home: the unit was reloaded and enabled" "$(grep -c 'daemon-reload\|enable oskar.service' "$sandbox/systemctl.log")" 2
check "rerun over our own files succeeds" "$(run --prebuilt "$matching")" 0
check "no cargo, no tarball, helper present: kept, exit 0" "$(run)" 0
check "  and it said so" "$(grep -c 'keeping the installed helper' "$sandbox/out")" 1
check "a tarball beside install.sh is picked up" "$( command cp "$matching" "$root/" && r=$(run); rm -f "$root/$(basename "$matching")"; echo "$r")" 0
check "  via the prebuilt path" "$(grep -c 'Installing the prebuilt helper' "$sandbox/out")" 1
check "version mismatch warns, still installs" "$(run --prebuilt "$tarball")" 0
check "  the warning names the plugin version" "$(grep -c "not built for plugin version $version" "$sandbox/out")" 1
reset; check "no cargo, no tarball, no helper: exit 1 with the hint" "$(run)" 1
check "  the hint names both ways" "$(grep -c 'omarchy pkg add rust\|--prebuilt' "$sandbox/out")" 2
reset; mkdir -p "$home/.local/bin"; printf '#!/bin/sh\n' > "$cli"
check "a command that is not OSKar's: refused, exit 3" "$(run --prebuilt "$matching")" 3
check "  nothing written" "$([[ -e "$unit" || -e "$helper" ]] && echo written || echo untouched)" untouched
check "  the message names the file" "$(grep -c "$cli is not an OSKar command" "$sandbox/out")" 1
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"
check "a unit that is not OSKar's: refused, exit 3" "$(run --prebuilt "$matching")" 3
check "  the foreign unit survives" "$(grep -c something-else "$unit")" 1
check "--force replaces it" "$(run --prebuilt "$matching" --force)" 0
check "  and the unit is ours now" "$(grep -c oskar-daemon "$unit")" 1
reset; other="$sandbox/other"; mkdir -p "$other/bin" "$home/.local/bin"; command cp "$root/manifest.json" "$other/"; command cp "$root/bin/oskar" "$other/bin/"; ln -s "$other/bin/oskar" "$cli"
check "another OSKar checkout's command is taken over" "$(run --prebuilt "$matching")" 0
check "  and now points here" "$(readlink -f "$cli")" "$(readlink -f "$root/bin/oskar")"
reset; echo x > "$sandbox/x"; tar -czf "$sandbox/empty.tar.gz" -C "$sandbox" x
check "a tarball without the helper: exit 1" "$(run --prebuilt "$sandbox/empty.tar.gz")" 1
check "a missing tarball: exit 2" "$(run --prebuilt "$sandbox/nope.tar.gz")" 2
check "an unknown flag: exit 2" "$(run --bogus)" 2
reset; check "with cargo and no tarball the build runs (here: the stub refuses, 99)" "$(run_with_cargo)" 99
reset; check "with cargo, a tarball still wins over the build" "$(run_with_cargo --prebuilt "$matching")" 0
check "  and cargo never ran" "$(grep -c 'cargo must not run' "$sandbox/out")" 0
exit "$fail"
