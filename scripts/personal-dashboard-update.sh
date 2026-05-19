#!/usr/bin/env bash
# personal-dashboard-update.sh - brew-upgrade personal-dashboard and
# try-restart the long-lived daemon unit.
#
# Invoked by personal-dashboard-update.timer daily, and on-demand via
# `coily systemctl start personal-dashboard-update.service` after a tap
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
# is-active gate matches the try-restart semantics: don't start a stopped
# daemon as a side effect of upgrading. coily systemctl doesn't expose
# try-restart, so the guard sits outside the wrapper. is-active reads
# cached systemd state unprivileged.
if systemctl is-active --quiet personal-dashboard.service; then
  coily systemctl restart personal-dashboard.service
else
  echo "personal-dashboard.service inactive; skipping restart"
fi

echo "==> personal-dashboard --help (smoke)"
personal-dashboard --help 2>&1 | head -3 || true
