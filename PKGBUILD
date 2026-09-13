# AUR PKGBUILD for omarchy-osk — the stable, tag-pinned package that is
# the public default (audit 2026-09-13 §32: one coherent product, not
# "AUR helper plus a separately managed Git plugin").
#
# PUBLISHING IS OWNER-GATED. This repo is currently unpushed and untagged;
# before publishing the owner must:
#   1. push the repo public (source= below points at GitHub),
#   2. create tag v$pkgver at the release commit,
#   3. replace sha256sums=('SKIP') with the tag tarball's real checksum
#      (updpkgsums), run makepkg --printsrcinfo > .SRCINFO, commit both
#      (omarchy-osk.install travels with the PKGBUILD or makepkg fails),
#      and push to the AUR.
# A -git VCS package may follow later as a separate optional PKGBUILD;
# this one never resolves a moving branch.

pkgname=omarchy-osk
pkgver=0.1.0
pkgrel=1
pkgdesc='Mouse-driven on-screen keyboard for Omarchy (Hyprland + Quickshell)'
arch=(x86_64)
url='https://github.com/Vladkarok/omarchy-osk'
license=(MIT)
# The product is Omarchy-only by scope decision: `omarchy` is provided by
# Omarchy's own packages (omarchy/omarchy-dev). The panel host and the
# compositor it reads layouts from are hard requirements, as are the
# clipboard tools the paste chip and the compatibility emoji route
# execute, and the library the helper links.
depends=(omarchy hyprland quickshell qt6-declarative jq wl-clipboard
  libxkbcommon gcc-libs glibc)
makedepends=(cargo)
optdepends=(
  'qt6-multimedia: key-click sound'
  'ffmpeg: key-click sound transcoding'
)
conflicts=(omarchy-osk-git)
install=omarchy-osk.install
source=("$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')  # publish gate: replace with the tag tarball checksum

_repo=omarchy-osk-$pkgver

build() {
  make -C "$srcdir/$_repo" build
}

check() {
  make -C "$srcdir/$_repo" check
}

package() {
  make -C "$srcdir/$_repo" stage DESTDIR="$pkgdir"
  install -Dm644 "$srcdir/$_repo/README.md" \
    "$pkgdir/usr/share/doc/omarchy-osk/README.md"
  install -Dm644 "$srcdir/$_repo/docs/omarchy-osk-package-notes.md" \
    "$pkgdir/usr/share/doc/omarchy-osk/package-notes.md"
}
