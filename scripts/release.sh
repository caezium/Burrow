#!/usr/bin/env bash
#
# Build a local Release Burrow.app and package it as a test-only .zip. The
# build carries no Developer ID and is not notarized, but it is coherently
# ad-hoc signed so macOS Full Disk Access grants can take effect. Never publish
# this artifact: official releases go only through the tag workflow, which
# requires Developer ID signing and Apple notarization before publication.
#
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || { echo "need xcodegen — brew install xcodegen"; exit 1; }

echo "==> fetching vendored Sentry.xcframework"
# Sentry is a local framework, not an SPM package (SPM's binary-artifact
# download hard-hangs the release runner — see scripts/fetch-sentry.sh).
bash scripts/fetch-sentry.sh

echo "==> fetching vendored Sparkle.framework"
# Sparkle's package also wraps a binary artifact. Fetch the official framework
# with curl so xcodebuild never enters SwiftPM's hanging artifact downloader.
bash scripts/fetch-sparkle.sh

echo "==> xcodegen generate"
# The macOS app lives under macos/ (monorepo: macos/ + windows/). Generate the
# project there; build artifacts still land at the repo root (build_dist/, dist/).
( cd macos && xcodegen generate >/dev/null )

# Telemetry keys (optional). Sourced from the gitignored scripts/release.env so
# secrets never hit the repo. Absent → an honest no-telemetry release: empty
# keys make PostHog/Sentry inert (see Sources/Telemetry.swift, CrashReporter.swift).
[ -f scripts/release.env ] && source scripts/release.env
[ -n "${POSTHOG_API_KEY:-}" ] && echo "==> telemetry: PostHog key present" || echo "==> telemetry: no PostHog key (analytics off in this build)"
[ -n "${SENTRY_DSN:-}" ] && echo "==> telemetry: Sentry DSN present" || echo "==> telemetry: no Sentry DSN (crash reporting off in this build)"

echo "==> building Release (no Developer ID; ad-hoc signed below)"
rm -rf build_dist
xcodebuild -project macos/Burrow.xcodeproj -scheme Burrow \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build_dist \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  POSTHOG_API_KEY="${POSTHOG_API_KEY:-}" \
  POSTHOG_HOST="${POSTHOG_HOST:-https://us.i.posthog.com}" \
  SENTRY_DSN="${SENTRY_DSN:-}" \
  ${BURROW_ENGINE_SRC:+BURROW_ENGINE_SRC="$BURROW_ENGINE_SRC"} \
  build

APP="build_dist/Build/Products/Release/Burrow.app"
[ -d "$APP" ] || { echo "build failed: $APP missing"; exit 1; }

# CODE_SIGNING_ALLOWED=NO above leaves linker/ad-hoc signatures on individual
# binaries, but the app contains several nested Mach-O executables (the
# conductor, fclones, and engine helpers). Sign every executable inside-out,
# then seal the outer app so the resource envelope is coherent and Full Disk
# Access can bind to a valid identity. A Developer ID identity is still needed
# for that identity to remain stable across updates.
echo "==> ad-hoc signing nested code + app (Full Disk Access identity)"
bash scripts/sign-macos-app.sh \
  "$APP" - adhoc macos/Resources/Burrow.entitlements

VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
mkdir -p dist
ZIP="dist/Burrow-$VERSION.zip"
rm -f "$ZIP"

echo "==> packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo
echo "Built local-only Burrow $VERSION (ad-hoc signed; not notarized)"
echo "  artifact : $ZIP"
echo "  sha256   : $SHA"
echo
echo "Do not publish this artifact."
echo "Official releases are created only by pushing a version tag after CI credentials are configured."
