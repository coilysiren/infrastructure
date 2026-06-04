#!/usr/bin/env bash
# kai-server-node-tooling-ensure.sh - guarantee the npm global tools the
# long-lived services depend on exist under the CURRENTLY-active nvm node.
#
# Why this exists:
#   nvm's default alias on kai-server is `lts/*` (a floating alias). When a
#   newer LTS node release lands, `source nvm.sh` resolves to the new
#   version, whose global node_modules is empty - so `claude` and `mcporter`
#   silently vanish from PATH. The claude-remote-control daemon's ExecStart
#   does `source nvm.sh && exec claude`, so the next restart hit
#   `exec: claude: not found` (exit 127), tripped StartLimitBurst, and the
#   daemon dropped out of the claude.ai/code Remote Control dropdown until a
#   manual reinstall + reset-failed.
#
#   This script reinstalls a static list of globals against whatever node
#   `nvm use default` resolves to today, so a node bump self-repairs on the
#   next daily tick instead of orphaning tooling.
#
# Invoked by kai-server-node-tooling-ensure.timer at 02:50 (before the 03:00
# remote-control restart), and on-demand via
# `coily systemctl start kai-server-node-tooling-ensure.service` or by
# running this script directly.
#
# Exit codes: 0 on success. Non-zero only on a genuine failure (nvm missing,
# npm install failed, claude still unresolved) so `systemctl status` flags
# it. The remote-control restart-precheck independently re-verifies claude
# resolves before restarting, so a failure here never tears down a working
# daemon.

set -uo pipefail

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  echo "FATAL: nvm.sh not found at $NVM_DIR/nvm.sh" >&2
  exit 1
fi

# nvm.sh is not shellcheck-clean and relies on unset vars; load it with the
# same lax options the daemon's ExecStart uses.
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# Land on the same node the daemon will: its ExecStart sources nvm.sh and
# lets the default alias decide. Activate it explicitly here so npm -g
# targets that version's global dir. `lts/*` is the configured default.
if ! nvm use default >/dev/null 2>&1; then
  if ! nvm use --lts >/dev/null 2>&1; then
    echo "FATAL: could not activate a default/LTS node via nvm" >&2
    exit 1
  fi
fi

echo "==> active node: $(command -v node) $(node -v 2>/dev/null) / npm $(npm -v 2>/dev/null)"

# Static list of globals that MUST exist under the active node version.
# npm and corepack ship bundled with node - do NOT list them here (npm
# manages its own version; corepack rides node). Add a tool here when a
# kai-server service starts depending on a new global CLI.
GLOBALS=(
  "@anthropic-ai/claude-code"
  "mcporter"
)

# `npm install -g pkg` resolves to @latest, so this doubles as the daily
# "keep current" step - no separate `npm update -g` needed for these. We
# deliberately skip `npm audit fix`: it operates on a project package.json,
# not the global prefix, so it is a no-op here and only adds noise.
echo "==> ensuring globals (install/update to latest): ${GLOBALS[*]}"
if ! npm install -g "${GLOBALS[@]}"; then
  echo "FATAL: npm install -g failed for one or more of: ${GLOBALS[*]}" >&2
  exit 1
fi

# Verify claude resolves the SAME way the daemon's non-login ExecStart will.
# This is the check that actually protects the dropdown.
if ! verify="$(/bin/bash -c 'source "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && command -v claude')" || [[ -z "$verify" ]]; then
  echo "FATAL: claude still not resolvable via 'source nvm.sh' after install" >&2
  exit 1
fi

echo "==> ok: claude at $verify ($(/bin/bash -c 'source "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && claude --version' 2>/dev/null))"
echo "==> ok: mcporter at $(command -v mcporter 2>/dev/null || echo MISSING)"
