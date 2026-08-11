#!/usr/bin/env bash
# Install the exact checksum-pinned universal sentry-cli used for dSYM upload.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$#" -eq 1 ] && [ -n "$1" ] \
  || { echo "usage: $0 <destination-file>" >&2; exit 2; }
DEST="$1"
[ ! -e "$DEST" ] \
  || { echo "error: sentry-cli destination already exists: $DEST" >&2; exit 2; }

VERSION="$(python3 scripts/release-input.py tools.sentry-cli.version)"
URL="$(python3 scripts/release-input.py tools.sentry-cli.url)"
SHA256="$(python3 scripts/release-input.py tools.sentry-cli.sha256)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fSL --retry 5 --retry-delay 3 --retry-all-errors \
  --connect-timeout 30 --max-time 300 -o "$TMP/sentry-cli" "$URL"
GOT="$(shasum -a 256 "$TMP/sentry-cli" | awk '{print $1}')"
[ "$GOT" = "$SHA256" ] \
  || { echo "error: sentry-cli checksum mismatch (got $GOT, want $SHA256)" >&2; exit 1; }
chmod 0755 "$TMP/sentry-cli"
ACTUAL="$("$TMP/sentry-cli" --version | awk '{print $NF}')"
[ "$ACTUAL" = "$VERSION" ] \
  || { echo "error: sentry-cli binary is $ACTUAL, expected $VERSION" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
mv "$TMP/sentry-cli" "$DEST"
echo "==> installed checksum-pinned sentry-cli $VERSION at $DEST"
