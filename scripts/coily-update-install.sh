#!/usr/bin/env bash
# Install the coily auto-update unit + timer on kai-server. Idempotent. Prereqs:
# coily-install.sh plus the NOPASSWD coily sudoers rule (coily#203). Run as kai.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> install unit files"
sudo install -m 0644 "${REPO_DIR}/systemd/coily-update.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/coily-update.timer"   /etc/systemd/system/

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
sudo systemctl enable --now coily-update.timer

echo
echo "==> status"
sudo systemctl --no-pager status coily-update.timer | head -10 || true
echo
echo "Verify with:"
echo "  systemctl list-timers coily-update.timer"
echo "  coily systemctl start coily-update.service  # force one run"
echo "  journalctl -u coily-update.service -n 30 --no-pager"
