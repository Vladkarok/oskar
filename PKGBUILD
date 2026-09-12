# AUR PKGBUILD for omarchy-osk-git (release plan §7/D2, E).
#
# Status: NOT yet buildable as-is - the repo is unpushed; the -git
# source clones a default branch that lacks Makefile/PKGBUILD. The
# owner gate is: push public, tag, THEN makepkg --printsrcinfo.
# PUBLISHING IS OWNER-GATED — pushing
# to the AUR is an external action this repo's workflow forbids without an
# explicit request. Before publishing the owner should:
#   1. push the repo public (source= below points at GitHub),
#   2. verify the tag exists and matches this pkgver,
#   3. run makepkg --printsrcinfo > .SRCINFO and commit it.
# A stable -release variant only needs source= pinned to the tag and a
# concrete pkgver; this -git prototype tracks default.

pkgname=omarchy-osk-git
pkgver=r60.0d23126
pkgrel=1
pkgdesc='Mouse-driven on-screen keyboard for Omarchy (Hyprland + Quickshell)'
arch=(x86_64)
url='https://github.com/Vladkarok/omarchy-osk'
license=(MIT)
depends=(gcc-libs glibc)
makedepends=(cargo rust git)
checkdepends=(qt6-declarative)
optdepends=(
  'omarchy: the shell this panel is built for'
  'wl-clipboard: the paste chip and clipboard-compat emoji delivery'
  'qt6-multimedia: key-click sound (optional)'
)
provides=(omarchy-osk)
conflicts=(omarchy-osk)
source=('git+https://github.com/Vladkarok/omarchy-osk.git')
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/$_repo"
  # r<commits>.<short-sha> until a tag exists; with a tag:
  # printf '%s.r%s.g%s' "$(git describe --tags --abbrev=0 | sed 's/^v//')" \
  #   "$(git rev-list "$(git describe --tags --abbrev=0)..HEAD" --count)" \
  #   "$(git rev-parse --short HEAD)"
  printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

# The git source clones to $srcdir/omarchy-osk regardless of pkgname.
_repo=omarchy-osk

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
