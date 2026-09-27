#!/usr/bin/env bash
# The install record's rule, in a sandbox: install.sh, uninstall.sh and
# bin/oskar run with a private HOME, XDG_RUNTIME_DIR, XDG_STATE_HOME and
# XDG_CONFIG_HOME, an otherwise empty environment, stubs first on PATH (a
# systemctl that logs every call, omarchy, omarchy-shell and the tools
# setup's preflight probes), a toolbox PATH without cargo, and a fake
# prebuilt tarball whose stand-in helper carries no marker of any kind.
# Nothing on the real machine is touched. Run by tools/run-tests.sh;
# standalone: tools/install-check.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
home="$sandbox/home"
unit="$home/.config/systemd/user/oskar.service"
cli="$home/.local/bin/oskar"
helper="$home/.local/libexec/oskar-daemon"
record_file="$home/.local/state/oskar/install-record"
reg="$home/.config/omarchy/plugins/io.github.vladkarok.oskar"
mkdir -p "$sandbox/bin" "$sandbox/run" "$sandbox/toolbox" "$sandbox/withcargo" "$sandbox/datestub"

# systemctl: every call logged; is-active answers $STUB_ACTIVE (1: no
# session); FragmentPath is the user unit when one exists, like systemd,
# unless $STUB_FRAGMENT names another file.
cat > "$sandbox/bin/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$sandbox/systemctl.log"
case "\$*" in
  *"show -p FragmentPath"*)
    if [ "\$STUB_FRAGMENT" != auto ]; then echo "\$STUB_FRAGMENT"
    elif [ -e "\$HOME/.config/systemd/user/oskar.service" ]; then echo "\$HOME/.config/systemd/user/oskar.service"
    else echo; fi
    exit 0 ;;
  *is-active*) exit "\$STUB_ACTIVE" ;;
esac
exit 0
EOF
for stub in omarchy omarchy-shell; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/omarchy.log"\nexit 0\n' "$stub" "$sandbox" > "$sandbox/bin/$stub"
done
for stub in hyprctl jq wl-copy wl-paste; do printf '#!/bin/sh\nexit 0\n' > "$sandbox/bin/$stub"; done
printf '#!/bin/sh\necho "\tlibxkbcommon.so.0 (libc6,x86-64) => /usr/lib/libxkbcommon.so.0"\n' > "$sandbox/bin/ldconfig"
chmod +x "$sandbox"/bin/*
for tool in bash sh tar sed grep find install ln mkdir readlink dirname basename uname head mktemp rm cat cmp printf cut sort seq sleep timeout gzip tr mv date realpath pwd sha256sum chmod; do
  path=$(command -v "$tool" 2>/dev/null) && ln -s "$path" "$sandbox/toolbox/$tool"
done
printf '#!/bin/sh\necho "cargo must not run" >&2; exit 99\n' > "$sandbox/withcargo/cargo"; chmod +x "$sandbox/withcargo/cargo"
printf '#!/bin/sh\necho 20260101-000000\n' > "$sandbox/datestub/date"; chmod +x "$sandbox/datestub/date"

# A prebuilt tarball with the release's layout; its helper is a plain
# script that says nothing about what it is.
stage="$sandbox/oskar-daemon-0.0.0-$(uname -m)"
mkdir -p "$stage"
printf '#!/bin/sh\nexit 0\n' > "$stage/oskar-daemon"; chmod +x "$stage/oskar-daemon"
command cp "$root/systemd/oskar.service" "$stage/oskar.service"; command cp "$root/bin/oskar" "$stage/oskar"
tarball="$sandbox/oskar-daemon-0.0.0-$(uname -m).tar.gz"
tar -czf "$tarball" -C "$sandbox" "$(basename "$stage")"
version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/manifest.json" | head -1)
matching="$sandbox/oskar-daemon-$version-$(uname -m).tar.gz"; command cp "$tarball" "$matching"

tpath="$sandbox/bin:$sandbox/toolbox"
sbx() {
  env -i HOME="$home" XDG_RUNTIME_DIR="$sandbox/run" XDG_STATE_HOME="$home/.local/state" \
    XDG_CONFIG_HOME="$home/.config" PATH="$tpath" STUB_ACTIVE="${STUB_ACTIVE:-1}" \
    STUB_FRAGMENT="${STUB_FRAGMENT:-auto}" "$@"
}
run() { sbx bash "${installer:-$root/install.sh}" "$@" >"$sandbox/out" 2>&1; echo $?; }
unrun() { sbx bash "$root/uninstall.sh" >"$sandbox/out" 2>&1; echo $?; }
oskar() { sbx bash "$root/bin/oskar" "$@" >"$sandbox/out" 2>&1; echo $?; }
rec() { sbx bash "$root/bin/oskar" record "$@" >/dev/null 2>&1; echo $?; }
sum() { sha256sum < "$1" | cut -c1-64; }
asides() { command ls -d "$1".replaced-* 2>/dev/null | wc -l; }
calls() { grep -c -E "$1" "$sandbox/systemctl.log"; }
written() { [[ -e "$unit" || -e "$helper" || -L "$cli" || -e "$record_file" ]] && echo written || echo untouched; }
reset() { rm -rf "$home" "$sandbox/run"; mkdir -p "$home" "$sandbox/run"; : > "$sandbox/systemctl.log"; : > "$sandbox/omarchy.log"; }
passed=0; failed=0
check() {
  if [[ "$2" == "$3" ]]; then echo "ok    $1"; passed=$((passed + 1))
  else echo "FAIL  $1: expected '$3', got '$2'"; echo "      output: $(tr '\n' '|' < "$sandbox/out" | cut -c1-300)"; failed=$((failed + 1)); fi
}

# ---- the record's primitive: matches ----
reset; mkdir -p "$sandbox/r"; printf 'one\n' > "$sandbox/r/f"; ln -sfn /x/one "$sandbox/r/l"
check "record write: a file and a link" "$(rec write "$sandbox/r/f" "$sandbox/r/l")" 0
check "matches: a recorded, unmodified file" "$(rec matches "$sandbox/r/f")" 0
check "  the same path spelled with a doubled slash" "$(rec matches "$sandbox//r/f")" 0
check "  the record is private (0600)" "$(stat -c %a "$record_file")" 600
check "matches: a recorded, unmodified link" "$(rec matches "$sandbox/r/l")" 0
printf 'onE\n' > "$sandbox/r/f"
check "matches: the same file with one byte changed" "$(rec matches "$sandbox/r/f")" 1
printf 'x\n' > "$sandbox/r/other"
check "matches: an unrecorded file" "$(rec matches "$sandbox/r/other")" 1
ln -sfn /x/two "$sandbox/r/l"
check "matches: a recorded link whose text changed" "$(rec matches "$sandbox/r/l")" 1
rm -f "$sandbox/r/f"; mkdir "$sandbox/r/f"
check "matches: a recorded path that is now a directory" "$(rec matches "$sandbox/r/f")" 1
check "write: a directory cannot be recorded" "$(rec write "$sandbox/r/f")" 1
check "matches: a relative path" "$(cd "$sandbox" && rec matches r/other)" 1
check "matches: no path at all" "$(rec matches)" 1
check "forget: one path" "$(rec forget "$sandbox/r/f")" 0
check "  the other line stays" "$(grep -c "$sandbox/r/l" "$record_file")" 1
check "forget: the last path removes the record" "$(rec forget "$sandbox/r/l" >/dev/null; [[ -e "$record_file" ]] && echo kept || echo gone)" gone

# ---- install.sh: fresh, rerun, the no-toolchain branches ----
reset; check "fresh home: prebuilt install succeeds" "$(run --prebuilt "$matching")" 0
check "  the helper is the tarball's" "$(cmp -s "$stage/oskar-daemon" "$helper" && echo same)" same
check "  the unit is the checkout's" "$(cmp -s "$root/systemd/oskar.service" "$unit" && echo same)" same
check "  the command points at this checkout" "$(readlink -f "$cli")" "$(readlink -f "$root/bin/oskar")"
check "  the record lists the three paths" "$(wc -l < "$record_file")" 3
check "  each matches it" "$(rec matches "$unit")$(rec matches "$helper")$(rec matches "$cli")" 000
check "  the unit was reloaded and enabled" "$(calls 'daemon-reload|enable oskar.service')" 2
check "  and systemd was asked which unit it resolves" "$(calls 'show -p FragmentPath --value oskar.service')" 1
check "rerun over our own unmodified files succeeds, no --force" "$(run --prebuilt "$matching")" 0
check "  and moved nothing aside" "$(( $(asides "$unit") + $(asides "$helper") + $(asides "$cli") ))" 0
check "no cargo, no tarball, our helper: kept, exit 0" "$(run)" 0
check "  and it said so" "$(grep -c 'keeping the installed helper' "$sandbox/out")" 1
check "a tarball beside install.sh is picked up" "$( command cp "$matching" "$root/" && r=$(run); rm -f "$root/$(basename "$matching")"; echo "$r")" 0
check "  via the prebuilt path" "$(grep -c 'Installing the prebuilt helper' "$sandbox/out")" 1
check "version mismatch warns, still installs" "$(run --prebuilt "$tarball")" 0
check "  the warning names the plugin version" "$(grep -c "not built for plugin version $version" "$sandbox/out")" 1
reset; check "no cargo, no tarball, no helper: exit 1 with the hint" "$(run)" 1
check "  the hint names both ways" "$(grep -c 'omarchy pkg add rust\|--prebuilt' "$sandbox/out")" 2
check "  nothing written" "$(written)" untouched
reset; echo x > "$sandbox/x"; tar -czf "$sandbox/empty.tar.gz" -C "$sandbox" x
check "a tarball without the helper: exit 1" "$(run --prebuilt "$sandbox/empty.tar.gz")" 1
check "  nothing written" "$(written)" untouched
check "a missing tarball: exit 2" "$(run --prebuilt "$sandbox/nope.tar.gz")" 2
check "an unknown flag: exit 2" "$(run --bogus)" 2
reset; check "with cargo and no tarball the build runs (here: the stub refuses, 99)" "$(tpath="$sandbox/bin:$sandbox/withcargo:$sandbox/toolbox" run)" 99
check "  a failed build writes nothing" "$(written)" untouched
reset; check "with cargo, a tarball still wins over the build" "$(tpath="$sandbox/bin:$sandbox/withcargo:$sandbox/toolbox" run --prebuilt "$matching")" 0
check "  and cargo never ran" "$(grep -c 'cargo must not run' "$sandbox/out")" 0

# ---- each destination foreign: refused, untouched; --force moves it aside ----
foreign_case() { # <name> <path> <maker>
  local name="$1" path="$2" maker="$3" before
  reset; mkdir -p "$(dirname "$path")"; eval "$maker"; before="$(sum "$path" 2>/dev/null || readlink "$path")"
  check "foreign $name: refused, exit 3" "$(run --prebuilt "$matching")" 3
  check "  the message names it" "$(grep -c "^  $path\$" "$sandbox/out")" 1
  check "  and says --force deletes nothing" "$(grep -c 'deletes nothing' "$sandbox/out")" 1
  check "  it is byte-identical" "$(sum "$path" 2>/dev/null || readlink "$path")" "$before"
  check "  nothing else was written" "$(for p in "$unit" "$helper" "$cli" "$record_file"; do [[ "$p" == "$path" ]] && continue; [[ -e "$p" || -L "$p" ]] && echo "$p"; done | wc -l)" 0
  check "  and systemd was not called" "$(wc -l < "$sandbox/systemctl.log")" 0
  check "foreign $name with --force: installs" "$(run --prebuilt "$matching" --force)" 0
  check "  it was moved aside with its content" "$(for a in "$path".replaced-*; do sum "$a" 2>/dev/null || readlink "$a"; done)" "$before"
  check "  and the destination is recorded as ours" "$(rec matches "$path")" 0
}
foreign_case unit "$unit" 'printf "[Service]\nExecStart=/usr/bin/something-else\n" > "$unit"'
foreign_case helper "$helper" 'printf "someone elses program\n" > "$helper"'
foreign_case command "$cli" 'printf "#!/bin/sh\n" > "$cli"'
foreign_case "command link elsewhere" "$cli" 'ln -s /usr/bin/env "$cli"'
foreign_case "dangling command link" "$cli" 'ln -s "$sandbox/gone/bin/oskar" "$cli"'

# ---- content proves nothing: the old predicates' false positives ----
reset; mkdir -p "$(dirname "$helper")"; printf 'not a helper\noskar-daemon: looks like one\n' > "$helper"
check "a helper-named file carrying 'oskar-daemon: ': refused" "$(run --prebuilt "$matching")" 3
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=%%h/.local/libexec/oskar-daemon --theirs\n' > "$unit"
check "a unit whose ExecStart runs an oskar-daemon: refused" "$(run --prebuilt "$matching")" 3
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/opt/foskar-daemon\n' > "$unit"
check "a foskar-daemon unit: refused" "$(run --prebuilt "$matching")" 3
reset; mkdir -p "$(dirname "$unit")"; command cp "$root/systemd/oskar.service" "$unit"
check "a byte-exact copy of our unit with no record line: refused" "$(run --prebuilt "$matching")" 3
check "  the refusal names the older-version case" "$(grep -c 'older than its install record' "$sandbox/out")" 1

# ---- a unit the user edited after install ----
reset; run --prebuilt "$matching" >/dev/null; printf '# my tweak\n' >> "$unit"
check "an edited unit: refused without --force" "$(run --prebuilt "$matching")" 3
check "  the edit survives" "$(grep -c '# my tweak' "$unit")" 1
check "an edited unit with --force: installs" "$(run --prebuilt "$matching" --force)" 0
check "  the edited copy is kept aside" "$(grep -l '# my tweak' "$unit".replaced-* 2>/dev/null | wc -l)" 1
check "  the unit is the checkout's again" "$(cmp -s "$root/systemd/oskar.service" "$unit" && echo same)" same

# ---- --force never moves anything before a helper is in hand ----
reset; mkdir -p "$(dirname "$helper")" "$(dirname "$unit")"; printf 'someone elses program\n' > "$helper"; printf 'theirs\n' > "$unit"
check "--force, no cargo, no tarball, foreign helper: exit 1" "$(run --force)" 1
check "  the foreign helper is untouched" "$(cat "$helper")" "someone elses program"
check "  the foreign unit is untouched" "$(cat "$unit")" "theirs"
check "  nothing moved aside" "$(( $(asides "$unit") + $(asides "$helper") ))" 0
check "  no command, no record" "$([[ -L "$cli" || -e "$record_file" ]] && echo written || echo untouched)" untouched

# ---- move-aside never lands on an existing name ----
reset; mkdir -p "$(dirname "$unit")"; printf 'theirs\n' > "$unit"
printf 'an older aside\n' > "$unit.replaced-20260101-000000"; mkdir "$unit.replaced-20260101-000000.1"
check "aside collision: --force installs" "$(tpath="$sandbox/datestub:$sandbox/bin:$sandbox/toolbox" run --prebuilt "$matching" --force)" 0
check "  the earlier aside of the same second survives" "$(cat "$unit.replaced-20260101-000000")" "an older aside"
check "  so does the directory after it" "$([[ -d "$unit.replaced-20260101-000000.1" ]] && echo kept)" kept
check "  the new aside has a name of its own" "$(cat "$unit.replaced-20260101-000000.2")" theirs

# ---- links: foreign unless recorded ----
reset; mkdir -p "$home/.local/bin"; ln -s "$sandbox/gone/bin/oskar" "$cli"; rec write "$cli" >/dev/null
check "a recorded dangling command link (its checkout is gone) is replaced" "$(run --prebuilt "$matching")" 0
check "  and now points here" "$(readlink -f "$cli")" "$(readlink -f "$root/bin/oskar")"

# ---- another checkout's install is taken over through the shared record ----
reset; other="$sandbox/other"; rm -rf "$other"; mkdir -p "$other"
command cp -r "$root/bin" "$root/systemd" "$root/install.sh" "$root/manifest.json" "$other/"
check "another checkout installs" "$(installer="$other/install.sh" run --prebuilt "$matching")" 0
check "  its command points there" "$(readlink -f "$cli")" "$(readlink -f "$other/bin/oskar")"
check "this checkout takes it over without --force" "$(run --prebuilt "$matching")" 0
check "  the command points here" "$(readlink -f "$cli")" "$(readlink -f "$root/bin/oskar")"
check "  nothing was moved aside" "$(( $(asides "$unit") + $(asides "$helper") + $(asides "$cli") ))" 0
check "  the record follows" "$(rec matches "$cli")" 0

# ---- uninstall.sh removes exactly what the record proves ----
reset; run --prebuilt "$matching" >/dev/null
check "uninstall after an install succeeds" "$(unrun)" 0
check "  the three are gone" "$([[ -e "$unit" || -e "$helper" || -L "$cli" ]] && echo left || echo gone)" gone
check "  and the record with them" "$([[ -e "$record_file" ]] && echo left || echo gone)" gone
reset; run --prebuilt "$matching" >/dev/null; printf '# my tweak\n' >> "$unit"; printf 'someone elses program\n' > "$helper"
check "uninstall with an edited unit and a replaced helper" "$(unrun)" 0
check "  the edited unit stays" "$(grep -c '# my tweak' "$unit")" 1
check "  the replaced helper stays" "$(cat "$helper")" "someone elses program"
check "  the command, ours, is gone" "$([[ -L "$cli" ]] && echo left || echo gone)" gone
check "  the record forgot only the command" "$(grep -c -F "$cli" "$record_file"; wc -l < "$record_file")" "$(printf '0\n2')"
check "  it names what it left" "$(grep -c 'left in place' "$sandbox/out")" 2

# ---- bin/oskar switches on or off only the unit that is OSKar's ----
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"
check "teardown (source mode) with a foreign oskar.service" "$(oskar teardown)" 0
check "  systemd was never told to disable or stop it" "$(calls '(disable|stop|restart|enable).*oskar.service')" 0
check "  and teardown says why" "$(grep -c 'OSKar did not install' "$sandbox/out")" 1
check "  the foreign unit is byte-identical" "$(grep -c something-else "$unit")" 1
reset; run --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "teardown with our recorded unit" "$(oskar teardown)" 0
check "  disables it" "$(calls 'disable --now oskar.service')" 1
reset; run --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "teardown when systemd resolves another file" "$(STUB_FRAGMENT=/etc/systemd/user/oskar.service oskar teardown)" 0
check "  leaves it alone" "$(calls '(disable|stop).*oskar.service')" 0

reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"
check "setup with a foreign unit present: dies" "$(oskar setup --prebuilt "$matching")" 1
check "  naming the unit and the way out" "$(grep -c -F "  $unit" "$sandbox/out")$(grep -c 'nothing was activated' "$sandbox/out")" 11
check "  no enable, start or restart of oskar.service" "$(calls '(enable|start|restart).*oskar.service')" 0
check "  nothing registered" "$([[ -e "$reg" || -L "$reg" ]] && echo registered || echo none)" none
reset
check "setup when systemd resolves an /etc unit over ours: dies" "$(STUB_FRAGMENT=/etc/systemd/user/oskar.service oskar setup --prebuilt "$matching")" 1
check "  no enable, start or restart of oskar.service" "$(calls '(enable|start|restart).*oskar.service')" 0
reset
check "setup in a live session with our unit" "$(STUB_ACTIVE=0 oskar setup --prebuilt "$matching")" 0
check "  enables and restarts it" "$(calls '^systemctl --user (enable|restart) oskar.service')" 4

# ---- nothing named omarchy-osk is ever touched ----
reset
theirs=("$home/.config/omarchy-osk/settings" "$home/.local/state/omarchy-osk/db" "$sandbox/run/omarchy-osk/their-file"
  "$home/.config/systemd/user/omarchy-osk.service" "$home/.local/libexec/omarchy-osk-daemon")
for f in "${theirs[@]}"; do mkdir -p "$(dirname "$f")"; printf 'theirs: %s\n' "$f" > "$f"; done
printf '[Service]\nExecStart=%%h/.local/libexec/omarchy-osk-daemon\n' > "$home/.config/systemd/user/omarchy-osk.service"
before="$(for f in "${theirs[@]}"; do sum "$f"; done)"
check "omarchy-osk world: setup" "$(STUB_ACTIVE=0 oskar setup --prebuilt "$matching")" 0
check "omarchy-osk world: upgrade" "$(STUB_ACTIVE=0 oskar upgrade --prebuilt "$matching")" 0
check "omarchy-osk world: teardown" "$(oskar teardown)" 0
check "  every omarchy-osk file is byte-identical" "$(for f in "${theirs[@]}"; do sum "$f"; done)" "$before"
check "  and nothing was moved aside beside them" "$(command ls -d "$home"/.config/omarchy-osk* "$home"/.local/state/omarchy-osk* "$sandbox"/run/omarchy-osk* "$home"/.config/systemd/user/omarchy-osk* "$home"/.local/libexec/omarchy-osk* | wc -l)" 5
check "  systemctl never named it" "$(calls 'omarchy-osk')" 0
check "  nor did the shell calls" "$(grep -c -E 'omarchy-osk|vladkarok\.osk( |$)' "$sandbox/omarchy.log")" 0

echo "install-check: $passed passed, $failed failed"
((failed == 0))
