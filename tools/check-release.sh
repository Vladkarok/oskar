#!/usr/bin/env bash
# Release consistency gate — the 2026-09-19 audit's automation ask.
# Checks, from the working tree:
#   1. PKGBUILD pkgver == manifest.json version
#   2. tag v$pkgver exists locally and on origin, and the local tag is pushed
#   3. the GitHub release notes for that tag carry the REAL tarball sha256
#   4. .SRCINFO is what `makepkg --printsrcinfo` produces today
# Network steps warn and skip when offline; every mismatch fails.
# Run: tools/check-release.sh
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
url=https://github.com/Vladkarok/oskar

fail=0
pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD | head -1)
manifest=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)
if [[ "$pkgver" != "$manifest" ]]; then
  echo "FAIL: PKGBUILD pkgver=$pkgver but manifest.json version=$manifest"
  fail=1
fi

if ! git rev-parse -q --verify "refs/tags/v$pkgver" >/dev/null; then
  echo "FAIL: tag v$pkgver does not exist locally"
  fail=1
elif ! git ls-remote --exit-code origin "refs/tags/v$pkgver" >/dev/null 2>&1; then
  echo "FAIL: tag v$pkgver exists locally but is not on origin"
  fail=1
elif [[ "$(git rev-parse "v$pkgver")" != "$(git ls-remote origin "refs/tags/v$pkgver" | cut -f1)" ]]; then
  echo "FAIL: local tag v$pkgver differs from the one on origin"
  fail=1
fi

if command -v makepkg >/dev/null 2>&1; then
  fresh=$(mktemp)
  makepkg --printsrcinfo >"$fresh"
  if ! diff -u .SRCINFO "$fresh"; then
    echo "FAIL: .SRCINFO is stale — regenerate with makepkg --printsrcinfo | tee .SRCINFO"
    fail=1
  fi
  rm -f "$fresh"
else
  echo "warn: makepkg not installed — .SRCINFO freshness not verified"
fi

archive=$(mktemp)
if curl -sfL --max-time 30 "$url/archive/refs/tags/v$pkgver.tar.gz" -o "$archive"; then
  sum=$(sha256sum "$archive" | cut -d' ' -f1)
  if gh release view "v$pkgver" --repo Vladkarok/oskar --json body -q .body 2>/dev/null \
      | grep -q "$sum"; then
    echo "ok: release notes for v$pkgver carry the tarball sha256 $sum"
  else
    echo "FAIL: release notes for v$pkgver do not carry the real tarball sha256 ($sum)"
    fail=1
  fi
else
  echo "warn: offline or tarball missing — release-notes hash not verified"
fi
rm -f "$archive"

if [[ $fail -eq 0 ]]; then
  echo "release consistency: PASS (v$pkgver)"
fi
exit $fail
