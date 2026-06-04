#!/usr/bin/env bash
# Install personal-dashboard from the coilysiren tap and wire it as a systemd service
# on kai-server. Idempotent. Run via bash (sudo invoked per-step).

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/personal-dashboard.service"
UPDATE_UNIT_DST="/etc/systemd/system/personal-dashboard-update.service"
UPDATE_TIMER_DST="/etc/systemd/system/personal-dashboard-update.timer"

# Non-interactive shells skip ~/.bashrc, so brew is not on PATH by
# default. Source shellenv explicitly.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
else
  echo "Linuxbrew not found at /home/linuxbrew/.linuxbrew/bin/brew" >&2
  echo "run scripts/coily-install.sh first to bootstrap brew" >&2
  exit 1
fi

echo ">>> brew tap + install/upgrade personal-dashboard"
brew tap coilysiren/personal-dashboard https://github.com/coilysiren/personal-dashboard
brew install coilysiren/personal-dashboard/personal-dashboard || brew upgrade coilysiren/personal-dashboard/personal-dashboard

echo ">>> installing unit -> $UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/personal-dashboard.service" "$UNIT_DST"

echo ">>> installing auto-update unit + timer"
sudo install -m 0644 "$INFRA_SRC/systemd/personal-dashboard-update.service" "$UPDATE_UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/personal-dashboard-update.timer" "$UPDATE_TIMER_DST"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + (re)starting personal-dashboard.service"
sudo systemctl enable personal-dashboard.service
sudo systemctl restart personal-dashboard.service

echo ">>> enabling + starting personal-dashboard-update.timer"
sudo systemctl enable personal-dashboard-update.timer
sudo systemctl start personal-dashboard-update.timer

sleep 2
sudo systemctl --no-pager --full status personal-dashboard.service || true

echo
echo "next: expose over tailscale (run as kai, once):"
echo "  sudo tailscale serve --bg --https=8443 http://127.0.0.1:31337"
echo "verify with:"
echo "  tailscale serve status"
echo "  curl -sfI https://kai-server.<tailnet>.ts.net:8443/"
echo
echo "secrets (optional): populate /etc/personal-dashboard.env from"
echo "agentic-os-kai/SSM.md, then 'coily systemctl restart personal-dashboard.service'."
