#!/usr/bin/env bash
#
# bundle-burrow.sh — stage the `burrow` CONDUCTOR binary into the app's Resources.
#
# The GUI shells out to this bundled conductor (`burrow <cmd> --json`) instead of the engine
# directly, so it gets the stable Burrow envelope + NDJSON streaming contract with zero install.
# burrow locates its engine via $BURROW_ENGINE_DIR, which the app sets to the sibling-bundled
# Resources/engine (see bundle-engine.sh). The FSL-licensed conductor and the MIT engine stay
# arm's-length (separate processes); only the built binary travels — no Rust source.
#
# Usage: bundle-burrow.sh <BURROW_CLI_SRC> <RESOURCES_DIR>
#   BURROW_CLI_SRC  a burrow-cli checkout (has Cargo.toml, src/)
#   RESOURCES_DIR   the app bundle's Resources dir (burrow is written directly inside it)
set -euo pipefail

SRC="${1:?burrow-cli source dir required}"
RESOURCES="${2:?resources dir required}"
OUT="$RESOURCES/burrow"

command -v cargo >/dev/null 2>&1 || {
  echo "error: cargo not found — cannot build the burrow conductor (install Rust, or omit the vendor/burrow-cli submodule to fall back to the system engine)"
  exit 1
}

# Build UNIVERSAL (arm64 + x86_64) so the conductor runs on BOTH Apple Silicon and Intel Macs.
# An arch-only binary hangs the universal app on the other arch (same lesson as the engine's Go
# binaries, issue #221). Rust cross-compiles per target; we add both targets (rustup fetches the
# missing slice) and lipo them together. GIT_TERMINAL_PROMPT=0 + </dev/null keep a fresh checkout
# from ever blocking the build on an interactive prompt.
export GIT_TERMINAL_PROMPT=0
A=aarch64-apple-darwin
X=x86_64-apple-darwin
( cd "$SRC"
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$A" "$X" >/dev/null 2>&1 || true
  fi
  cargo build --release --target "$A" </dev/null
  cargo build --release --target "$X" </dev/null
  lipo -create -output "target/release/burrow-universal" \
    "target/$A/release/burrow" "target/$X/release/burrow" )

# Stage + sign the conductor beside the engine so the app's own signature validates (--deep).
# Uses the build's resolved identity when run as a build phase, else ad-hoc ('-').
mkdir -p "$RESOURCES"
cp "$SRC/target/release/burrow-universal" "$OUT"
chmod +x "$OUT"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$OUT" 2>/dev/null \
  || codesign --force --sign - --timestamp=none "$OUT" || true

echo "bundled burrow -> $OUT ($(lipo -archs "$OUT" 2>/dev/null || echo native); signed with '${IDENTITY}')"
