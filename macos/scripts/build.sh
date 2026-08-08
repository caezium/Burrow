#!/usr/bin/env bash
#
# build.sh — build a local Burrow.app with the MIT engine bundled and sealed.
#
# The engine is staged into Resources by a build phase, but Xcode's CodeSign runs after all
# phases, leaving the resource seal stale (which breaks Full Disk Access — #177/#178). So the
# final inside-out seal is done HERE, after xcodebuild.
#
# Usage: scripts/build.sh [Debug|Release]
#   BURROW_ENGINE_SRC   engine checkout to bundle (default: ./vendor/burrow-engine)
#
# This helper always applies an ad-hoc identity. Official artifacts are signed
# with Developer ID and notarized only by the fail-closed tag workflow.
set -euo pipefail
cd "$(dirname "$0")/.."   # macos/

CONFIG="${1:-Debug}"
ENGINE_SRC="${BURROW_ENGINE_SRC:-$PWD/vendor/burrow-engine}"

bash ../scripts/fetch-sentry.sh
bash ../scripts/fetch-sparkle.sh
xcodegen generate >/dev/null

BURROW_ENGINE_SRC="$ENGINE_SRC" xcodebuild -project Burrow.xcodeproj -scheme Burrow \
  -configuration "$CONFIG" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO build

APP="$(xcodebuild -project Burrow.xcodeproj -scheme Burrow -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR /{d=$2} / WRAPPER_NAME /{w=$2} END{print d"/"w}')"

# Final inside-out seal (engine included). This is the step Xcode can't do for us.
bash ../scripts/sign-macos-app.sh "$APP" - adhoc Resources/Burrow.entitlements
echo "✓ built + sealed (local ad-hoc identity): $APP"
