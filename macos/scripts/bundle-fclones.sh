#!/usr/bin/env bash
#
# bundle-fclones.sh — stage a cached universal `fclones` (MIT) into the app's Resources.
#
# COPY-ONLY BY DESIGN. The Duplicates pane runs `burrow dupes`, whose conductor shells out to
# the fclones sidecar; the app points $BURROW_FCLONES at this bundled copy so Duplicates works
# with zero user install. fclones has no macOS prebuilt binary, so it's built from source ONCE
# by scripts/build-fclones.sh (release-only — it needs GBs of temp space, which disk-constrained
# dev machines don't have). This script NEVER builds; it only copies the cached universal. If
# the cache is empty (a plain local build) it warns + skips so the app build stays green and
# Duplicates falls back to a system/$BURROW_FCLONES fclones.
#
# Usage: bundle-fclones.sh <RESOURCES_DIR>
set -euo pipefail

RESOURCES="${1:?resources dir required}"
VERSION="${FCLONES_VERSION:-0.35.0}"
CACHE="${FCLONES_CACHE:-$HOME/.cache/burrow-fclones}"
OUT="$RESOURCES/fclones"
UNIVERSAL="$CACHE/fclones-universal-$VERSION"

if [ ! -x "$UNIVERSAL" ]; then
  echo "note: no cached universal fclones at $UNIVERSAL — Duplicates will use a system/\$BURROW_FCLONES fclones. (The release pipeline builds + caches it via scripts/build-fclones.sh.)"
  exit 0
fi

mkdir -p "$RESOURCES"
cp "$UNIVERSAL" "$OUT"
chmod +x "$OUT"

# Sign beside the engine/conductor so the app's own signature validates (--deep).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$OUT" 2>/dev/null \
  || codesign --force --sign - --timestamp=none "$OUT" || true

echo "bundled fclones -> $OUT ($(lipo -archs "$OUT" 2>/dev/null || echo native); signed with '${IDENTITY}')"
