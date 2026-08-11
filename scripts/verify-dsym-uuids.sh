#!/usr/bin/env bash
# Prove that a release app binary and its dSYM describe exactly the same slices.
set -euo pipefail

[ "$#" -eq 2 ] \
  || { echo "usage: $0 <Burrow.app> <Burrow.app.dSYM>" >&2; exit 2; }

APP="$1"
DSYM="$2"
BINARY="$APP/Contents/MacOS/Burrow"
DEBUG_BINARY="$DSYM/Contents/Resources/DWARF/Burrow"

[ -f "$BINARY" ] \
  || { echo "error: release binary is missing: $BINARY" >&2; exit 1; }
[ -f "$DEBUG_BINARY" ] \
  || { echo "error: release dSYM is missing its DWARF binary: $DEBUG_BINARY" >&2; exit 1; }

uuids() {
  dwarfdump --uuid "$1" \
    | awk '/^UUID: / { print toupper($2) " " $3 }' \
    | LC_ALL=C sort -u
}

APP_UUIDS="$(uuids "$BINARY")"
DSYM_UUIDS="$(uuids "$DEBUG_BINARY")"
[ -n "$APP_UUIDS" ] \
  || { echo "error: release binary has no Mach-O UUID" >&2; exit 1; }
[ -n "$DSYM_UUIDS" ] \
  || { echo "error: release dSYM has no UUID" >&2; exit 1; }

if [ "$APP_UUIDS" != "$DSYM_UUIDS" ]; then
  echo "error: release binary and dSYM UUIDs differ" >&2
  printf 'app:\n%s\ndSYM:\n%s\n' "$APP_UUIDS" "$DSYM_UUIDS" >&2
  exit 1
fi

printf 'release binary/dSYM UUIDs match:\n%s\n' "$APP_UUIDS"
