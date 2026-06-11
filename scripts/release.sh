#!/usr/bin/env bash
#
# Build a Release Burrow.app and package it as a distributable .zip, then
# print the sha256 for the Homebrew cask. The build carries no Developer ID
# and isn't notarized — but it IS ad-hoc signed (see below), which is what
# lets macOS Full Disk Access grants actually take effect. For a fully
# Gatekeeper-clean release, sign + notarize with a Developer ID on top (the
# CI release workflow does this when the signing secrets are present).
#
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || { echo "need xcodegen — brew install xcodegen"; exit 1; }

echo "==> xcodegen generate"
xcodegen generate >/dev/null

# Telemetry keys (optional). Sourced from the gitignored scripts/release.env so
# secrets never hit the repo. Absent → an honest no-telemetry release: empty
# keys make PostHog/Sentry inert (see Sources/Telemetry.swift, CrashReporter.swift).
[ -f scripts/release.env ] && source scripts/release.env
[ -n "${POSTHOG_API_KEY:-}" ] && echo "==> telemetry: PostHog key present" || echo "==> telemetry: no PostHog key (analytics off in this build)"
[ -n "${SENTRY_DSN:-}" ] && echo "==> telemetry: Sentry DSN present" || echo "==> telemetry: no Sentry DSN (crash reporting off in this build)"

echo "==> building Release (no Developer ID; ad-hoc signed below)"
rm -rf build_dist
xcodebuild -project Burrow.xcodeproj -scheme Burrow \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build_dist \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  POSTHOG_API_KEY="${POSTHOG_API_KEY:-}" \
  POSTHOG_HOST="${POSTHOG_HOST:-https://us.i.posthog.com}" \
  SENTRY_DSN="${SENTRY_DSN:-}" \
  build >/dev/null

APP="build_dist/Build/Products/Release/Burrow.app"
[ -d "$APP" ] || { echo "build failed: $APP missing"; exit 1; }

# Ad-hoc sign the bundle. CODE_SIGNING_ALLOWED=NO above leaves only the
# linker's automatic signature (codesign flags: adhoc,linker-signed), which
# `codesign --verify` rejects as "not signed at all". macOS TCC won't bind a
# Full Disk Access grant to a code identity it considers invalid, so on the
# unsigned build, granting FDA silently does nothing — the app keeps asking.
# An explicit `codesign --sign -` gives the bundle a real, stable cdhash that
# the FDA grant attaches to. (The cdhash still changes every rebuild, so each
# new version must be re-granted — only a Developer ID identity avoids that.)
echo "==> ad-hoc signing (stable code identity so Full Disk Access grants stick)"
codesign --force --sign - \
  --entitlements Resources/Burrow.entitlements \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
mkdir -p dist
ZIP="dist/Burrow-$VERSION.zip"
rm -f "$ZIP"

echo "==> packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo
echo "Built Burrow $VERSION"
echo "  artifact : $ZIP"
echo "  sha256   : $SHA"
echo
echo "Publish:"
echo "  gh release create v$VERSION \"$ZIP\" --title \"Burrow $VERSION\" --notes-file RELEASES.md"
echo "  then set version=$VERSION + sha256=$SHA in packaging/burrow.rb (your tap)."
