#!/usr/bin/env bash
set -euo pipefail

target="${1:-docs/analytics.js}"
placeholder='__POSTHOG_PROJECT_KEY__'
project_key="${POSTHOG_API_KEY:-}"

if [[ ! -f "$target" ]]; then
  echo "::error::Website analytics source not found: $target" >&2
  exit 1
fi

if [[ ! "$project_key" =~ ^phc_[A-Za-z0-9]+$ ]]; then
  echo "::error::POSTHOG_API_KEY is missing or is not a PostHog project key." >&2
  exit 1
fi

placeholder_count="$( (grep -oF "$placeholder" "$target" || true) | wc -l | tr -d '[:space:]')"
if [[ "$placeholder_count" != "1" ]]; then
  echo "::error::Expected exactly one website analytics key placeholder; found $placeholder_count." >&2
  exit 1
fi

POSTHOG_API_KEY="$project_key" perl -0pi -e \
  's/\Q__POSTHOG_PROJECT_KEY__\E/$ENV{POSTHOG_API_KEY}/g' "$target"

if grep -qF "$placeholder" "$target"; then
  echo "::error::Website analytics key injection did not complete." >&2
  exit 1
fi

echo "Website analytics key injected."
