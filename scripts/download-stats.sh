#!/usr/bin/env bash
# Burrow download stats — zero telemetry, just GitHub's own release counts.
# Sums asset downloads per release (and a grand total) via the public API.
#
# Usage:
#   scripts/download-stats.sh                 # uses caezium/Burrow
#   REPO=owner/name scripts/download-stats.sh
#
# Needs `gh` (authenticated) or falls back to anonymous curl + jq.
set -euo pipefail

REPO="${REPO:-caezium/Burrow}"

fetch() {
  if command -v gh >/dev/null 2>&1; then
    # gh that's installed but unauthenticated/rate-limited exits non-zero;
    # fall through to anonymous curl instead of dying under `set -e`.
    if out=$(gh api --paginate "repos/$REPO/releases" 2>/dev/null); then
      printf '%s' "$out"
      return
    fi
  fi
  curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100"
}

command -v jq >/dev/null 2>&1 || { echo "needs jq (brew install jq)" >&2; exit 1; }

echo "Download counts for $REPO"
echo "----------------------------------------"
fetch | jq -r '
  ( if type == "array" then . else [.] end )
  | map(select(type == "object" and has("tag_name")))
  | sort_by(.published_at) | reverse
  | (.[] | "\(.tag_name)\t\([.assets[]?.download_count] | add // 0) downloads"),
    "----------------------------------------",
    "TOTAL\t\([.[].assets[]?.download_count] | add // 0) downloads"
' | column -t -s $'\t'
