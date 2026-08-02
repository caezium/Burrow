#!/usr/bin/env bash

set -euo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::TAP_PAT is missing; Homebrew publication cannot be verified." >&2
  exit 1
fi

# The repository API's `.permissions.push` field describes the account's role,
# `git push --dry-run` sends no update, and a same-SHA ref update is treated as
# a no-op. Push a unique temporary ref through the same Git transport used by
# the release, verify it, then remove it before continuing. No commit is created
# and a successful probe leaves the tap exactly as it found it.
probe_root="$(
  mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/burrow-tap-write.XXXXXX"
)"
tap_dir="$probe_root/tap"
probe_branch="burrow-release-access-probe-${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-0}"
probe_ref="refs/heads/$probe_branch"
probe_created=false

cleanup_probe() {
  if [ "$probe_created" != true ]; then
    return 0
  fi

  if ! delete_output="$(
    git -C "$tap_dir" push --quiet origin ":$probe_ref" 2>&1
  )"; then
    printf '%s\n' "$delete_output" >&2
    echo "::error::Created $probe_ref but could not remove it from caezium/homebrew-tap." >&2
    return 1
  fi

  probe_created=false
}

cleanup_all() {
  cleanup_status=0
  cleanup_probe || cleanup_status=1
  rm -rf "$probe_root"
  return "$cleanup_status"
}
trap cleanup_all EXIT

export GIT_CONFIG_GLOBAL="$probe_root/gitconfig"
touch "$GIT_CONFIG_GLOBAL"

if ! gh auth setup-git; then
  echo "::error::Unable to configure Git authentication from TAP_PAT." >&2
  exit 1
fi

if ! (cd "$probe_root" && git clone --quiet --depth 1 \
  https://github.com/caezium/homebrew-tap.git tap); then
  echo "::error::TAP_PAT cannot clone caezium/homebrew-tap." >&2
  exit 1
fi

current_sha="$(git -C "$tap_dir" rev-parse HEAD)"
if ! push_output="$(
  git -C "$tap_dir" push --quiet origin "HEAD:$probe_ref" 2>&1
)"; then
  printf '%s\n' "$push_output" >&2
  if git -C "$tap_dir" ls-remote --exit-code --refs \
    origin "$probe_ref" >/dev/null 2>&1; then
    probe_created=true
  fi
  echo "::error::TAP_PAT cannot push to caezium/homebrew-tap. Replace it with a fine-grained token scoped only to that repository with Contents: Read and write." >&2
  exit 1
fi
probe_created=true

remote_sha="$(
  git -C "$tap_dir" ls-remote --exit-code --refs origin "$probe_ref" \
    | awk 'NR == 1 { print $1 }'
)"
if [ "$remote_sha" != "$current_sha" ]; then
  echo "::error::Homebrew tap write probe returned an unexpected ref SHA." >&2
  exit 1
fi

if ! cleanup_probe; then
  trap - EXIT
  rm -rf "$probe_root"
  exit 1
fi
trap - EXIT
rm -rf "$probe_root"

echo "Homebrew tap write access verified; the temporary ref was removed."
