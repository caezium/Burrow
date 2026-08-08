#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != "1" || -z "$1" ]]; then
  echo "usage: $0 <empty-staging-directory>" >&2
  exit 2
fi

stage_dir="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -e "$stage_dir" ]]; then
  echo "::error::Website staging path already exists: $stage_dir" >&2
  exit 1
fi

mkdir -p "$stage_dir"
cp -R "$repo_root/docs/." "$stage_dir/"
bash "$repo_root/scripts/inject-site-analytics.sh" "$stage_dir/analytics.js"
