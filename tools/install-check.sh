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

# systemctl: every call logged (per case, and for the whole run);
# is-active answers $STUB_ACTIVE (1: no session). FragmentPath is, like
# systemd's search order: $STUB_FRAGMENT when set (a higher-priority
# override), else the user unit when one exists, else $STUB_SYSTEM_UNIT
# (a lower-priority oskar.service, e.g. /usr/lib's). enable links the
# resolved file into graphical-session.target.wants and, like systemd,
# refuses to replace a link there that points elsewhere; disable removes
# every oskar.service link by name.
cat > "$sandbox/bin/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$sandbox/systemctl.log"
echo "systemctl \$*" >> "$sandbox/systemctl.all.log"
frag() {
  if [ "\$STUB_FRAGMENT" != auto ]; then echo "\$STUB_FRAGMENT"
  elif [ -e "\$HOME/.config/systemd/user/oskar.service" ]; then echo "\$HOME/.config/systemd/user/oskar.service"
  else echo "\$STUB_SYSTEM_UNIT"; fi
}
case "\$*" in
  *"show -p FragmentPath"*) frag; exit 0 ;;
  "--user enable oskar.service")
    f=\$(frag); [ -n "\$f" ] || exit 1
    w="\$HOME/.config/systemd/user/graphical-session.target.wants"; mkdir -p "\$w"
    if [ -L "\$w/oskar.service" ]; then
      [ "\$(readlink "\$w/oskar.service")" = "\$f" ] && exit 0
      echo "Failed to enable unit: File \$w/oskar.service already exists and is a symlink to \$(readlink "\$w/oskar.service")." >&2; exit 1
    fi
    ln -s "\$f" "\$w/oskar.service"; exit 0 ;;
  *disable*oskar.service*)
    # By name, as systemd does: every oskar.service enablement link goes,
    # whatever unit file it points at.
    rm -f "\$HOME"/.config/systemd/user/*.wants/oskar.service "\$HOME"/.config/systemd/user/*.requires/oskar.service
    exit 0 ;;
  *is-enabled*) echo enabled; exit 0 ;;
  *is-active*) if [ "\$STUB_ACTIVE" = 0 ]; then echo active; else echo inactive; fi; exit "\$STUB_ACTIVE" ;;
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
mkdir -p "$sandbox/nosha"
for t in "$sandbox"/toolbox/*; do [[ "$(basename "$t")" == sha256sum ]] || ln -s "$(readlink "$t")" "$sandbox/nosha/$(basename "$t")"; done

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
    ${state_home_override:+XDG_STATE_HOME="$state_home_override"} \
    STUB_FRAGMENT="${STUB_FRAGMENT:-auto}" STUB_SYSTEM_UNIT="${STUB_SYSTEM_UNIT:-}" "$@"
}
run() { sbx bash "${installer:-$root/install.sh}" "$@" >"$sandbox/out" 2>&1; echo $?; }
unrun() { sbx bash "$root/uninstall.sh" >"$sandbox/out" 2>&1; echo $?; }
oskar() { sbx bash "$root/bin/oskar" "$@" >"$sandbox/out" 2>&1; echo $?; }
rec() { sbx bash "$root/bin/oskar" record "$@" >/dev/null 2>&1; echo $?; }
sum() { sha256sum < "$1" | cut -c1-64; }
wants="$home/.config/systemd/user/graphical-session.target.wants/oskar.service"
theirs_link="$home/.config/systemd/user/default.target.wants/oskar.service"
# Another program's oskar.service, enabled before OSKar came.
foreign_enabled() { mkdir -p "$(dirname "$theirs_link")"; ln -sfn "$home/.local/share/systemd/user/oskar.service" "$theirs_link"; }
link_is() { if [[ -L "$1" ]]; then readlink "$1"; else echo none; fi; }
# What a path is, without following a link: "link:<text>" or "file:<sha256>".
what() { if [[ -L "$1" ]]; then echo "link:$(readlink "$1")"; else echo "file:$(sum "$1")"; fi; }
anyaside() { find "$home" "$sandbox/run" \( -name '*.replaced-*' -o -name '*.migrated-*' \) 2>/dev/null | wc -l; }
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
printf 'rel\n' > "$sandbox/r/rel"; rec write "$sandbox/r/rel" >/dev/null
check "matches: a recorded file, by its absolute path" "$(rec matches "$sandbox/r/rel")" 0
check "matches: the same recorded file by a relative spelling" "$(cd "$sandbox" && rec matches r/rel)" 1
check "write: a path containing a tab is refused" "$(printf 'x\n' > "$sandbox/r/a$(printf '\t')b"; rec write "$sandbox/r/a$(printf '\t')b")" 1
check "  and not recorded" "$(grep -c 'a.b$' "$record_file")" 0
check "aside: an invalid word is refused" "$(rec aside "$sandbox/r/other" 'Bad-word')" 1
check "  and the file did not move" "$(cat "$sandbox/r/other")" x
check "usable: a normal home" "$(rec usable)" 0
check "matches: no path at all" "$(rec matches)" 1
check "forget: one path" "$(rec forget "$sandbox/r/f" "$sandbox/r/rel")" 0
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
check "  and systemd was asked which unit it resolves (before writing, and after)" "$(calls 'show -p FragmentPath --value oskar.service')" 2
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
  reset; mkdir -p "$(dirname "$path")"; eval "$maker"; before="$(what "$path")"
  check "foreign $name: refused, exit 3" "$(run --prebuilt "$matching")" 3
  check "  the message names it" "$(grep -c "^  $path\$" "$sandbox/out")" 1
  check "  and says --force deletes nothing" "$(grep -c 'deletes nothing' "$sandbox/out")" 1
  check "  it is identical (a link keeps its text)" "$(what "$path")" "$before"
  check "  nothing else was written" "$(for p in "$unit" "$helper" "$cli" "$record_file"; do [[ "$p" == "$path" ]] && continue; [[ -e "$p" || -L "$p" ]] && echo "$p"; done | wc -l)" 0
  check "  and systemd was only asked, never told anything" "$(grep -v -c 'show -p FragmentPath' "$sandbox/systemctl.log")" 0
  check "foreign $name with --force: installs" "$(run --prebuilt "$matching" --force)" 0
  check "  it was moved aside as it was (a link stays a link, same text)" "$(for a in "$path".replaced-*; do what "$a"; done)" "$before"
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
check "  its enablement link is removed (the unit file is gone)" "$(link_is "$wants")" none
reset; run --prebuilt "$matching" >/dev/null; printf '# my tweak\n' >> "$unit"; printf 'someone elses program\n' > "$helper"
check "uninstall with an edited unit and a replaced helper" "$(unrun)" 0
check "  the edited unit stays" "$(grep -c '# my tweak' "$unit")" 1
check "  the replaced helper stays" "$(cat "$helper")" "someone elses program"
check "  the command, ours, is gone" "$([[ -L "$cli" ]] && echo left || echo gone)" gone
check "  the record forgot only the command" "$(grep -c -F "$cli" "$record_file"; wc -l < "$record_file")" "$(printf '0\n2')"
check "  it lists what stays, as not matching, never as not OSKar's" "$(grep -c -F -e "  $unit (does not match what OSKar installed)" -e "  $helper (does not match what OSKar installed)" "$sandbox/out")$(grep -c 'did not install' "$sandbox/out")" 20
check "  and says what oskar.service is now" "$(grep -c 'oskar.service is now enabled and inactive' "$sandbox/out")" 1
check "  the unit that stays is not disabled" "$(calls 'disable')" 0

# An edited unit that still runs the helper keeps the helper: no enabled
# unit is left pointing at a missing binary.
reset; run --prebuilt "$matching" >/dev/null; printf '# my tweak\n' >> "$unit"; hsum="$(sum "$helper")"; : > "$sandbox/systemctl.log"
check "uninstall with an edited unit that runs the helper" "$(unrun)" 0
check "  the unit stays" "$(grep -c '# my tweak' "$unit")" 1
check "  the helper stays with it, unchanged" "$(sum "$helper")" "$hsum"
check "  the command stays too, so uninstall.sh can finish" "$([[ -L "$cli" ]] && echo left || echo gone)" left
check "  it says why and how to finish" "$(grep -c -F "  $helper (OSKar's, kept because $unit was changed since OSKar installed it and still runs it)" "$sandbox/out")$(grep -c 'uninstall.sh --force' "$sandbox/out")" 11
check "  nothing disabled" "$(calls 'disable')" 0
check "  the helper stays recorded" "$(rec matches "$helper")" 0
check "then uninstall.sh --force" "$(sbx bash "$root/uninstall.sh" --force >"$sandbox/out" 2>&1; echo $?)" 0
check "  moves the edited unit aside, content kept" "$(grep -l '# my tweak' "$unit".uninstalled-* 2>/dev/null | wc -l)$([[ -e "$unit" ]] && echo left || echo gone)" 1gone
check "  removes the helper and the command" "$([[ -e "$helper" || -L "$cli" ]] && echo left || echo gone)" gone
check "  removes its own enablement link (the unit file is gone)" "$(link_is "$wants")" none
check "  and the record is gone" "$([[ -e "$record_file" ]] && echo left || echo gone)" gone
check "  it says where the unit went" "$(grep -c "moved aside as $unit.uninstalled-" "$sandbox/out")" 1

# A unit under our name that does not run our helper holds nothing back.
reset; run --prebuilt "$matching" >/dev/null; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"; : > "$sandbox/systemctl.log"
check "uninstall with someone else's unit under the name" "$(unrun)" 0
check "  their unit stays" "$(grep -c something-else "$unit")" 1
check "  our helper goes" "$([[ -e "$helper" ]] && echo left || echo gone)" gone
check "  nothing disabled" "$(calls 'disable')" 0

# --force never disables a unit file that stays: here systemd runs /etc's.
reset; run --prebuilt "$matching" >/dev/null; printf '# my tweak\n' >> "$unit"; : > "$sandbox/systemctl.log"
check "uninstall --force while systemd resolves an /etc unit" "$(STUB_FRAGMENT=/etc/systemd/user/oskar.service sbx bash "$root/uninstall.sh" --force >"$sandbox/out" 2>&1; echo $?)" 0
check "  no disable of any kind" "$(calls 'disable')" 0

# Another program's enablement of an oskar.service survives every way
# OSKar switches itself off; OSKar's own link goes.
for how in uninstall force teardown; do
  reset; run --prebuilt "$matching" >/dev/null; foreign_enabled
  [[ "$how" == force ]] && printf '# my tweak\n' >> "$unit"
  case "$how" in
    uninstall) r="$(unrun)" ;;
    force) r="$(sbx bash "$root/uninstall.sh" --force >"$sandbox/out" 2>&1; echo $?)" ;;
    teardown) r="$(oskar teardown)" ;;
  esac
  check "foreign enablement link with $how: exit 0" "$r" 0
  check "  their link survives, same text" "$(link_is "$theirs_link")" "$home/.local/share/systemd/user/oskar.service"
  check "  ours is removed" "$(link_is "$wants")" none
  check "  and the output says which was left and why" "$(grep -c -F "enablement link left: $theirs_link" "$sandbox/out")" 1
done

# --force is all or nothing.
reset; run --prebuilt "$matching" >/dev/null; printf '# my tweak\n' >> "$unit"; printf 'someone elses\n' > "$helper"
chmod 555 "$(dirname "$helper")"
check "uninstall --force with the helper's directory read-only: exit 1" "$(sbx bash "$root/uninstall.sh" --force >"$sandbox/out" 2>&1; echo $?)" 1
chmod 755 "$(dirname "$helper")"
check "  the unit is at its own name, edit kept" "$(grep -c '# my tweak' "$unit")" 1
check "  the helper too" "$(cat "$helper")" "someone elses"
check "  the command too" "$([[ -L "$cli" ]] && echo kept)" kept
check "  no aside anywhere" "$(find "$home" -name '*.uninstalled-*' | wc -l)" 0

# ---- oskar start: the panel's Retry ----
reset; run --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "start with our recorded unit" "$(oskar start)" 0
check "  starts it" "$(calls '^systemctl --user start oskar.service$')" 1
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"
check "start with a foreign unit: exit 1" "$(oskar start)" 1
check "  starts nothing" "$(calls '(start|restart|reset-failed).*oskar.service')" 0
check "  and says why" "$(grep -c "not proven OSKar's" "$sandbox/out")" 1
reset
check "start with no unit at all: exit 1" "$(oskar start)" 1
check "  starts nothing" "$(calls '(start|restart|reset-failed).*oskar.service')" 0

# ---- uninstall.sh over an install older than the record ----
reset; run --prebuilt "$matching" >/dev/null; rm -f "$record_file"; ln -s "$root" "$reg" 2>/dev/null || { mkdir -p "$(dirname "$reg")"; ln -s "$root" "$reg"; }
before="$(what "$unit") $(what "$helper") $(what "$cli")"; : > "$sandbox/systemctl.log"; : > "$sandbox/omarchy.log"
check "uninstall with no file matching the record: exit 3" "$(unrun)" 3
check "  the three are untouched" "$(what "$unit") $(what "$helper") $(what "$cli")" "$before"
check "  no teardown: registration kept, plugin not disabled, unit not disabled" "$([[ -L "$reg" ]] && echo kept)$(wc -l < "$sandbox/omarchy.log")$(calls 'disable')" kept00
check "  it says the truth and both ways out" "$(grep -c 'older than its install record' "$sandbox/out")$(grep -c 'install.sh --force once' "$sandbox/out")$(grep -c 'or run uninstall.sh --force' "$sandbox/out")" 111
reset; run --prebuilt "$matching" >/dev/null
for how in missing unreadable; do
  other="$sandbox/other"; rm -rf "$other"; mkdir -p "$other"
  command cp -r "$root/bin" "$root/systemd" "$root/install.sh" "$root/uninstall.sh" "$root/manifest.json" "$other/"
  reset; installer="$other/install.sh" run --prebuilt "$matching" >/dev/null; mkdir -p "$(dirname "$reg")"; ln -s "$other" "$reg"
  rsum="$(sum "$record_file")"; : > "$sandbox/systemctl.log"
  if [[ "$how" == missing ]]; then rm -f "$other/bin/oskar"; else chmod 000 "$other/bin/oskar"; fi
  check "uninstall with bin/oskar $how: refuses" "$(sbx bash "$other/uninstall.sh" >"$sandbox/out" 2>&1; echo $?)" 1
  check "  removes nothing" "$([[ -e "$unit" && -e "$helper" && -L "$cli" && -L "$reg" ]] && echo kept)$(sum "$record_file")$(wc -l < "$sandbox/systemctl.log")" "kept${rsum}0"
  chmod 644 "$other/bin/oskar" 2>/dev/null
done

# ---- the record file itself ----
record_refusal() { # <name> <maker>
  reset; mkdir -p "$(dirname "$unit")"; printf 'theirs\n' > "$unit"; eval "$2"
  check "record $1: install refuses, exit 1" "$(run --prebuilt "$matching" --force)" 1
  check "  the foreign unit did not move" "$(cat "$unit")$(anyaside)" theirs0
  check "  nothing was written" "$([[ -e "$helper" || -L "$cli" ]] && echo written || echo untouched)" untouched
}
record_refusal "path is a directory" 'mkdir -p "$record_file"'
check "  the directory is still empty" "$(command ls -A "$record_file" | wc -l)" 0
record_refusal "path is a symlink" 'mkdir -p "$(dirname "$record_file")"; printf "mine\n" > "$sandbox/target"; ln -s "$sandbox/target" "$record_file"'
check "  the symlink and its target are unchanged" "$(readlink "$record_file") $(cat "$sandbox/target")" "$sandbox/target mine"
record_refusal "state dir is a file" 'mkdir -p "$home/.local/state"; printf "a file\n" > "$home/.local/state/oskar"'
check "  the file is unchanged" "$(cat "$home/.local/state/oskar")" "a file"
record_refusal "without sha256sum" 'tpath="$sandbox/bin:$sandbox/nosha"'
tpath="$sandbox/bin:$sandbox/toolbox"
check "usable: a directory at the record path is refused" "$(mkdir -p "$record_file"; rec usable)" 1
check "write: a directory at the record path is refused, never moved into" "$(printf 'y\n' > "$sandbox/r/y"; rec write "$sandbox/r/y"; command ls -A "$record_file" | wc -l)" "$(printf '1\n0')"
reset; mkdir -p "$sandbox/cwd/oskar"; printf 'the user file\n' > "$sandbox/cwd/oskar/install-record"
check "a relative XDG_STATE_HOME is ignored: install succeeds" "$(cd "$sandbox/cwd" && state_home_override=. run --prebuilt "$matching")" 0
check "  the user's ./oskar/install-record is untouched" "$(cat "$sandbox/cwd/oskar/install-record"; command ls -A "$sandbox/cwd/oskar" | wc -l)" "$(printf 'the user file\n1')"
check "  the record went to the default place" "$(wc -l < "$record_file")" 3

# ---- --force is all or nothing ----
reset; mkdir -p "$(dirname "$unit")" "$(dirname "$helper")"; printf 'their unit\n' > "$unit"; printf 'their helper\n' > "$helper"
chmod 555 "$(dirname "$helper")"
check "--force with the helper's directory read-only: exit 1" "$(run --prebuilt "$matching" --force)" 1
chmod 755 "$(dirname "$helper")"
check "  the unit is at its own name, same bytes" "$(cat "$unit")" "their unit"
check "  the helper too" "$(cat "$helper")" "their helper"
check "  no aside anywhere" "$(anyaside)" 0
check "  nothing written" "$([[ -L "$cli" || -e "$record_file" ]] && echo written || echo untouched)" untouched

# ---- bin/oskar switches on or off only the unit that is OSKar's ----
reset; mkdir -p "$(dirname "$unit")"; printf '[Service]\nExecStart=/usr/bin/something-else\n' > "$unit"
check "teardown (source mode) with a foreign oskar.service" "$(oskar teardown)" 0
check "  systemd was never told to disable or stop it" "$(calls '(disable|stop|restart|enable).*oskar.service')" 0
check "  and teardown says why" "$(grep -c "not proven OSKar's" "$sandbox/out")" 1
check "  the foreign unit is byte-identical" "$(grep -c something-else "$unit")" 1
reset; run --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "teardown with our recorded unit" "$(oskar teardown)" 0
check "  stops it" "$(calls '^systemctl --user stop oskar.service$')" 1
check "  and removes its enablement link" "$(link_is "$wants")" none
reset; run --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "teardown when systemd resolves another file" "$(STUB_FRAGMENT=/etc/systemd/user/oskar.service oskar teardown)" 0
check "  leaves it alone" "$(calls '(disable|stop).*oskar.service')" 0

# The packaged unit's path proves nothing from a checkout: another
# package may ship oskar.service. Source mode never switches it.
pk=/usr/lib/systemd/user/oskar.service
reset; run --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "source mode, systemd resolves $pk: teardown" "$(STUB_FRAGMENT=$pk oskar teardown)" 0
check "  no disable or stop" "$(calls '(disable|stop).*oskar.service')" 0
reset; check "  setup dies" "$(STUB_ACTIVE=0 STUB_FRAGMENT=$pk oskar setup --prebuilt "$matching")" 1
check "  no enable or restart" "$(calls '(enable|start|restart).*oskar.service')" 0
reset; STUB_ACTIVE=0 oskar setup --prebuilt "$matching" >/dev/null; : > "$sandbox/systemctl.log"
check "  upgrade does not finish" "$(STUB_ACTIVE=0 STUB_FRAGMENT=$pk oskar upgrade --prebuilt "$matching")" 1
check "  no enable, restart or disable" "$(calls '(enable|start|restart|disable|stop).*oskar.service')" 0
mkdir -p "$sandbox/pacman"; printf '#!/bin/sh\n[ "$1 $2" = "-Qqo %s" ] && echo oskar\n' "$pk" > "$sandbox/pacman/pacman"; chmod +x "$sandbox/pacman/pacman"
reset; mkdir -p "$(dirname "$wants")"; ln -s "$pk" "$wants"; : > "$sandbox/systemctl.log"
check "source mode, pacman says the oskar package owns $pk: teardown" "$(tpath="$sandbox/pacman:$sandbox/bin:$sandbox/toolbox" STUB_FRAGMENT=$pk oskar teardown)" 0
check "  stops it" "$(calls '^systemctl --user stop oskar.service$')" 1
check "  and removes the link to it" "$(link_is "$wants")" none

# ---- install.sh does not shadow another oskar.service unasked ----
for other_unit in /usr/lib/systemd/user/oskar.service "$home/.local/share/systemd/user/oskar.service"; do
  reset
  check "another oskar.service at $other_unit: refused, exit 3" "$(STUB_SYSTEM_UNIT="$other_unit" run --prebuilt "$matching")" 3
  check "  it says so" "$(grep -c "a unit named oskar.service from $other_unit is already on this system" "$sandbox/out")" 1
  check "  nothing written" "$(written)" untouched
  foreign_enabled
  check "  with --force: installs" "$(STUB_SYSTEM_UNIT="$other_unit" run --prebuilt "$matching" --force)" 0
  check "  their enablement link is untouched" "$(link_is "$theirs_link")" "$home/.local/share/systemd/user/oskar.service"
done
reset; mkdir -p "$(dirname "$wants")"; ln -s /usr/lib/systemd/user/oskar.service "$wants"
check "--force when their link holds the very name OSKar would enable: exit 1" "$(STUB_SYSTEM_UNIT=/usr/lib/systemd/user/oskar.service run --prebuilt "$matching" --force)" 1
check "  their link is untouched" "$(link_is "$wants")" /usr/lib/systemd/user/oskar.service
check "  and it says OSKar's unit is installed but not enabled" "$(grep -c 'installed but not enabled' "$sandbox/out")" 1

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
check "  the shell calls were logged (the check below is not vacuous)" "$(grep -c 'omarchy plugin enable io.github.vladkarok.oskar' "$sandbox/omarchy.log")" 1
check "  nor did the shell calls" "$(grep -c -E 'omarchy-osk|vladkarok\.osk( |$)' "$sandbox/omarchy.log")" 0

check "the whole run never asked systemctl to disable anything (it acts by name)" "$(grep -c 'disable' "$sandbox/systemctl.all.log")" 0

echo "install-check: $passed passed, $failed failed"
((failed == 0))
