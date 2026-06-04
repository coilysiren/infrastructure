#!/usr/bin/env bash
# brew-upgrade personal-dashboard and try-restart the daemon. Runs daily via timer
# or on demand after a tap push.

# A brew-upgrade failure exits non-zero before the restart, so the running daemon
# keeps serving the previous binary and `systemctl status` surfaces the failure.

set -euo pipefail

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

echo "==> brew update"
brew update

echo "==> brew tap + upgrade coilysiren/personal-dashboard/personal-dashboard"
brew tap coilysiren/personal-dashboard https://github.com/coilysiren/personal-dashboard
brew upgrade coilysiren/personal-dashboard/personal-dashboard

echo "==> try-restart personal-dashboard.service"
# is-active gate gives try-restart semantics: don't start a stopped daemon on upgrade.
# coily systemctl lacks try-restart, so the unprivileged guard sits outside the wrapper.
if systemctl is-active --quiet personal-dashboard.service; then
  coily systemctl restart personal-dashboard.service
else
  echo "personal-dashboard.service inactive; skipping restart"
fi

echo "==> personal-dashboard --help (smoke)"
personal-dashboard --help 2>&1 | head -3 || true
