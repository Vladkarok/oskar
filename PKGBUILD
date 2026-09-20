# AUR PKGBUILD for oskar — the stable, tag-pinned package that is
# the public default (audit 2026-09-13 §32: one coherent product, not
# "AUR helper plus a separately managed Git plugin").
#
# CHECKSUMS LIVE OUTSIDE THE TREE. A GitHub tag tarball embeds the tag's
# commit SHA in a pax global header, so the tarball's bytes depend on the
# commit and a checksum recorded inside that same tag can never match it
# (v0.1.1 and v0.1.2 both shipped the PREVIOUS tag's checksum —
# updpkgsums ran while pkgver still named the old version). The
# verifying authority for a release is its GitHub release notes, which
# publish the tag tarball's real sha256; the AUR PKGBUILD carries the
# same value when AUR registration reopens — built mechanically by
# tools/make-aur-recipe.sh, which emits the AUR copy with the real sum.
# In-tree the sum stays SKIP
# and a source-checkout makepkg builds unverified by design.
#
# PUBLISHING IS OWNER-GATED. To release a version:
#   1. bump pkgver AND manifest.json's version together, create tag
#      v$pkgver at the release commit, push both,
#   2. create the GitHub release for the tag; its notes publish the
#      tag tarball's real sha256 (the AUR copies it later):
#        curl -sL "$url/archive/refs/tags/v$pkgver.tar.gz" | sha256sum
#      (oskar.install travels with the PKGBUILD or makepkg fails),
#   3. run makepkg --printsrcinfo > .SRCINFO, commit that,
#   4. revisit README's Status paragraph — it names the current release.
# A -git VCS package may follow later as a separate optional PKGBUILD;
# this one never resolves a moving branch.

pkgname=oskar
pkgver=0.2.1
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
# SKIP by design — see the checksum paragraph in the header: the real
# sha256 is published in the tag's GitHub release notes and travels to
# the AUR from there.
sha256sums=('SKIP')

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
