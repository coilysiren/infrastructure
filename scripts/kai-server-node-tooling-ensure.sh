#!/usr/bin/env bash
# Reinstall the npm globals (claude, mcporter) under the active nvm node so a floating
# `lts/*` bump can't orphan them out of PATH and break the remote-control daemon.

# Runs daily via timer at 02:50 (before the 03:00 restart) or on demand. Non-zero exit
# only on genuine failure. See docs/claude-remote-control.md.

set -uo pipefail

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  echo "FATAL: nvm.sh not found at $NVM_DIR/nvm.sh" >&2
  exit 1
fi

# nvm.sh relies on unset vars, so load it lax, matching the daemon's ExecStart.
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# Land on the same node the daemon will (default `lts/*` alias) and activate it
# explicitly so npm -g targets that version's global dir.
if ! nvm use default >/dev/null 2>&1; then
  if ! nvm use --lts >/dev/null 2>&1; then
    echo "FATAL: could not activate a default/LTS node via nvm" >&2
    exit 1
  fi
fi

echo "==> active node: $(command -v node) $(node -v 2>/dev/null) / npm $(npm -v 2>/dev/null)"

# Globals that MUST exist under the active node version (omit bundled npm/corepack).
# Add a tool here when a kai-server service starts depending on a new global CLI.
GLOBALS=(
  "@anthropic-ai/claude-code"
  "mcporter"
)

# `npm install -g pkg` resolves to @latest, so this doubles as the daily keep-current
# step (no `npm update -g` needed). `npm audit fix` is skipped - it is a no-op here.
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
