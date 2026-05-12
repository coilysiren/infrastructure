#!/usr/bin/env bash
# claude-remote-control-install.sh - install the Claude Code remote-control
# daemon unit plus its daily 3am restart timer on kai-server. Idempotent:
# re-run after editing the unit files.
#
# Prereqs:
#   - nvm installed for kai with a default node version selected.
#   - `claude` (npm package) installed under that node version.
#   - `claude login` already run as kai against the active claude.ai
#     subscription (Pro/Max/Team/Enterprise; API keys not supported).
#
# Run as the `kai` user from the repo checkout. Sudo is invoked per-step.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> install unit files"
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control.service"         /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-restart.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-restart.timer"   /etc/systemd/system/

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
sudo systemctl enable --now claude-remote-control.service
sudo systemctl enable --now claude-remote-control-restart.timer

echo
echo "==> status"
sudo systemctl --no-pager status claude-remote-control.service         | head -10 || true
echo
sudo systemctl --no-pager status claude-remote-control-restart.timer   | head -10 || true
echo
echo "Verify with:"
echo "  systemctl list-timers claude-remote-control-restart.timer"
echo "  journalctl -u claude-remote-control.service -n 50 --no-pager"
echo "  sudo systemctl start claude-remote-control-restart.service  # force one restart"
