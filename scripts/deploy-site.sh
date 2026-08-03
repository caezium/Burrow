#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/burrow-site-deploy.XXXXXX")"
stage_dir="$temporary_root/assets"
trap 'rm -rf -- "$temporary_root"' EXIT

bash "$repo_root/scripts/prepare-site-assets.sh" "$stage_dir"

cd "$repo_root"
npx wrangler deploy --assets "$stage_dir"
