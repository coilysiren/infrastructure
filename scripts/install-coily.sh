#!/usr/bin/bash
# install-coily.sh - bootstrap Linuxbrew + coily on a fresh node.
#
# Idempotent: re-running upgrades coily and re-applies `coily setup`.
# Safe to run as the `kai` user; sudo is invoked per-step for apt only.

set -euo pipefail

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_ENV_LINE='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'

echo "==> apt: brew prereqs"
sudo apt-get install -y build-essential procps curl file git

if [ ! -x "${BREW_PREFIX}/bin/brew" ]; then
  echo "==> Linuxbrew install"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo "==> Linuxbrew already installed at ${BREW_PREFIX}, skipping"
fi

echo "==> wire brew into ~/.bashrc"
if ! grep -qF "${BREW_ENV_LINE}" "${HOME}/.bashrc" 2>/dev/null; then
  echo "${BREW_ENV_LINE}" >> "${HOME}/.bashrc"
fi
eval "${BREW_ENV_LINE}"

echo "==> brew install coilysiren/tap/coily"
brew tap coilysiren/tap
brew install coilysiren/tap/coily || brew upgrade coilysiren/tap/coily
coily setup

echo
echo "==> sanity"
coily version
# Read-only verify of the SSM creds without echoing the secret. Prints just
# the parameter name and "ok" when it decrypts.
for name in /sentry-dsn/kai-server /kai-server/thermal-heartbeat-cron-url; do
  if coily aws ssm get-parameter --name "${name}" --with-decryption \
      --query Parameter.Name --output text >/dev/null 2>&1; then
    echo "  ${name}: ok"
  else
    echo "  ${name}: MISSING" >&2
    exit 1
  fi
done
echo
echo "Next: bash scripts/thermal-heartbeat-install.sh"
