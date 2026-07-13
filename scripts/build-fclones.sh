#!/usr/bin/env bash
#
# build-fclones.sh — build a UNIVERSAL `fclones` (MIT) from crates.io into the sidecar cache.
#
# fclones ships no macOS prebuilt binary, so the app bundles one we build ourselves. This is the
# HEAVY, disk-hungry half (two full dependency-tree builds, arm64 + x86_64) — kept OUT of the app
# build phase so a disk-constrained dev machine never triggers it accidentally. Run it explicitly:
# the release pipeline calls it (ample runner disk) with actions/cache keyed on the version so it
# builds only on the first release. bundle-fclones.sh then just COPIES the result.
#
# Idempotent: exits immediately if the cached universal already exists.
set -euo pipefail

VERSION="${FCLONES_VERSION:-0.35.0}"
CACHE="${FCLONES_CACHE:-$HOME/.cache/burrow-fclones}"
UNIVERSAL="$CACHE/fclones-universal-$VERSION"

if [ -x "$UNIVERSAL" ]; then
  echo "fclones $VERSION already cached: $UNIVERSAL ($(lipo -archs "$UNIVERSAL"))"
  exit 0
fi

command -v cargo >/dev/null 2>&1 || { echo "error: cargo not found — cannot build fclones"; exit 1; }

# Universal (arm64 + x86_64): an arch-only sidecar hangs the universal app on the other arch
# (#221). rustup fetches the missing target slice.
export GIT_TERMINAL_PROMPT=0
A=aarch64-apple-darwin
X=x86_64-apple-darwin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v rustup >/dev/null 2>&1; then
  rustup target add "$A" "$X" >/dev/null 2>&1 || true
fi

echo "building fclones $VERSION for $A …"
cargo install fclones --version "$VERSION" --locked --target "$A" --root "$TMP/a" </dev/null
echo "building fclones $VERSION for $X …"
cargo install fclones --version "$VERSION" --locked --target "$X" --root "$TMP/x" </dev/null

mkdir -p "$CACHE"
lipo -create -output "$UNIVERSAL" "$TMP/a/bin/fclones" "$TMP/x/bin/fclones"
chmod +x "$UNIVERSAL"
echo "built fclones $VERSION -> $UNIVERSAL ($(lipo -archs "$UNIVERSAL"))"
