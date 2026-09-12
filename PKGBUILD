# Prototype PKGBUILD for omarchy-osk (release plan §7/D2).
#
# Local prototype only: the source is the working tree via git+file, and
# the checksum is SKIP — a release must pin a tag and a real sha256.
# The package owns the helper, the user unit and the runtime plugin
# payload. Plugin registration and unit enablement are explicit user
# actions (omarchy plugin add / systemctl --user enable), never package
# hooks — the plan's §7 rules.

pkgname=omarchy-osk
pkgver=0.1.0
pkgrel=1
pkgdesc='Mouse-driven on-screen keyboard for Omarchy (Hyprland + Quickshell)'
arch=(x86_64)
url='https://github.com/Vladkarok/omarchy-osk'
license=(MIT)
depends=(gcc-libs glibc)
makedepends=(cargo rust)
optdepends=(
  'omarchy: the shell this panel is built for'
  'wl-clipboard: the paste chip and clipboard-compat delivery'
  'qt6-multimedia: key-click sound (optional)'
)
source=("git+file://$startdir")
sha256sums=('SKIP')

build() {
	make -C "$srcdir/$pkgname" build
}

check() {
	make -C "$srcdir/$pkgname" check
}

package() {
	make -C "$srcdir/$pkgname" stage DESTDIR="$pkgdir"
	install -Dm644 "$srcdir/$pkgname/README.md" \
		"$pkgdir/usr/share/doc/omarchy-osk/README.md"
	install -Dm644 "$srcdir/$pkgname/docs/omarchy-osk-package-notes.md" \
		"$pkgdir/usr/share/doc/omarchy-osk/package-notes.md" 2>/dev/null || true
}
