# AUR PKGBUILD for oskar — the stable, tag-pinned package that is
# the public default (audit 2026-09-13 §32: one coherent product, not
# "AUR helper plus a separately managed Git plugin").
#
# PUBLISHING IS OWNER-GATED. This repo is currently unpushed and untagged;
# before publishing the owner must:
#   1. push the repo public (source= below points at GitHub),
#   2. create tag v$pkgver at the release commit,
#   3. replace sha256sums=('SKIP') with the tag tarball's real checksum
#      (updpkgsums), run makepkg --printsrcinfo > .SRCINFO, commit both
#      (oskar.install travels with the PKGBUILD or makepkg fails),
#      and push to the AUR.
#   4. revisit README's Status paragraph — it names this gate.
# A -git VCS package may follow later as a separate optional PKGBUILD;
# this one never resolves a moving branch.

pkgname=oskar
pkgver=0.1.0
pkgrel=1
pkgdesc='OSKar — mouse-driven on-screen keyboard for Omarchy (Hyprland + Quickshell)'
arch=(x86_64)
url='https://github.com/Vladkarok/oskar'
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
conflicts=(oskar-git omarchy-osk)
# The pre-publish rename (ticket 59): machines that installed the
# never-published omarchy-osk package walk to this one — pacman -Syu
# (and AUR helpers' sync installs) replace it via replaces=; a plain
# pacman -U refuses while the old package stands (conflicts=), so the
# old one comes out first (sudo pacman -Rns omarchy-osk). `oskar
# setup` then migrates registration, unit and state.
replaces=(omarchy-osk)
install=oskar.install
source=("$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('461cf30ab6471ddff3bca9dbaf7e3451f6c2a15385b64e7ecfb18f080da665b2')

_repo=oskar-$pkgver

build() {
  make -C "$srcdir/$_repo" build
}

check() {
  make -C "$srcdir/$_repo" check
}

package() {
  make -C "$srcdir/$_repo" stage DESTDIR="$pkgdir"
  install -Dm644 "$srcdir/$_repo/README.md" \
    "$pkgdir/usr/share/doc/oskar/README.md"
  install -Dm644 "$srcdir/$_repo/docs/package-notes.md" \
    "$pkgdir/usr/share/doc/oskar/package-notes.md"
}
