#!/usr/bin/env bash

set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::TAP_PAT is missing; Homebrew publication cannot be verified." >&2
  exit 1
fi

if ! permission="$(
  gh api repos/caezium/homebrew-tap --jq '.permissions.push'
)"; then
  echo "::error::Unable to verify TAP_PAT access to caezium/homebrew-tap." >&2
  exit 1
fi

if [ "$permission" != "true" ]; then
  echo "::error::TAP_PAT cannot push to caezium/homebrew-tap. Replace it with a fine-grained token scoped only to that repository with Contents: Read and write." >&2
  exit 1
fi

echo "Homebrew tap write access verified."
