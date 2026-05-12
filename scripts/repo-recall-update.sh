#!/usr/bin/env bash
# repo-recall-update.sh - brew-upgrade repo-recall and try-restart the
# long-lived daemon unit.
#
# Invoked by repo-recall-update.timer weekly, and on-demand via
# `sudo systemctl start repo-recall-update.service` after a tap push.
#
# Failure mode: brew-upgrade failure exits non-zero before the restart,
# leaving the running daemon untouched. `systemctl status
# repo-recall-update.service` surfaces the failure; the existing
# repo-recall.service keeps serving the previous binary.

set -euo pipefail

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

echo "==> brew update"
brew update

echo "==> brew upgrade coilysiren/tap/repo-recall"
brew upgrade coilysiren/tap/repo-recall

echo "==> try-restart repo-recall.service"
# try-restart is a no-op if the unit isn't already active, which matches
# the intent: don't start a stopped daemon as a side effect of upgrading.
sudo /bin/systemctl try-restart repo-recall.service

echo "==> repo-recall --version"
repo-recall --version || true
