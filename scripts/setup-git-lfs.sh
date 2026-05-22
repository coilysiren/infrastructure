#!/usr/bin/env bash
# setup-git-lfs.sh - wire Git LFS for the current user and re-smudge
# any already-degraded LFS files in the coilysiren checkouts.
#
# coilysiren-pull-all.sh wires `git lfs install` on every run so future
# pulls fetch real content. This script is the one-shot repair for a
# checkout that was pulled before the filters existed and now holds
# pointer text instead of binary assets. See
# coilysiren/infrastructure#286.
#
# Idempotent: `git lfs install --skip-repo` just rewrites the global
# filter config, and `git lfs pull` is a no-op once content is real.

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
