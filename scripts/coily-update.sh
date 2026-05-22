#!/usr/bin/env bash
# coily-update.sh - brew-upgrade coily plus every other formula, then
# re-baseline coily's setup.
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

# brew update can race the global brew lock on boot when multiple
# *-update.service units fire near-simultaneously after reboot
# (coilysiren/coily#240). Retry with linear backoff; six attempts at
# 10s spacing covers the 1-min window the racing units typically
# share without unbounded waiting.
echo "==> brew update"
for attempt in 1 2 3 4 5 6; do
  if brew update; then
    break
  fi
  if [ "$attempt" -ge 6 ]; then
    echo "brew update: gave up after $attempt attempts" >&2
    exit 1
  fi
  echo "brew update: attempt $attempt failed; another brew process may hold the lock; retrying in 10s" >&2
  sleep 10
done

echo "==> brew tap + upgrade coilysiren/coily/coily"
brew tap coilysiren/coily https://github.com/coilysiren/coily
brew upgrade coilysiren/coily/coily

# Keep every other Linuxbrew formula on kai-server current too, not just
# coily. Runs after the targeted coily upgrade so coily still lands even
# if a later formula's upgrade fails and trips set -e.
echo "==> brew upgrade (all formulae)"
brew upgrade

echo "==> coily setup (lockdown root: ${COILY_LOCKDOWN_ROOT:-unset})"
coily setup

echo "==> coily version"
coily version
