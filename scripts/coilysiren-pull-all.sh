#!/usr/bin/env bash
# coilysiren-pull-all.sh - fast-forward every git checkout under
# ~/projects/coilysiren on kai-server.
#
# Invoked by coilysiren-pull-all.timer daily, and on-demand via
# `coily systemctl start coilysiren-pull-all.service` or by running this
# script directly.
#
# Why: several long-lived services on kai-server read local checkouts
# directly:
#   - personal-dashboard.service reads agentic-os-kai/data/catalog-graph.yaml
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

# Git LFS: eco-mods and infrastructure track binary assets via LFS.
# Wire the global smudge/clean filters so every pull below fetches real
# content, not pointer files. Idempotent; warns if git-lfs is absent.
# See coilysiren/infrastructure#286.
if command -v git-lfs >/dev/null 2>&1; then
  git lfs install --skip-repo >/dev/null
else
  echo "WARN: git-lfs not installed; LFS repos will get pointer files" >&2
fi

pulled=0
skipped=0
failed=0
agentic_os_kai_ok=0

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
    if [[ "$name" == "agentic-os-kai" ]]; then
      agentic_os_kai_ok=1
    fi
  else
    echo "[$name] FAIL: non-ff (manual rebase/merge needed)"
    failed=$((failed+1))
  fi
done

# Refresh agentic-os-kai's host setup (skill symlinks, ~/.claude/CLAUDE.md,
# merged Claude settings) whenever its pull succeeded. setup.sh is
# idempotent and cheap. Picked up by the daily restart at 03:00, gated
# by claude-remote-control-restart-precheck.sh. See coilysiren/infrastructure#211.
if (( agentic_os_kai_ok == 1 )); then
  setup="$ROOT/agentic-os-kai/setup.sh"
  if [[ -x "$setup" ]]; then
    echo
    echo "[agentic-os-kai] running setup.sh..."
    if "$setup" >/dev/null; then
      echo "[agentic-os-kai] setup.sh ok"
    else
      echo "[agentic-os-kai] FAIL: setup.sh non-zero exit"
      failed=$((failed+1))
    fi
  else
    echo "[agentic-os-kai] SKIP: setup.sh not executable at $setup"
  fi
fi

echo
echo "pulled=$pulled skipped=$skipped failed=$failed"
# Exit non-zero only on a genuine failure so systemctl status flags it,
# not on routine skips (dirty trees, feature branches).
if (( failed > 0 )); then
  exit 2
fi
