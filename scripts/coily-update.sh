#!/usr/bin/env bash
# coily-update.sh - brew-upgrade coily and re-baseline its setup.
#
# Invoked by coily-update.timer weekly, and on-demand via
# `coily systemctl start coily-update.service` after a tap push so the new
# version lands without waiting for the next timer fire.
#
# Failure mode: any non-zero exit lights up `systemctl status` with the
# usual "Failed" line; check `journalctl -u coily-update.service` for the
# full output. brew-upgrade failure leaves the previously installed binary
# in place.

set -euo pipefail

# Non-interactive shells skip ~/.bashrc, so brew is not on PATH by
# default. Source shellenv explicitly.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

echo "==> brew update"
brew update

echo "==> brew upgrade coilysiren/tap/coily"
brew upgrade coilysiren/tap/coily

echo "==> coily setup (lockdown root: ${COILY_LOCKDOWN_ROOT:-unset})"
coily setup

echo "==> coily version"
coily version
