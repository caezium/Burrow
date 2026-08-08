#!/usr/bin/env bash
# Fail closed unless an extracted Burrow release preserves its distribution identity.
set -euo pipefail

[ "$#" -eq 4 ] \
  || { echo "usage: $0 <Burrow.app> <team-id> <version> <build>" >&2; exit 2; }

APP="$1"
EXPECTED_TEAM="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUILD="$4"
EXPECTED_IDENTIFIER="dev.caezium.Burrow"

[ -d "$APP" ] || { echo "error: app bundle is missing: $APP" >&2; exit 1; }
[[ "$EXPECTED_TEAM" =~ ^[A-Z0-9]{10}$ ]] \
  || { echo "error: expected Developer ID team is invalid" >&2; exit 2; }

codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -qxF "Identifier=$EXPECTED_IDENTIFIER" <<< "$DETAILS" \
  || { echo "error: release bundle identifier changed" >&2; exit 1; }
grep -qxF "TeamIdentifier=$EXPECTED_TEAM" <<< "$DETAILS" \
  || { echo "error: release Developer ID team changed" >&2; exit 1; }
grep -q '^Authority=Developer ID Application:' <<< "$DETAILS" \
  || { echo "error: release is not signed with Developer ID Application" >&2; exit 1; }
grep -q '^Runtime Version=' <<< "$DETAILS" \
  || { echo "error: release is missing hardened runtime" >&2; exit 1; }
grep -q '^Timestamp=' <<< "$DETAILS" \
  || { echo "error: release is missing a secure timestamp" >&2; exit 1; }

REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
grep -Fq "identifier \"$EXPECTED_IDENTIFIER\"" <<< "$REQUIREMENT" \
  || { echo "error: designated requirement has the wrong identifier" >&2; exit 1; }
grep -Fq "anchor apple generic" <<< "$REQUIREMENT" \
  || { echo "error: designated requirement is not anchored to Apple" >&2; exit 1; }
grep -Eq 'certificate leaf\[subject\.OU\] = "?'"$EXPECTED_TEAM"'"?' <<< "$REQUIREMENT" \
  || { echo "error: designated requirement does not pin the expected team" >&2; exit 1; }

INFO="$APP/Contents/Info.plist"
actual_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"
}
[ "$(actual_plist_value CFBundleIdentifier)" = "$EXPECTED_IDENTIFIER" ] \
  || { echo "error: Info.plist bundle identifier changed" >&2; exit 1; }
[ "$(actual_plist_value CFBundleShortVersionString)" = "$EXPECTED_VERSION" ] \
  || { echo "error: downloaded app version does not match the tag build" >&2; exit 1; }
[ "$(actual_plist_value CFBundleVersion)" = "$EXPECTED_BUILD" ] \
  || { echo "error: downloaded app build does not match the tag build" >&2; exit 1; }

xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
echo "Verified notarized Developer ID release identity for $EXPECTED_IDENTIFIER $EXPECTED_VERSION ($EXPECTED_BUILD), team $EXPECTED_TEAM."
