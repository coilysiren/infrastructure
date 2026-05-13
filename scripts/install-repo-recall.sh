#!/usr/bin/env bash
# install-repo-recall.sh - install repo-recall from the coilysiren tap
# and wire it up as a systemd service on kai-server.
#
# Idempotent: re-run to upgrade. For automated weekly upgrades see
# scripts/repo-recall-update-install.sh.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-repo-recall.sh
# (sudo is invoked per-step, no need to run the whole script as root.)

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/repo-recall.service"

# Non-interactive shells skip ~/.bashrc, so brew is not on PATH by
# default. Source shellenv explicitly.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
else
  echo "Linuxbrew not found at /home/linuxbrew/.linuxbrew/bin/brew" >&2
  echo "run scripts/coily-install.sh first to bootstrap brew" >&2
  exit 1
fi

echo ">>> brew tap + install/upgrade repo-recall"
brew tap coilysiren/tap
brew install coilysiren/tap/repo-recall || brew upgrade coilysiren/tap/repo-recall

echo ">>> installing unit -> $UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/repo-recall.service" "$UNIT_DST"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + (re)starting repo-recall.service"
sudo systemctl enable repo-recall.service
sudo systemctl restart repo-recall.service

sleep 2
sudo systemctl --no-pager --full status repo-recall.service || true

echo
echo "next: expose over tailscale (run as kai, once):"
echo "  tailscale serve --bg --https=443 http://127.0.0.1:7777"
echo "verify with:"
echo "  tailscale serve status"
echo "  curl -sf https://kai-server.<tailnet>.ts.net/api/scan-version"
