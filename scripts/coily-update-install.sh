#!/usr/bin/env bash
# coily-update-install.sh - install the coily auto-update unit + timer
# on kai-server. Idempotent: re-run after editing the unit files.
#
# Prereqs:
#   - coily already installed via scripts/coily-install.sh.
#   - Broad NOPASSWD coily sudoers rule in place so `coily systemctl start
#     coily-update.service` self-elevates non-TTY (coily#203).
#
# Run as the `kai` user from the repo checkout. Sudo is invoked per-step.

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
