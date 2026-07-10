#!/usr/bin/env bash
# Stage the "Burrow over iMessage" sidecar into the app bundle's Resources.
#   bundle-sidecar.sh <sidecar-src-dir> <resources-dir>
# Copies the TS sources + node_modules + a `bun` binary into Resources/sidecar/,
# then codesigns the nested bun Mach-O so the app signature validates (Xcode's
# CodeSign phase re-seals the app afterward; scripts/build.sh / the release
# pipeline finalize it).
set -euo pipefail

SRC="${1:?sidecar source dir}"
RES="${2:?resources dir}"
DEST="$RES/sidecar"

BUN="${BUN_BIN:-$(command -v bun || true)}"
if [ -z "$BUN" ] || [ ! -x "$BUN" ]; then
  echo "warning: no bun binary (set BUN_BIN or install bun) — skipping sidecar bundle; feature inert."
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST/bin"

# Runtime files only (skip dev/test/secret/heavy artifacts).
/usr/bin/rsync -a \
  --exclude '.git' --exclude '.scguard' --exclude 'logs' \
  --exclude '*.test.ts' --exclude 'config.local.json' --exclude '*.state.json' \
  --exclude 'launchd' --exclude 'FRICTION.md' \
  "$SRC/agent.ts" "$SRC/check.ts" "$SRC/package.json" "$SRC/config.example.json" \
  "$SRC/src" "$SRC/agent" "$DEST/"

# node_modules is required at runtime (spectrum-ts). Copy if present, else install.
if [ -d "$SRC/node_modules" ]; then
  /usr/bin/rsync -a "$SRC/node_modules" "$DEST/"
else
  ( cd "$DEST" && "$BUN" install --production ) || echo "warning: bun install failed; sidecar may not run."
fi

cp "$BUN" "$DEST/bin/bun"
chmod +x "$DEST/bin/bun"

# Codesign the nested binary (adhoc if no identity, matching engine bundling).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
codesign --force --timestamp=none --sign "$IDENTITY" "$DEST/bin/bun" 2>/dev/null \
  || codesign --force --sign - "$DEST/bin/bun" 2>/dev/null \
  || echo "warning: could not codesign bundled bun."

echo "bundled iMessage sidecar → $DEST"
