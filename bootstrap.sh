#!/usr/bin/env bash
# Bare-host bootstrap: the one surviving script after setup.sh was retired.
# Seeds a host until ansible can take over, then runs the freshen play.

# Prereqs the operator provides first: git auth to forgejo.coilysiren.me (SSH key
# or a cached PAT) and AWS credentials (the roles read SSM). See docs/ansible.md.

# Idempotent: re-running clones only what is missing and re-converges.

set -euo pipefail

PROJECTS="${PROJECTS_ROOT:-$HOME/projects}"
FORGEJO="https://forgejo.coilysiren.me"

# Anchor repos the freshen play's early roles (shell, agent-compose, kai-config,
# skills) read before the repos role would clone the rest. org/name pairs.
ANCHORS=(
  "coilyco-flight-deck/infrastructure"
  "coilyco-flight-deck/agentic-os"
  "coilyco-bridge/agentic-os-kai"
)

echo "bootstrap: projects root $PROJECTS"

# 1. uv (drives ansible from the infrastructure uv env).
if ! command -v uv >/dev/null 2>&1; then
  echo "bootstrap: installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # shellcheck disable=SC1091
  . "$HOME/.local/bin/env" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
fi

# 2. Clone the anchor repos into ~/projects/<org>/<name> if absent.
for slug in "${ANCHORS[@]}"; do
  dest="$PROJECTS/$slug"
  if [ -d "$dest/.git" ]; then
    echo "bootstrap: have $slug"
  else
    echo "bootstrap: cloning $slug"
    mkdir -p "$(dirname "$dest")"
    git clone "$FORGEJO/$slug.git" "$dest"
  fi
done

# 3. Sync the infrastructure uv env (installs ansible + community.general).
INFRA="$PROJECTS/coilyco-flight-deck/infrastructure"
echo "bootstrap: uv sync in $INFRA"
( cd "$INFRA" && uv sync )

# 4. Hand off to ansible. From here the freshen play converges everything,
# including cloning any remaining repos via the repos role.
echo "bootstrap: converging host via ansible freshen (apply)"
( cd "$INFRA" && uv run python scripts/ansible/freshen.py apply )

echo "bootstrap: done. Host is ansible-managed; re-converge anytime with"
echo "  coily ansible-freshen            # or: uv run python scripts/ansible/freshen.py apply"
