#!/usr/bin/env bash
# Brew-upgrade coily plus every other formula, then re-baseline `coily setup`.
# Run weekly by coily-update.timer, or on-demand after a tap push.

set -euo pipefail

# Non-interactive shells skip ~/.bashrc, so source brew shellenv explicitly.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# brew update can race the global brew lock on boot (coilyco-bridge/coily#240).
# Retry six times at 10s spacing to cover the ~1-min contention window.
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

echo "==> brew tap + upgrade coilyco-bridge/coily/coily"
brew tap coilyco-bridge/coily https://github.com/coilyco-bridge/coily
brew upgrade coilyco-bridge/coily/coily

# Upgrade all other Linuxbrew formulae too, after the targeted coily upgrade so
# coily still lands even if a later formula's upgrade trips set -e.
echo "==> brew upgrade (all formulae)"
brew upgrade

echo "==> coily setup (lockdown root: ${COILY_LOCKDOWN_ROOT:-unset})"
coily setup

echo "==> coily version"
coily version
