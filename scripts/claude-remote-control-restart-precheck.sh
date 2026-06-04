#!/usr/bin/env bash
# claude-remote-control-restart-precheck.sh - ExecCondition gate for the
# daily claude-remote-control restart.
#
# Verifies the most recent coilysiren-pull-all.service run succeeded and
# is not still running. If either check fails, skip the restart so the
# daemon keeps running on yesterday's tree instead of restarting into a
# bad / mid-pull state.
#
# Exit codes (per systemd ExecCondition semantics):
#   0       proceed with the unit's ExecStart
#   1-254   skip the unit silently, log the journal entry
#   255     hard fail the unit
#
# Returns 1 (skip) on any not-success condition. The journal line is the
# operator's signal to look at why pull-all is unhappy.
#
# See coilyco-flight-deck/infrastructure#211, coilyco-bridge/agentic-os-kai#612.

set -uo pipefail

if systemctl is-active --quiet coilysiren-pull-all.service; then
  echo "coilysiren-pull-all.service is still active; skipping restart this cycle"
  exit 1
fi

result="$(systemctl show coilysiren-pull-all.service -p Result --value 2>/dev/null || true)"

if [[ "$result" != "success" ]]; then
  echo "coilysiren-pull-all.service Result=${result:-unknown}; skipping restart"
  exit 1
fi

# Second gate: verify `claude` resolves the SAME way the daemon's non-login
# ExecStart will (`source nvm.sh && exec claude`). A floating nvm default
# (lts/*) can orphan the global on a node bump, and restarting into that
# state is exactly what dropped kai-server out of the Remote Control
# dropdown. Refuse the restart so the currently-running daemon keeps serving
# until kai-server-node-tooling-ensure.service has reinstalled the global.
NVM_DIR="${NVM_DIR:-/home/kai/.nvm}"
if ! /bin/bash -c 'source "'"$NVM_DIR"'/nvm.sh" >/dev/null 2>&1 && command -v claude >/dev/null 2>&1'; then
  echo "claude not resolvable via 'source nvm.sh'; skipping restart to keep the live daemon up"
  exit 1
fi

echo "coilysiren-pull-all.service Result=success and claude resolves; proceeding with restart"
exit 0
