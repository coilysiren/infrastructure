#!/usr/bin/env bash
# personal-dashboard-update.sh - brew-upgrade personal-dashboard and
# try-restart the long-lived daemon unit.
#
# Invoked by personal-dashboard-update.timer daily, and on-demand via
# `sudo systemctl start personal-dashboard-update.service` after a tap
# push.
#
# Failure mode: brew-upgrade failure exits non-zero before the restart,
# leaving the running daemon untouched. `systemctl status
# personal-dashboard-update.service` surfaces the failure; the existing
# personal-dashboard.service keeps serving the previous binary.

set -euo pipefail

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

echo "==> brew update"
brew update

echo "==> brew upgrade coilysiren/tap/personal-dashboard"
brew upgrade coilysiren/tap/personal-dashboard

echo "==> try-restart personal-dashboard.service"
# try-restart is a no-op if the unit isn't already active, which matches
# the intent: don't start a stopped daemon as a side effect of upgrading.
sudo /bin/systemctl try-restart personal-dashboard.service

echo "==> personal-dashboard --help (smoke)"
personal-dashboard --help 2>&1 | head -3 || true
