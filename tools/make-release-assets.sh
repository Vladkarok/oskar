#!/usr/bin/env bash
# Builds the prebuilt-helper asset for a release: a tarball with the
# stripped oskar-daemon, the user unit and the oskar lifecycle command,
# built from a CLEAN checkout of the release tag (never the working tree),
# plus its sha256. Upload both files to the tag's GitHub release; a user
# without a Rust toolchain then runs `install.sh --prebuilt <tarball>`.
#
#   tools/make-release-assets.sh            # ref v<pkgver from PKGBUILD>
#   tools/make-release-assets.sh <git-ref>  # any ref, for a dry run
#
# Output: dist/oskar-daemon-<version>-<arch>.tar.gz and .sha256, where
# <version> is manifest.json's at that ref (install.sh compares it with
# the plugin it installs beside).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

ref="${1:-v$(sed -n 's/^pkgver=//p' PKGBUILD | head -1)}"
git rev-parse -q --verify "$ref^{commit}" >/dev/null \
  || { echo "no such ref: $ref" >&2; exit 1; }
command -v cargo >/dev/null || { echo "cargo is required" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive --format=tar "$ref" | tar -x -C "$work"

version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$work/manifest.json" | head -1)
[[ -n "$version" ]] || { echo "manifest.json at $ref has no version" >&2; exit 1; }
arch=$(uname -m)
name="oskar-daemon-$version-$arch"

echo "Building the helper at $ref ($version, $arch)..."
cargo build --locked --release --quiet --manifest-path "$work/daemon/Cargo.toml"

stage="$work/stage/$name"
install -Dm755 "$work/daemon/target/release/oskar-daemon" "$stage/oskar-daemon"
install -Dm644 "$work/systemd/oskar.service" "$stage/oskar.service"
install -Dm755 "$work/bin/oskar" "$stage/oskar"
git -C "$root" rev-parse "$ref^{commit}" > "$stage/COMMIT"

mkdir -p dist
tar -czf "dist/$name.tar.gz" -C "$work/stage" "$name"
(cd dist && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
echo "dist/$name.tar.gz"
/usr/bin/cat "dist/$name.tar.gz.sha256"
