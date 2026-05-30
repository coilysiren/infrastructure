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

if [[ "$result" == "success" ]]; then
  echo "coilysiren-pull-all.service Result=success; proceeding with restart"
  exit 0
fi

echo "coilysiren-pull-all.service Result=${result:-unknown}; skipping restart"
exit 1
