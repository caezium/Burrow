#!/usr/bin/env bash
#
# Sign every executable inside a macOS app from the inside out, then seal the
# outer app with its entitlements. Release CI uses Developer ID mode; local
# source builds use ad-hoc mode so Full Disk Access can bind to a valid code
# identity without requiring maintainers to possess the distribution key.
#
set -euo pipefail

usage() {
  echo "usage: $0 <app-path> <identity> <developer-id|adhoc> [entitlements-path]" >&2
  exit 2
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage

APP="$1"
IDENTITY="$2"
MODE="$3"
ENTITLEMENTS="${4:-macos/Resources/Burrow.entitlements}"

[ -d "$APP" ] || { echo "error: app not found: $APP" >&2; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "error: entitlements not found: $ENTITLEMENTS" >&2; exit 1; }

case "$MODE" in
  developer-id)
    case "$IDENTITY" in
      "Developer ID Application:"*) ;;
      *)
        echo "error: release identity must start with 'Developer ID Application:'" >&2
        exit 1
        ;;
    esac
    if [[ "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
      EXPECTED_TEAM="${BASH_REMATCH[1]}"
    else
      echo "error: release identity must end with a 10-character team ID in parentheses" >&2
      exit 1
    fi
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
    if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
      [ -f "$CODESIGN_KEYCHAIN" ] \
        || { echo "error: signing keychain not found: $CODESIGN_KEYCHAIN" >&2; exit 1; }
      SIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
    fi
    ;;
  adhoc)
    [ "$IDENTITY" = "-" ] || { echo "error: ad-hoc mode requires identity '-'" >&2; exit 1; }
    EXPECTED_TEAM=""
    SIGN_ARGS=(--force --sign -)
    ;;
  *)
    usage
    ;;
esac

sign_one() {
  local path="$1"
  local metadata="identifier"
  local existing_entitlements
  # Sparkle's Autoupdate helper carries an application-identifier entitlement,
  # and future nested dependencies may add their own. Re-sign every nested
  # executable with our identity while retaining vendor-defined identifiers.
  # Only ask codesign to preserve entitlements when the component has at least
  # one: preserving an empty entitlement blob fails on Sparkle's Updater binary
  # with errSecInternalComponent. The outer Burrow app gets its explicit
  # entitlements separately below.
  existing_entitlements="$(codesign -d --entitlements :- "$path" 2>/dev/null || true)"
  if printf '%s' "$existing_entitlements" | grep -q '<key>'; then
    metadata+=",entitlements"
  fi
  codesign "${SIGN_ARGS[@]}" \
    --preserve-metadata="$metadata" "$path"
}

is_macho() {
  file -b "$1" | grep -q "Mach-O"
}

read_entitlements() {
  local path="$1"
  local plist
  if ! plist="$(codesign -d --entitlements :- "$path" 2>/dev/null)"; then
    echo "error: could not read entitlements from signed code: $path" >&2
    return 1
  fi
  if ! printf '%s' "$plist" | plutil -lint - >/dev/null; then
    echo "error: codesign returned invalid entitlements for: $path" >&2
    return 1
  fi
  printf '%s' "$plist"
}

plist_has_key() {
  local key="$1"
  local xml
  if ! xml="$(plutil -convert xml1 -o - - 2>/dev/null)"; then
    return 2
  fi
  if grep -Fq "<key>$key</key>" <<< "$xml"; then
    return 0
  fi
  return 1
}

required_plist_raw() {
  local key="$1"
  local expected_type="$2"
  local value
  if ! value="$(
    plutil -extract "$key" raw -expect "$expected_type" -o - - 2>/dev/null
  )"; then
    echo "error: could not extract plist key '$key' as $expected_type" >&2
    return 1
  fi
  printf '%s' "$value"
}

echo "==> signing nested Mach-O files ($MODE)"
SIGNED_MACHO=0
while IFS= read -r -d '' candidate; do
  if is_macho "$candidate"; then
    sign_one "$candidate"
    SIGNED_MACHO=$((SIGNED_MACHO + 1))
  fi
done < <(find "$APP/Contents" -type f -print0)

# Re-seal code-bearing containers after their executables. `find -depth`
# guarantees an embedded app/XPC/framework is handled before its parent.
echo "==> signing nested code containers ($MODE)"
SIGNED_CONTAINERS=0
while IFS= read -r -d '' container; do
  sign_one "$container"
  SIGNED_CONTAINERS=$((SIGNED_CONTAINERS + 1))
done < <(
  find "$APP/Contents" -depth -type d \
    \( -name "*.framework" -o -name "*.xpc" -o -name "*.appex" \
       -o -name "*.app" -o -name "*.plugin" \) -print0
)

echo "==> sealing outer app ($MODE)"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$MODE" = "developer-id" ]; then
  verify_team() {
    local path="$1"
    local actual
    actual="$(codesign -d --verbose=4 "$path" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    [ "$actual" = "$EXPECTED_TEAM" ] || {
      echo "error: nested code has team '${actual:-missing}', expected '$EXPECTED_TEAM': $path" >&2
      exit 1
    }
  }

  echo "==> verifying one Developer ID team across all nested code"
  while IFS= read -r -d '' candidate; do
    if is_macho "$candidate"; then verify_team "$candidate"; fi
  done < <(find "$APP/Contents" -type f -print0)
  while IFS= read -r -d '' container; do
    verify_team "$container"
  done < <(
    find "$APP/Contents" -depth -type d \
      \( -name "*.framework" -o -name "*.xpc" -o -name "*.appex" \
         -o -name "*.app" -o -name "*.plugin" \) -print0
  )
  verify_team "$APP"
fi

# Sparkle 2.9.4's installer helper needs this entitlement. A generic re-sign
# can silently strip it while leaving `codesign --verify --deep` green, so pin
# the runtime contract explicitly whenever Sparkle is embedded.
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  SPARKLE_AUTOUPDATE="$(find "$SPARKLE_FRAMEWORK" -type f -name Autoupdate -print -quit)"
  [ -n "$SPARKLE_AUTOUPDATE" ] \
    || { echo "error: Sparkle.framework is missing Autoupdate" >&2; exit 1; }
  SPARKLE_ENTITLEMENTS="$(read_entitlements "$SPARKLE_AUTOUPDATE")"
  SPARKLE_APP_ID="$(
    printf '%s' "$SPARKLE_ENTITLEMENTS" \
      | required_plist_raw 'com\.apple\.application-identifier' string
  )"
  [ "$SPARKLE_APP_ID" = "org.sparkle-project.Sparkle.Autoupdate" ] || {
    echo "error: Sparkle Autoupdate entitlement was lost while re-signing" >&2
    exit 1
  }
fi

APP_ENTITLEMENTS="$(read_entitlements "$APP")"
GET_TASK_ALLOW_KEY='com.apple.security.get-task-allow'
if printf '%s' "$APP_ENTITLEMENTS" | plist_has_key "$GET_TASK_ALLOW_KEY"; then
  GET_TASK_ALLOW="$(
    printf '%s' "$APP_ENTITLEMENTS" \
      | required_plist_raw 'com\.apple\.security\.get-task-allow' bool
  )"
  if [ "$GET_TASK_ALLOW" != false ]; then
    echo "error: release app contains invalid com.apple.security.get-task-allow=$GET_TASK_ALLOW" >&2
    exit 1
  fi
else
  KEY_STATUS=$?
  if [ "$KEY_STATUS" -ne 1 ]; then
    echo "error: could not inspect app entitlements for $GET_TASK_ALLOW_KEY" >&2
    exit 1
  fi
fi

echo "signed $SIGNED_MACHO Mach-O file(s) and $SIGNED_CONTAINERS code container(s); strict verification passed"
