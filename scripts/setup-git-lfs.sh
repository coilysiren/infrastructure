#!/usr/bin/env bash
# Wire Git LFS for the current user and re-smudge any already-degraded LFS files in the
# coilysiren checkouts (one-shot repair for checkouts pulled before the filters existed).

# Idempotent: install --skip-repo just rewrites global filter config, lfs pull is a
# no-op once content is real. See infrastructure#286.

set -euo pipefail

if ! command -v git-lfs >/dev/null 2>&1; then
  echo "git-lfs not installed - run: coily pkg brew install git-lfs --allow-untapped" >&2
  exit 1
fi

git lfs install --skip-repo
echo "git lfs: global smudge/clean filters wired for $(whoami)"

# Parent of the infrastructure checkout - holds every coilysiren repo.
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

for git_dir in "$ROOT"/*/.git; do
  repo="$(dirname "$git_dir")"
  name="$(basename "$repo")"
  attrs="$repo/.gitattributes"
  if [[ -f "$attrs" ]] && grep -q 'filter=lfs' "$attrs"; then
    git -C "$repo" lfs pull
    echo "[$name] LFS content refreshed"
  fi
done
