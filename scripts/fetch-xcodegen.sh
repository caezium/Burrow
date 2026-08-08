#!/usr/bin/env bash
# Install the exact checksum-pinned XcodeGen release used by CI and releases.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$#" -eq 1 ] && [ -n "$1" ] \
  || { echo "usage: $0 <destination-directory>" >&2; exit 2; }
DEST="$1"
[ ! -e "$DEST" ] \
  || { echo "error: XcodeGen destination already exists: $DEST" >&2; exit 2; }

VERSION="$(python3 scripts/release-input.py tools.xcodegen.version)"
URL="$(python3 scripts/release-input.py tools.xcodegen.url)"
SHA256="$(python3 scripts/release-input.py tools.xcodegen.sha256)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fSL --retry 5 --retry-delay 3 --retry-all-errors \
  --connect-timeout 30 --max-time 300 -o "$TMP/xcodegen.zip" "$URL"
GOT="$(shasum -a 256 "$TMP/xcodegen.zip" | awk '{print $1}')"
[ "$GOT" = "$SHA256" ] \
  || { echo "error: XcodeGen checksum mismatch (got $GOT, want $SHA256)" >&2; exit 1; }

unzip -q "$TMP/xcodegen.zip" -d "$TMP/unpacked"
[ -x "$TMP/unpacked/xcodegen/bin/xcodegen" ] \
  || { echo "error: XcodeGen archive is missing bin/xcodegen" >&2; exit 1; }
ACTUAL="$("$TMP/unpacked/xcodegen/bin/xcodegen" --version | awk '{print $NF}')"
[ "$ACTUAL" = "$VERSION" ] \
  || { echo "error: XcodeGen binary is $ACTUAL, expected $VERSION" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
mv "$TMP/unpacked/xcodegen" "$DEST"
echo "==> installed checksum-pinned XcodeGen $VERSION at $DEST"
