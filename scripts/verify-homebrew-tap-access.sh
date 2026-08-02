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
# `git push --dry-run` sends no update, and a same-SHA ref update is treated as
# a no-op. Create a unique temporary ref so GitHub must authorize a real write,
# then remove it before continuing. No commit is created and a successful probe
# leaves the tap exactly as it found it.
probe_branch="burrow-release-access-probe-${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-0}"
probe_ref="refs/heads/$probe_branch"
probe_created=false

cleanup_probe() {
  if [ "$probe_created" != true ]; then
    return 0
  fi

  if ! gh api --method DELETE \
    "repos/caezium/homebrew-tap/git/refs/heads/$probe_branch" >/dev/null; then
    echo "::error::Created $probe_ref but could not remove it from caezium/homebrew-tap." >&2
    return 1
  fi

  probe_created=false
}
trap cleanup_probe EXIT

if ! created_ref="$(
  gh api --method POST \
    repos/caezium/homebrew-tap/git/refs \
    -f ref="$probe_ref" \
    -f sha="$current_sha" \
    --jq '.ref'
)"; then
  echo "::error::TAP_PAT cannot create a temporary ref in caezium/homebrew-tap. Replace it with a fine-grained token scoped only to that repository with Contents: Read and write." >&2
  exit 1
fi
probe_created=true

if [ "$created_ref" != "$probe_ref" ]; then
  echo "::error::Homebrew tap write probe created an unexpected ref." >&2
  exit 1
fi

if ! cleanup_probe; then
  trap - EXIT
  exit 1
fi
trap - EXIT

echo "Homebrew tap write access verified; the temporary ref was removed."
