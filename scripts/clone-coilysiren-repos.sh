#!/usr/bin/env bash
# Bootstrap /home/kai/projects/coilysiren/ on kai-server with the active
# coilysiren/* repo set. Idempotent: clones missing repos, fetches existing
# ones. Never auto-pulls dirty checkouts.
#
# Drives: repo-recall's kai-server instance (infrastructure#69, infrastructure#68).
# Mirrors the workspace layout used on the Mac and the new Windows path.
# coilyco-vault is intentionally excluded (not in git).

set -euo pipefail

ROOT="${ROOT:-/home/kai/projects/coilysiren}"
ORG="coilysiren"

REPOS=(
  backend
  coily
  coilyco-ai
  coilysiren
  drift
  eco-configs
  eco-cycle-prep
  eco-mcp-app
  eco-mods
  eco-mods-public
  eco-spec-tracker
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

  if [[ -n "$(git -C "$name" status --porcelain)" ]]; then
    echo "    dirty working tree, leaving alone"
    skipped_dirty=$((skipped_dirty + 1))
  fi
done

echo
echo "summary: cloned=$cloned fetched=$fetched dirty=$skipped_dirty failed=$failed"
[[ $failed -eq 0 ]]
