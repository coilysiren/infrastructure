#!/usr/bin/env bash
# Bootstrap /home/kai/projects/coilysiren/ on kai-server with the coilysiren/*
# repo set. Idempotent: clones missing, fetches existing, skips dirty trees.

set -euo pipefail

ROOT="${ROOT:-/home/kai/projects/coilysiren}"
ORG="coilysiren"
FORGEJO_HOST="forgejo.coilysiren.me"

# Forgejo is the canonical upstream and GitHub a downstream mirror. Wire origin
# so a single push fans out to both. See ansible/library/repo_status.py.
wire_dual_push() {
  local name="$1"
  local gh_url="git@github.com:${ORG}/${name}.git"
  local fj_url="https://${FORGEJO_HOST}/${ORG}/${name}.git"
  local pushes
  pushes="$(git -C "$name" remote get-url --push --all origin 2>/dev/null)"
  if ! grep -qxF "$gh_url" <<<"$pushes" || ! grep -qxF "$fj_url" <<<"$pushes"; then
    git -C "$name" config --unset-all remote.origin.pushurl 2>/dev/null || true
    git -C "$name" remote set-url --add --push origin "$gh_url"
    git -C "$name" remote set-url --add --push origin "$fj_url"
  fi
  git -C "$name" remote | grep -qx forgejo || git -C "$name" remote add forgejo "$fj_url"
}

REPOS=(
  backend
  coily
  agentic-os-kai
  coilysiren
  eco-configs
  eco-cycle-prep
  eco-mcp-app
  eco-mods
  eco-mods-public
  eco-jobs-tracker
  eco-telemetry
  galaxy-gen
  gauntlet
  homebrew-tap
  infrastructure
  kai-server
  luca
  message-ops
  repo-recall
  sirens-discord-ops
  website
)

mkdir -p "$ROOT"
cd "$ROOT"

cloned=0
fetched=0
skipped_dirty=0
failed=0

for name in "${REPOS[@]}"; do
  if [[ ! -d "$name/.git" ]]; then
    echo ">>> cloning $name"
    if git clone "git@github.com:${ORG}/${name}.git" "$name"; then
      wire_dual_push "$name"
      cloned=$((cloned + 1))
    else
      echo "!!! clone failed: $name" >&2
      failed=$((failed + 1))
    fi
    continue
  fi

  echo ">>> fetching $name"
  if ! git -C "$name" fetch --all --prune --quiet; then
    echo "!!! fetch failed: $name" >&2
    failed=$((failed + 1))
    continue
  fi
  fetched=$((fetched + 1))
  wire_dual_push "$name"

  if [[ -n "$(git -C "$name" status --porcelain)" ]]; then
    echo "    dirty working tree, leaving alone"
    skipped_dirty=$((skipped_dirty + 1))
  fi
done

echo
echo "summary: cloned=$cloned fetched=$fetched dirty=$skipped_dirty failed=$failed"
[[ $failed -eq 0 ]]
