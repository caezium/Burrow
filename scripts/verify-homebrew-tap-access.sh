#!/usr/bin/env bash

set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::TAP_PAT is missing; Homebrew publication cannot be verified." >&2
  exit 1
fi

if ! current_sha="$(
  gh api repos/caezium/homebrew-tap/git/ref/heads/main --jq '.object.sha'
)"; then
  echo "::error::TAP_PAT cannot read caezium/homebrew-tap." >&2
  exit 1
fi

# The repository API's `.permissions.push` field describes the account's role,
# and `git push --dry-run` does not send an update for GitHub to authorize.
# GitHub documents the Update a reference endpoint as requiring fine-grained
# Contents: write. Pointing main at its exact current SHA exercises that write
# endpoint without moving the ref, creating a commit, or triggering a release.
if ! verified_sha="$(
  gh api --method PATCH \
    repos/caezium/homebrew-tap/git/refs/heads/main \
    -f sha="$current_sha" \
    -F force=false \
    --jq '.object.sha'
)"; then
  echo "::error::TAP_PAT cannot push to caezium/homebrew-tap. Replace it with a fine-grained token scoped only to that repository with Contents: Read and write." >&2
  exit 1
fi

if [ "$verified_sha" != "$current_sha" ]; then
  echo "::error::Homebrew tap write probe returned an unexpected ref SHA." >&2
  exit 1
fi

echo "Homebrew tap write access verified without moving its main ref."
