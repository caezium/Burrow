#!/usr/bin/env bash
#
# fetch-sentry.sh — vendor Sentry's prebuilt static xcframework locally.
#
# Sentry is deliberately NOT a Swift Package Manager dependency. SPM eagerly
# downloads EVERY binary xcframework variant in sentry-cocoa's manifest during
# resolution (Sentry, Sentry-Dynamic, -WithARM64e, -WithoutUIKitOrAppKit, …,
# ~500 MB total), and on the GitHub release runner that download hard-hangs
# xcodebuild's SPM forever — even though `curl` pulls the same artifact in under
# a second. So we vendor only the single static Sentry.xcframework we actually
# link (the same one the old SPM `Sentry` product used), with a checksum-pinned
# curl that retries on transient TLS failures. macos/project.yml references it
# as a local framework; CrashReporter.swift is unchanged.
#
# Idempotent: a stamp file lets repeat builds skip the download.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 scripts/release-input.py frameworks.sentry.version)"
# Matches the checksum sentry-cocoa pins for the static Sentry binary target.
SHA256="$(python3 scripts/release-input.py frameworks.sentry.sha256)"
URL="$(python3 scripts/release-input.py frameworks.sentry.url)"
DEST="macos/vendor/Sentry.xcframework"
STAMP="macos/vendor/.sentry-${VERSION}-${SHA256:0:12}.ok"

if [ -d "$DEST" ] && [ -f "$STAMP" ]; then
  echo "==> Sentry.xcframework ${VERSION} already vendored"
  exit 0
fi

echo "==> fetching Sentry.xcframework ${VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fSL --retry 5 --retry-delay 3 --retry-all-errors \
  --connect-timeout 30 --max-time 300 \
  -o "$TMP/Sentry.zip" "$URL"

GOT="$(shasum -a 256 "$TMP/Sentry.zip" | awk '{print $1}')"
if [ "$GOT" != "$SHA256" ]; then
  echo "error: Sentry.xcframework.zip checksum mismatch (got $GOT, want $SHA256)" >&2
  exit 1
fi

( cd "$TMP" && unzip -q Sentry.zip )
mkdir -p macos/vendor
rm -rf "$DEST"
mv "$TMP/Sentry.xcframework" "$DEST"
rm -f macos/vendor/.sentry-*.ok
touch "$STAMP"
echo "==> vendored $DEST"
