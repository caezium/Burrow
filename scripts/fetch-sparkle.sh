#!/usr/bin/env bash
#
# fetch-sparkle.sh — vendor Sparkle's official universal framework locally.
#
# Sparkle's Swift package is a thin wrapper around a binary artifact. On the
# GitHub macOS release runner, SwiftPM checks out Sparkle and then hangs forever
# while resolving that artifact; two v0.11.0 release attempts reached the
# 38-minute hard timeout before compilation. curl downloads the same official
# release archive reliably, so fetch it explicitly, pin its checksum, validate
# the framework, and keep SwiftPM responsible only for source packages.
#
# Usage:
#   fetch-sparkle.sh                    # install macos/vendor/Sparkle.framework
#   fetch-sparkle.sh --tools <dir>      # install the matching release tools
#
# The verified release archive is cached locally, but its full SHA-256 is
# checked on every invocation and outputs are always re-extracted from it. An
# ignored marker file cannot make modified framework contents look trusted.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 scripts/release-input.py frameworks.sparkle.version)"
# Framework and appcast tools both come through this single content pin.
SHA256="$(python3 scripts/release-input.py frameworks.sparkle.sha256)"
URL="$(python3 scripts/release-input.py frameworks.sparkle.url)"
DEST="macos/vendor/Sparkle.framework"
CACHE_DIR="macos/vendor/.sparkle-cache"
ARCHIVE="$CACHE_DIR/Sparkle-${VERSION}.tar.xz"

MODE="framework"
TOOLS_DEST=""
case "$#" in
  0) ;;
  2)
    if [ "$1" != "--tools" ] || [ -z "$2" ]; then
      echo "usage: $0 [--tools <destination>]" >&2
      exit 2
    fi
    MODE="tools"
    TOOLS_DEST="$2"
    ;;
  *)
    echo "usage: $0 [--tools <destination>]" >&2
    exit 2
    ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ensure_archive() {
  local got

  if [ -f "$ARCHIVE" ]; then
    got="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
    if [ "$got" = "$SHA256" ]; then
      echo "==> verified cached Sparkle ${VERSION} release archive"
      return
    fi
    echo "warning: cached Sparkle archive checksum is $got; downloading a clean copy" >&2
  fi

  echo "==> fetching Sparkle ${VERSION} release archive"
  curl -fSL --retry 5 --retry-delay 3 --retry-all-errors \
    --connect-timeout 30 --max-time 300 \
    -o "$TMP/Sparkle.tar.xz" "$URL"

  got="$(shasum -a 256 "$TMP/Sparkle.tar.xz" | awk '{print $1}')"
  if [ "$got" != "$SHA256" ]; then
    echo "error: Sparkle release checksum mismatch (got $got, want $SHA256)" >&2
    exit 1
  fi

  mkdir -p "$CACHE_DIR"
  mv -f "$TMP/Sparkle.tar.xz" "$ARCHIVE"
}

validate_framework() {
  local framework="$1"
  local binary="$framework/Sparkle"
  local info="$framework/Resources/Info.plist"
  local actual_version arches

  [ -f "$binary" ] \
    || { echo "error: Sparkle framework binary is missing: $binary" >&2; return 1; }
  [ -f "$info" ] \
    || { echo "error: Sparkle framework Info.plist is missing: $info" >&2; return 1; }
  [ -x "$framework/Autoupdate" ] \
    || { echo "error: Sparkle Autoupdate helper is missing" >&2; return 1; }
  [ -x "$framework/Updater.app/Contents/MacOS/Updater" ] \
    || { echo "error: Sparkle Updater helper is missing" >&2; return 1; }
  [ -x "$framework/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" ] \
    || { echo "error: Sparkle Downloader XPC service is missing" >&2; return 1; }
  [ -x "$framework/XPCServices/Installer.xpc/Contents/MacOS/Installer" ] \
    || { echo "error: Sparkle Installer XPC service is missing" >&2; return 1; }

  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
  [ "$actual_version" = "$VERSION" ] \
    || { echo "error: Sparkle framework version is $actual_version, expected $VERSION" >&2; return 1; }

  arches="$(lipo -archs "$binary")"
  [[ " $arches " == *" arm64 "* ]] \
    || { echo "error: Sparkle framework is missing arm64: $arches" >&2; return 1; }
  [[ " $arches " == *" x86_64 "* ]] \
    || { echo "error: Sparkle framework is missing x86_64: $arches" >&2; return 1; }

  codesign --verify --deep --strict "$framework" 2>/dev/null \
    || { echo "error: Sparkle framework's distributed signature is invalid" >&2; return 1; }
}

ensure_archive

if [ "$MODE" = "tools" ]; then
  [ ! -e "$TOOLS_DEST" ] \
    || { echo "error: Sparkle tools destination already exists: $TOOLS_DEST" >&2; exit 2; }
  mkdir -p "$TMP/tools"
  tar -xf "$ARCHIVE" -C "$TMP/tools" ./bin
  [ -x "$TMP/tools/bin/generate_appcast" ] && [ -x "$TMP/tools/bin/sign_update" ] \
    || { echo "error: Sparkle release archive is missing required tools" >&2; exit 1; }
  mkdir -p "$(dirname "$TOOLS_DEST")"
  mv "$TMP/tools" "$TOOLS_DEST"
  echo "==> installed Sparkle ${VERSION} release tools at $TOOLS_DEST/bin"
  exit 0
fi

mkdir -p "$TMP/unpacked"
tar -xf "$ARCHIVE" -C "$TMP/unpacked" ./Sparkle.framework
validate_framework "$TMP/unpacked/Sparkle.framework"
mkdir -p macos/vendor
rm -rf "$DEST"
mv "$TMP/unpacked/Sparkle.framework" "$DEST"
echo "==> vendored $DEST"
