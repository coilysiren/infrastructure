#!/usr/bin/env bash
# repo-recall-update-install.sh - install the repo-recall auto-update
# unit + timer on kai-server. Idempotent.
#
# Prereqs:
#   - repo-recall already installed via scripts/repo-recall-install.sh.
#   - sudoers/kai-coilysiren-updates already in place (for the
#     `sudo systemctl try-restart repo-recall.service` step inside the
#     wrapper script, plus the on-demand `start repo-recall-update.service`
#     route).
#
# Run as the `kai` user from the repo checkout. Sudo is invoked per-step.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> install unit files"
sudo install -m 0644 "${REPO_DIR}/systemd/repo-recall-update.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/repo-recall-update.timer"   /etc/systemd/system/

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
sudo systemctl enable --now repo-recall-update.timer

echo
echo "==> status"
sudo systemctl --no-pager status repo-recall-update.timer | head -10 || true
echo
echo "Verify with:"
echo "  systemctl list-timers repo-recall-update.timer"
echo "  sudo systemctl start repo-recall-update.service  # force one run"
echo "  journalctl -u repo-recall-update.service -n 30 --no-pager"
