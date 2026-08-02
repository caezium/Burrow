#!/usr/bin/env bash

set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::TAP_PAT is missing; Homebrew publication cannot be verified." >&2
  exit 1
fi

if ! gh api repos/caezium/homebrew-tap >/dev/null; then
  echo "::error::TAP_PAT cannot read caezium/homebrew-tap." >&2
  exit 1
fi

if ! gh auth setup-git; then
  echo "::error::Unable to configure Git authentication from TAP_PAT." >&2
  exit 1
fi

probe_root="$(
  mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/burrow-tap-write.XXXXXX"
)"
trap 'rm -rf "$probe_root"' EXIT
tap_dir="$probe_root/tap"

if ! git clone --quiet --depth 1 \
  https://github.com/caezium/homebrew-tap.git "$tap_dir"; then
  echo "::error::TAP_PAT cannot clone caezium/homebrew-tap." >&2
  exit 1
fi

# The repository API's `.permissions.push` field describes the account's role,
# not a fine-grained token's Contents scope. Exercise the same receive-pack
# authorization as the release's final push, but --dry-run guarantees this
# probe creates no branch or commit on the external tap.
probe_ref="refs/heads/burrow-release-access-probe-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
if ! push_output="$(
  git -C "$tap_dir" push --dry-run origin "HEAD:$probe_ref" 2>&1
)"; then
  printf '%s\n' "$push_output" >&2
  echo "::error::TAP_PAT cannot push to caezium/homebrew-tap. Replace it with a fine-grained token scoped only to that repository with Contents: Read and write." >&2
  exit 1
fi

echo "Homebrew tap write access verified with a non-mutating Git dry run."
