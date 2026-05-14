#!/usr/bin/env bash
# coilysiren-pull-all.sh - fast-forward every git checkout under
# ~/projects/coilysiren on kai-server.
#
# Invoked by coilysiren-pull-all.timer daily, and on-demand via
# `sudo systemctl start coilysiren-pull-all.service` or by running this
# script directly.
#
# Why: several long-lived services on kai-server read local checkouts
# directly:
#   - personal-dashboard.service reads coilyco-ai/data/catalog-graph.yaml
#   - coily ssh deploy <target> calls scripts under infrastructure
#   - eco-mods rsync deploys read from eco-mods / eco-mods-public
# Stale checkouts silently feed stale data to running services.
#
# Skips with a one-line warning when:
#   - working tree is dirty
#   - HEAD is detached
#   - current branch is not the remote's default branch
# Failures on a single repo do not abort the sweep.

set -uo pipefail

ROOT="${ROOT:-/home/kai/projects/coilysiren}"

if [[ ! -d "$ROOT" ]]; then
  echo "no such root: $ROOT" >&2
  exit 1
fi

pulled=0
skipped=0
failed=0

for git_dir in "$ROOT"/*/.git; do
  repo_dir="$(dirname "$git_dir")"
  name="$(basename "$repo_dir")"

  if ! current="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    echo "[$name] SKIP: not a usable git checkout"
    skipped=$((skipped+1))
    continue
  fi

  if [[ "$current" == "HEAD" ]]; then
    echo "[$name] SKIP: detached HEAD"
    skipped=$((skipped+1))
    continue
  fi

  if [[ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]; then
    echo "[$name] SKIP: working tree dirty"
    skipped=$((skipped+1))
    continue
  fi

  # The remote default branch can drift from main; ask the remote.
  default="$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  default="${default:-main}"
  if [[ "$current" != "$default" ]]; then
    echo "[$name] SKIP: on $current (default $default)"
    skipped=$((skipped+1))
    continue
  fi

  if ! git -C "$repo_dir" fetch --quiet --prune origin 2>/dev/null; then
    echo "[$name] FAIL: fetch"
    failed=$((failed+1))
    continue
  fi

  if git -C "$repo_dir" pull --ff-only --quiet 2>/dev/null; then
    echo "[$name] ok"
    pulled=$((pulled+1))
  else
    echo "[$name] FAIL: non-ff (manual rebase/merge needed)"
    failed=$((failed+1))
  fi
done

echo
echo "pulled=$pulled skipped=$skipped failed=$failed"
# Exit non-zero only on a genuine failure so systemctl status flags it,
# not on routine skips (dirty trees, feature branches).
if (( failed > 0 )); then
  exit 2
fi
