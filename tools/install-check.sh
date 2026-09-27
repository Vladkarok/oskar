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
for tool in bash sh tar sed grep find install ln mkdir readlink dirname basename uname head mktemp rm cat cmp printf cut sort seq sleep timeout gzip tr mv date realpath pwd ldconfig; do
  path=$(command -v "$tool" 2>/dev/null) && ln -s "$path" "$sandbox/toolbox/$tool"
done
printf '#!/bin/sh\necho "cargo must not run" >&2; exit 99\n' > "$sandbox/withcargo/cargo"; chmod +x "$sandbox/withcargo/cargo"
# A prebuilt tarball with the release's layout and a stand-in binary.
stage="$sandbox/oskar-daemon-0.0.0-$(uname -m)"
mkdir -p "$stage"
printf '#!/bin/sh\n# oskar-daemon: stand-in for the sandbox\nexit 0\n' > "$stage/oskar-daemon"; chmod +x "$stage/oskar-daemon"
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
check "  the message names the file" "$(grep -c "^  $cli\$" "$sandbox/out")" 1
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"
check "a unit that is not OSKar's: refused, exit 3" "$(run --prebuilt "$matching")" 3
check "  the foreign unit survives" "$(grep -c something-else "$unit")" 1
check "--force installs" "$(run --prebuilt "$matching" --force)" 0
check "  the unit is ours now" "$(grep -c oskar-daemon "$unit")" 1
check "  and the foreign unit was moved aside, not destroyed" "$(grep -l something-else "$unit".replaced-* 2>/dev/null | wc -l)" 1
reset; mkdir -p "$(dirname "$helper")"; printf 'someone elses program\n' > "$helper"
check "a helper that is not OSKar's: refused, exit 3" "$(run --prebuilt "$matching")" 3
check "  the foreign helper is untouched" "$(cat "$helper")" "someone elses program"
check "  and neither unit nor command was written" "$([[ -e "$unit" || -e "$cli" || -L "$cli" ]] && echo written || echo untouched)" untouched
check "--force over a foreign helper installs" "$(run --prebuilt "$matching" --force)" 0
check "  the helper is the tarball's" "$(cmp -s "$stage/oskar-daemon" "$helper" && echo same)" same
check "  and the foreign helper was moved aside" "$(grep -l 'someone elses program' "$helper".replaced-* 2>/dev/null | wc -l)" 1
reset; mkdir -p "$home/.local/bin"; ln -s "$sandbox/gone/bin/oskar" "$cli"
check "a dangling link to a vanished checkout's bin/oskar is replaced" "$(run --prebuilt "$matching")" 0
reset; mkdir -p "$home/.local/bin"; ln -s /usr/bin/env "$cli"
check "a symlink to something else is not ours: exit 3" "$(run --prebuilt "$matching")" 3
check "  and it still points where it did" "$(readlink "$cli")" /usr/bin/env
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

# ---- uninstall.sh: what it removes it has proven ----
unrun() { HOME="$home" XDG_RUNTIME_DIR="$sandbox/run" PATH="$sandbox/bin:$sandbox/toolbox" bash "$root/uninstall.sh" >"$sandbox/out" 2>&1; echo $?; }
reset; run --prebuilt "$matching" >/dev/null
check "uninstall after an install succeeds" "$(unrun)" 0
check "  the trio is gone" "$([[ -e "$unit" || -e "$helper" || -L "$cli" ]] && echo left || echo gone)" gone
reset; run --prebuilt "$matching" >/dev/null; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"; printf 'someone elses program\n' > "$helper"
check "uninstall with a unit and helper replaced by someone else since" "$(unrun)" 0
check "  leaves their unit" "$(grep -c something-else "$unit")" 1
check "  leaves their helper" "$(cat "$helper")" "someone elses program"
check "  and removes only our command" "$([[ -L "$cli" ]] && echo left || echo gone)" gone

# ---- the lifecycle command's migration: nothing foreign is deleted ----
printf '#!/bin/sh\nexit 0\n' > "$sandbox/bin/omarchy"; printf '#!/bin/sh\nexit 0\n' > "$sandbox/bin/omarchy-shell"; chmod +x "$sandbox/bin/omarchy" "$sandbox/bin/omarchy-shell"
oskar() { HOME="$home" XDG_RUNTIME_DIR="$sandbox/run" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" PATH="$sandbox/bin:$sandbox/toolbox" bash "$root/bin/oskar" "$@" >"$sandbox/out" 2>&1; echo $?; }
old_helper="$home/.local/libexec/omarchy-osk-daemon"; old_shadow="$home/.local/bin/omarchy-osk"; old_unit="$home/.config/systemd/user/omarchy-osk.service"; old_run="$sandbox/run/omarchy-osk"
reset; rm -rf "$old_run"; mkdir -p "$(dirname "$old_helper")" "$(dirname "$old_shadow")" "$(dirname "$old_unit")" "$old_run"
printf 'omarchy-osk-daemon: the old helper\n' > "$old_helper"; ln -s "$sandbox/gone/bin/omarchy-osk" "$old_shadow"
printf '[Service]\nExecStart=%%h/.local/libexec/omarchy-osk-daemon\n' > "$old_unit"; : > "$old_run/keymap.xkb"
check "teardown walks a genuine old install" "$(oskar teardown)" 0
check "  the old helper is removed" "$([[ -e "$old_helper" ]] && echo left || echo gone)" gone
check "  the old command is removed" "$([[ -L "$old_shadow" ]] && echo left || echo gone)" gone
check "  the old unit is moved aside, kept" "$(ls "$old_unit".migrated-* 2>/dev/null | wc -l)" 1
reset; rm -rf "$old_run"; mkdir -p "$(dirname "$old_helper")" "$(dirname "$old_shadow")" "$(dirname "$old_unit")" "$old_run"
printf 'someone elses program\n' > "$old_helper"; ln -s /usr/bin/env "$old_shadow"
printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$old_unit"; : > "$old_run/their-file"
check "teardown over same-named files that are not ours" "$(oskar teardown)" 0
check "  their helper is kept (moved aside)" "$(grep -l 'someone elses program' "$old_helper".migrated-* 2>/dev/null | wc -l)" 1
check "  their command is left" "$(readlink "$old_shadow")" /usr/bin/env
check "  their unit is left" "$(grep -c something-else "$old_unit")" 1
check "  the wants link and registration steps did not fail the walk" "$(grep -c 'teardown complete' "$sandbox/out")" 1
HOME="$home" XDG_RUNTIME_DIR="$sandbox/run" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" PATH="$sandbox/bin:$sandbox/toolbox" bash "$root/bin/oskar" upgrade >"$sandbox/out" 2>&1 || true
check "the full migration leaves a runtime dir with foreign files" "$([[ -e "$old_run/their-file" ]] && echo kept || echo deleted)" kept

# ---- the predicates themselves ----
owns() { PATH="$sandbox/toolbox" bash "$root/bin/oskar" owns "$1" "$2" >/dev/null 2>&1 && echo ours || echo foreign; }
check "owns helper: the real marker" "$(owns helper "$stage/oskar-daemon")" ours
check "owns helper: an unrelated binary" "$(owns helper "$(command -v tar)")" foreign
check "owns helper: a symlink to a real helper is not a helper file" "$(ln -sf "$stage/oskar-daemon" "$sandbox/hl"; owns helper "$sandbox/hl")" foreign
check "owns unit: ours" "$(owns unit "$root/systemd/oskar.service")" ours
check "owns unit: a comment naming oskar-daemon is not proof" "$(printf '# oskar-daemon\n[Service]\nExecStart=/bin/true\n' > "$sandbox/u"; owns unit "$sandbox/u")" foreign
check "owns cli: a regular file named oskar" "$(printf 'x' > "$sandbox/oskar"; owns cli "$sandbox/oskar")" foreign
exit "$fail"
