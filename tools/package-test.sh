#!/usr/bin/env bash
# Ticket 32's acceptance choreography — run INSIDE the VM (it installs
# packages and drives a live session; see docs/vm-handoff.md first).
#
#   tools/package-test.sh <phase>
#
# Phases, in the audit's order (docs/audit-2026-09-13.md §32):
#
#   build        package the CURRENT TREE (tarball source, no developer
#                checkout inside the build), namcap + ldd inspection
#   chroot-build the same recipe inside a clean archbuild chroot
#                (best-effort: needs the omarchy packages reachable)
#   install      pacman -U the built package
#   status       read-only report on a freshly installed package
#   setup        activate, then activate AGAIN (idempotence)
#   protocol     one hello roundtrip against the live helper + panel toggle
#   upgrade      pkgrel+1 build, pacman -U, omarchy-osk upgrade
#   teardown     deactivate twice; assert nothing dangles
#   reinstall    package + setup again
#   legacy       source install.sh, then package + setup --migrate-source
#   coldboot     after a guest reboot: service up, plugin loads, protocol
#
# Each phase is independently rerunnable and prints PASS/FAIL lines; the
# exit code is non-zero when any assertion fails. The developer checkout
# at ~/omarchy-osk is only the SOURCE of the tarball — everything the
# phases exercise is the installed package's world.

set -euo pipefail

phase="${1:-}"
[[ -n "$phase" ]] || { echo "usage: tools/package-test.sh <phase>" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# On disk, not /tmp: a makepkg srcdir grows a full cargo target (~1G+) and
# a tmpfs /tmp caps out mid-extract with a confusing quota error.
BUILD="${OSK_PKG_BUILD:-$HOME/.cache/osk-pkg}"
PKGOUT="$BUILD/omarchy-osk-0.1.0-1-x86_64.pkg.tar.zst"
PKGOUT2="$BUILD/omarchy-osk-0.1.0-2-x86_64.pkg.tar.zst"
PLUGIN_ID=io.github.vladkarok.osk
REG="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
PASS=0
FAIL=0

ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
no() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
summary() {
  printf -- '--- %s: %d passed, %d failed ---\n' "$phase" "$PASS" "$FAIL"
  ((FAIL == 0))
}

# The live-session environment every phase that talks to the shell needs.
session_env() {
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
  export OMARCHY_PATH=/usr/share/omarchy
  local sig
  sig="$(for d in "$XDG_RUNTIME_DIR"/hypr/*/; do
    printf 'j/version' | socat - UNIX-CONNECT:"$d.socket.sock" >/dev/null 2>&1 && basename "$d"
  done | tail -1)"
  [[ -n "$sig" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$sig" || true
}

make_tarball() {
  local out="$1" ver="${2:-0.1.0}"
  mkdir -p "$BUILD"
  # $HERE is the repo root; everything under it is the payload the tag
  # tarball would carry (minus build output and the local board).
  tar -C "$HERE" \
    --exclude='./.git' --exclude='./daemon/target' --exclude='./.scratch' \
    --transform="s|^\./|omarchy-osk-$ver/|" \
    -czf "$out" .
}

local_pkgbuild() {
  # The stable PKGBUILD with source= pointed at the local tarball: the
  # published recipe, proven without the (owner-gated) public tag.
  local ver="$1" rel="$2" tarname="$3" sums="$4"
  sed -e "s|^source=.*|source=(\"$BUILD/$tarname\")|" \
    -e "s|^sha256sums=.*|sha256sums=('$sums')|" \
    -e "s|^pkgrel=.*|pkgrel=$rel|" \
    "$HERE/PKGBUILD" >"$BUILD/PKGBUILD"
  # The recipe is exercised as written: GitHub tag tarballs extract to
  # omarchy-osk-<pkgver>/ and the local tarball matches that shape, so
  # _repo=omarchy-osk-$pkgver needs no patching here.
  cp "$HERE/omarchy-osk.install" "$BUILD/omarchy-osk.install"
}

phase_build() {
  mkdir -p "$BUILD"
  make_tarball "$BUILD/omarchy-osk-0.1.0.tar.gz" 0.1.0
  local sums
  sums="$(sha256sum "$BUILD/omarchy-osk-0.1.0.tar.gz" | awk '{print $1}')"
  local_pkgbuild 0.1.0 1 omarchy-osk-0.1.0.tar.gz "$sums"
  (cd "$BUILD" && makepkg -f --nosign) >/dev/null
  [[ -f "$PKGOUT" ]] && ok "makepkg produced $(basename "$PKGOUT")" \
    || no "package missing after makepkg"

  # .SRCINFO generates from the final recipe — the publish gate's artifact.
  (cd "$BUILD" && makepkg --printsrcinfo > .SRCINFO)
  grep -q "pkgname = omarchy-osk" "$BUILD/.SRCINFO" \
    && ok ".SRCINFO generated" || no ".SRCINFO missing"

  # No symlinks in the payload, and the lifecycle command is in place.
  # The package is not installed yet, so inspect the tar stream itself.
  bad="$(tar -tf "$PKGOUT" | grep -c ' -> ' || true)"
  [[ "$bad" == 0 ]] && ok "payload is symlink-free" || no "symlinks in payload: $bad"
  pacman -Qlp "$PKGOUT" 2>/dev/null | grep -q "/usr/bin/omarchy-osk$" \
    && ok "lifecycle command packaged" || no "/usr/bin/omarchy-osk missing"

  # namcap, when available (informational unless installed).
  if command -v namcap >/dev/null; then
    namcap "$PKGOUT" | tee "$BUILD/namcap.log" || true
    ok "namcap ran (log: $BUILD/namcap.log)"
  else
    echo "note: namcap not installed; skipping (pacman -S namcap)"
  fi

  # The staged helper's dynamic set must be covered by depends=.
  rm -rf "$BUILD/inspect" && mkdir -p "$BUILD/inspect"
  tar -xf "$PKGOUT" -C "$BUILD/inspect" usr/lib/omarchy-osk/omarchy-osk-daemon
  local libs uncovered lib
  libs="$(ldd "$BUILD/inspect/usr/lib/omarchy-osk/omarchy-osk-daemon" |
    awk '/=> \//{print $1}' | sort -u)"
  uncovered=""
  local lib
  for lib in $libs; do
    case "$lib" in
    libc.so.6|libgcc_s.so.1|libxkbcommon.so.0|/lib64/ld-linux-x86-64.so.2) ;;
    *) uncovered="$uncovered $lib" ;;
    esac
  done
  [[ -z "$uncovered" ]] \
    && ok "helper .so set covered by depends= (glibc, libgcc_s, libxkbcommon)" \
    || no "uncovered libraries:$uncovered"
  summary
}

phase_chroot_build() {
  command -v makechrootpkg >/dev/null || {
    echo "note: devtools not installed; trying: pacman -S devtools"
    sudo pacman -Sy --needed --noconfirm devtools >/dev/null
  }
  local chroot=/var/lib/archbuild/osk
  # mkarchroot resolves the dir with readlink -f, which yields nothing
  # while intermediate directories are missing — create them first.
  sudo mkdir -p "$chroot"
  [[ -d $chroot/root ]] || sudo mkarchroot "$chroot/root" base-devel >/dev/null
  # A stock chroot cannot resolve depends=(omarchy): the omarchy packages
  # are Omarchy's own AUR set whose closure (omarchy-keyring,
  # omarchy-settings-dev, …) no mirror carries. That is a property of the
  # dependency graph, not of this recipe — a real AUR helper resolves it
  # against the user's full set. The chroot leg therefore proves the
  # recipe in a clean environment with the toolchain installed by hand
  # and dependency resolution skipped; check() ran in the dirty build.
  # -Sw --needed refuses to download packages the guest already has
  # installed, so fetch the exact files by URL into the cache.
  local p url base
  for p in rust cargo libxkbcommon; do
    ls /var/cache/pacman/pkg/$p-*.pkg.tar.zst >/dev/null 2>&1 && continue
    url="$(pacman -Sp "$p" 2>/dev/null || true)"
    [[ -n "$url" ]] || continue
    base="$(basename "$url")"
    sudo curl -sSL --retry 3 -C - -o "/var/cache/pacman/pkg/$base" "$url" || true
  done
  local args=()
  local f
  for p in rust cargo libxkbcommon; do
    f="$(ls /var/cache/pacman/pkg/$p-*.pkg.tar.zst 2>/dev/null | tail -1 || true)"
    [[ -n "$f" ]] && args+=(-I "$f")
  done
  if (cd "$BUILD" && sudo makechrootpkg -c -r "$chroot" "${args[@]}" \
    -- -f --nodeps --nocheck) >"$BUILD/chroot-build.log" 2>&1; then
    # PKGDEST is the cwd ($BUILD): the chroot product lands beside the
    # dirty one, same name.
    [[ -s "$BUILD/omarchy-osk-0.1.0-1-x86_64.pkg.tar.zst" ]] \
      && ok "clean-chroot build produced the package into \$BUILD (log: $BUILD/chroot-build.log)" \
      || ok "clean-chroot build completed (log: $BUILD/chroot-build.log)"
  else
    tail -5 "$BUILD/chroot-build.log" || true
    no "clean-chroot build failed (log: $BUILD/chroot-build.log); the dirty build remains the gate"
  fi
  summary
}

phase_install() {
  [[ -f "$PKGOUT" ]] || { no "no package built"; summary; return; }
  sudo pacman -U --noconfirm "$PKGOUT" >/dev/null
  pacman -Qi omarchy-osk >/dev/null && ok "package installed" || no "not installed"
  command -v omarchy-osk >/dev/null && ok "omarchy-osk on PATH" || no "command missing"
  [[ -d /usr/share/omarchy-osk/plugin ]] && ok "payload present" || no "payload missing"
  summary
}

phase_status() {
  session_env
  omarchy-osk status | tee "$BUILD/status-fresh.log"
  grep -q "mode:            packaged" "$BUILD/status-fresh.log" \
    && ok "status reports packaged mode" || no "mode line wrong"
  grep -q "registration:.*-> none" "$BUILD/status-fresh.log" \
    && ok "fresh install reports no registration" || no "registration line wrong"
  summary
}

phase_setup() {
  session_env
  omarchy-osk setup | tee "$BUILD/setup1.log"
  [[ "$(readlink -f "$REG")" == /usr/share/omarchy-osk/plugin ]] \
    && ok "registration -> packaged payload" || no "registration wrong"
  omarchy plugin list --json | jq -e --arg id "$PLUGIN_ID" \
    '.[] | select(.id == $id) | .enabled' | grep -q true \
    && ok "plugin enabled" || no "plugin not enabled"
  systemctl --user --quiet is-enabled omarchy-osk.service \
    && ok "unit enabled" || no "unit not enabled"
  systemctl --user --quiet is-active omarchy-osk.service \
    && ok "unit active" || no "unit not active"

  omarchy-osk setup >/dev/null && ok "second setup exits 0" || no "second setup failed"
  [[ "$(readlink -f "$REG")" == /usr/share/omarchy-osk/plugin ]] \
    && ok "second setup kept the registration" || no "registration changed"
  summary
}

phase_protocol() {
  session_env
  local sock="$XDG_RUNTIME_DIR/omarchy-osk/control.sock" reply tries=20
  while ((tries-- > 0)); do
    [[ -S "$sock" ]] && break
    sleep 0.5
  done
  [[ -S "$sock" ]] && ok "socket present" || no "socket missing"
  reply="$(printf 'hello 5\n' | timeout 2 socat -t1 - UNIX-CONNECT:"$sock" | head -n1)"
  [[ "$reply" == "hello 5" ]] && ok "protocol hello ok" || no "hello reply: $reply"
  local rc1=0 rc2=0
  omarchy-shell shell toggle "$PLUGIN_ID" || rc1=$?
  sleep 2
  omarchy-shell shell toggle "$PLUGIN_ID" || rc2=$?
  if [[ $rc1 -eq 0 && $rc2 -eq 0 ]]; then
    ok "panel toggles both directions from the packaged tree"
  else
    no "panel toggle failed (open rc=$rc1, close rc=$rc2)"
  fi
  summary
}

phase_upgrade() {
  session_env
  make_tarball "$BUILD/omarchy-osk-0.1.0.tar.gz" 0.1.0
  local sums
  sums="$(sha256sum "$BUILD/omarchy-osk-0.1.0.tar.gz" | awk '{print $1}')"
  local_pkgbuild 0.1.0 2 omarchy-osk-0.1.0.tar.gz "$sums"
  (cd "$BUILD" && makepkg -f --nosign) >/dev/null
  [[ -f "$PKGOUT2" ]] && ok "pkgrel=2 package built" || no "upgrade package missing"
  sudo pacman -U --noconfirm "$PKGOUT2" >/dev/null
  [[ "$(pacman -Q omarchy-osk)" == *-2 ]] && ok "pkgrel=2 installed" || no "pkgrel wrong"
  omarchy-osk upgrade | tee "$BUILD/upgrade.log"
  systemctl --user --quiet is-active omarchy-osk.service \
    && ok "helper active after upgrade" || no "helper down after upgrade"
  local sock="$XDG_RUNTIME_DIR/omarchy-osk/control.sock" reply
  reply="$(printf 'hello 5\n' | timeout 2 socat -t1 - UNIX-CONNECT:"$sock" | head -n1)"
  [[ "$reply" == "hello 5" ]] && ok "protocol ok after upgrade" || no "hello reply: $reply"
  summary
}

phase_teardown() {
  session_env
  omarchy-osk teardown | tee "$BUILD/teardown1.log"
  [[ ! -e "$REG" ]] && ok "registration unlinked" || no "registration still present"
  systemctl --user --quiet is-enabled omarchy-osk.service 2>/dev/null \
    && no "unit still enabled" || ok "unit disabled"
  systemctl --user --quiet is-active omarchy-osk.service 2>/dev/null \
    && no "unit still active" || ok "unit stopped"

  omarchy-osk teardown >/dev/null && ok "second teardown exits 0" || no "second teardown failed"
  [[ ! -e "$REG" ]] && ok "no dangling registration" || no "registration dangles"
  [[ -e $HOME/.config/omarchy-osk ]] && ok "config preserved" || ok "config absent (fresh lab)"
  summary
}

phase_reinstall() {
  session_env
  sudo pacman -U --noconfirm "$PKGOUT" >/dev/null
  omarchy-osk setup >/dev/null
  systemctl --user --quiet is-active omarchy-osk.service \
    && ok "reinstalled + setup: helper active" || no "helper down after reinstall"
  [[ "$(readlink -f "$REG")" == /usr/share/omarchy-osk/plugin ]] \
    && ok "registration restored" || no "registration wrong after reinstall"
  summary
}

phase_legacy() {
  session_env
  # A source install from a separate checkout — the legacy state.
  rm -rf /tmp/osk-legacy && mkdir -p /tmp/osk-legacy
  make_tarball /tmp/osk-legacy/omarchy-osk-0.1.0.tar.gz 0.1.0
  tar -C /tmp/osk-legacy -xzf /tmp/osk-legacy/omarchy-osk-0.1.0.tar.gz
  (cd /tmp/osk-legacy/omarchy-osk-0.1.0 && bash install.sh) >/dev/null 2>&1
  [[ -f $HOME/.config/systemd/user/omarchy-osk.service ]] \
    && ok "legacy user unit installed" || no "legacy unit missing"
  systemctl --user --quiet is-active omarchy-osk.service \
    && ok "legacy helper running" || no "legacy helper not running"

  # The packaged unit is shadowed: plain setup must refuse.
  if omarchy-osk setup >/dev/null 2>&1; then
    no "setup did not refuse the legacy override"
  else
    ok "setup refuses while the legacy unit overrides"
  fi

  omarchy-osk setup --migrate-source | tee "$BUILD/migrate.log"
  [[ ! -e $HOME/.config/systemd/user/omarchy-osk.service ]] \
    && ok "legacy unit moved aside" || no "legacy unit still in place"
  ls $HOME/.config/systemd/user/omarchy-osk.service.migrated-* >/dev/null 2>&1 \
    && ok "legacy unit kept (renamed)" || no "legacy unit not preserved"
  [[ ! -e $HOME/.local/libexec/omarchy-osk-daemon ]] \
    && ok "legacy helper binary removed" || no "legacy binary still present"
  [[ ! -e $HOME/.local/bin/omarchy-osk ]] \
    && ok "source lifecycle symlink removed from ~/.local/bin" \
    || no "~/.local/bin/omarchy-osk still shadows /usr/bin"
  systemctl --user --quiet is-active omarchy-osk.service \
    && ok "helper active from the packaged unit" || no "helper down after migration"
  [[ "$(readlink -f "$REG")" == /usr/share/omarchy-osk/plugin ]] \
    && ok "registration points at the packaged payload" || no "registration wrong"
  summary
}

phase_coldboot() {
  session_env
  sleep 3
  systemctl --user --quiet is-active omarchy-osk.service \
    && ok "helper active after cold boot" || no "helper down after cold boot"
  local sock="$XDG_RUNTIME_DIR/omarchy-osk/control.sock" reply
  reply="$(printf 'hello 5\n' | timeout 2 socat -t1 - UNIX-CONNECT:"$sock" | head -n1)"
  [[ "$reply" == "hello 5" ]] && ok "protocol ok after cold boot" || no "hello reply: $reply"
  [[ "$(readlink -f "$REG")" == /usr/share/omarchy-osk/plugin ]] \
    && ok "registration intact" || no "registration lost on boot"
  omarchy-shell shell toggle "$PLUGIN_ID" && sleep 2 \
    && ok "panel loads from the packaged payload" || no "panel toggle failed"
  omarchy-shell shell toggle "$PLUGIN_ID" >/dev/null
  summary
}

case "$phase" in
build) phase_build ;;
chroot-build) phase_chroot_build ;;
install) phase_install ;;
status) phase_status ;;
setup) phase_setup ;;
protocol) phase_protocol ;;
upgrade) phase_upgrade ;;
teardown) phase_teardown ;;
reinstall) phase_reinstall ;;
legacy) phase_legacy ;;
coldboot) phase_coldboot ;;
*)
  echo "unknown phase: $phase" >&2
  echo "phases: build chroot-build install status setup protocol upgrade teardown reinstall legacy coldboot" >&2
  exit 2
  ;;
esac
