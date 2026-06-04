#!/usr/bin/env bash
# ExecCondition gate for the daily restart: skip (exit 1) unless the last
# coilysiren-pull-all run succeeded and finished. See docs/claude-remote-control.md.

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

# Second gate: verify `claude` resolves via `source nvm.sh` as the daemon will.
# A floating nvm default can orphan the global. See docs/claude-remote-control.md.
NVM_DIR="${NVM_DIR:-/home/kai/.nvm}"
if ! /bin/bash -c 'source "'"$NVM_DIR"'/nvm.sh" >/dev/null 2>&1 && command -v claude >/dev/null 2>&1'; then
  echo "claude not resolvable via 'source nvm.sh'; skipping restart to keep the live daemon up"
  exit 1
fi

echo "coilysiren-pull-all.service Result=success and claude resolves; proceeding with restart"
exit 0
