#!/usr/bin/env bash
# Fast-forward every git checkout under ~/projects/coilysiren on kai-server so
# services don't run on stale trees. Skips dirty/detached/non-default; runs daily.

set -uo pipefail

ROOT="${ROOT:-/home/kai/projects/coilysiren}"

if [[ ! -d "$ROOT" ]]; then
  echo "no such root: $ROOT" >&2
  exit 1
fi

# Wire global LFS filters so pulls fetch real content, not pointers (eco-mods +
# infrastructure track LFS assets). Idempotent (coilyco-flight-deck/infrastructure#286).
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

# Re-run agentic-os-kai/setup.sh (skill symlinks, CLAUDE.md, Claude settings)
# whenever its pull succeeded. Idempotent (coilyco-flight-deck/infrastructure#211).
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
