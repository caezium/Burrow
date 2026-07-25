#!/usr/bin/env bash
#
# bundle-burrow.sh — build the `burrow-engine` binary and stage it as the app's `Resources/burrow`.
#
# NAMING TRAP — read this before grepping for "engine" in this directory. In this repo "engine"
# used to mean the legacy Go DIGGER: bundle-engine.sh staged it at Resources/engine, sourced from
# caezium/burrow-digger, and the submodule at vendor/burrow-engine still checks out burrow-digger
# until a separate change repoints it. This script is named "burrow" because it used to build the
# FSL burrow-cli CONDUCTOR — but now it builds the new MIT `caezium/burrow-engine` Rust crate
# instead, and stages IT as Resources/burrow. So: the script called "burrow" builds the thing
# actually named "burrow-engine", and writes it to a file named neither. That's deliberate, not
# a leftover: keeping the staged filename `burrow` means `BurrowConductor.executableURL()`
# (Resources/burrow) never has to change, which is what lets every `capture()` call site need
# zero edits for this repoint.
#
# The GUI shells out to this ONE bundled binary (`burrow <cmd> --json`) for the stable Burrow
# envelope, and `clean --stream` / `optimize --stream` for the live NDJSON progress feed. The new
# MIT `burrow-engine` does all the work natively (analyze/status/clean/optimize/uninstall/net/
# orphans/slim-check/evict/dupes/photos/history/purge/installer), so there is no separate engine
# dir or conductor anymore — this single binary replaces both the old burrow-cli conductor and the
# burrow-digger engine. Only the built binary travels — no Rust source ships. `dupes` shells the
# sibling-bundled Resources/fclones via $BURROW_FCLONES.
#
# Usage: bundle-burrow.sh <BURROW_ENGINE_SRC> <RESOURCES_DIR>
#   BURROW_ENGINE_SRC  a burrow-engine checkout (has Cargo.toml with the `burrow-engine` binary)
#   RESOURCES_DIR      the app bundle's Resources dir (the binary is written directly inside it)
set -euo pipefail

SRC="${1:?burrow-engine source dir required}"
RESOURCES="${2:?resources dir required}"
OUT="$RESOURCES/burrow"

command -v cargo >/dev/null 2>&1 || {
  echo "error: cargo not found — cannot build burrow-engine (install Rust, or omit the vendor/burrow-engine submodule to fall back to a system engine)"
  exit 1
}

# Build UNIVERSAL (arm64 + x86_64) so the engine runs on BOTH Apple Silicon and Intel Macs. An
# arch-only binary hangs the universal app on the other arch (issue #221). Rust cross-compiles per
# target; we add both targets (rustup fetches the missing slice) and lipo them together.
# GIT_TERMINAL_PROMPT=0 + </dev/null keep a fresh checkout from ever blocking on an interactive
# prompt.
export GIT_TERMINAL_PROMPT=0
A=aarch64-apple-darwin
X=x86_64-apple-darwin
( cd "$SRC"
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$A" "$X" >/dev/null 2>&1 || true
  fi
  cargo build --release --bin burrow-engine --target "$A" </dev/null
  cargo build --release --bin burrow-engine --target "$X" </dev/null
  lipo -create -output "target/release/burrow-engine-universal" \
    "target/$A/release/burrow-engine" "target/$X/release/burrow-engine" )

# Stage + sign the engine so the app's own signature validates (--deep). Uses the build's resolved
# identity when run as a build phase, else ad-hoc ('-').
mkdir -p "$RESOURCES"
cp "$SRC/target/release/burrow-engine-universal" "$OUT"
chmod +x "$OUT"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$OUT" 2>/dev/null \
  || codesign --force --sign - --timestamp=none "$OUT" || true

echo "bundled burrow-engine -> $OUT ($(lipo -archs "$OUT" 2>/dev/null || echo native); signed with '${IDENTITY}')"
