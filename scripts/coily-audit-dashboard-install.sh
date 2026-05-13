#!/usr/bin/env bash
# coily-audit-dashboard-install.sh - install the coily audit dashboard
# timer + unit on kai-server, plus the /var/lib/coily output dir.
#
# Idempotent: re-run after editing the unit files.
#
# Prereqs:
#   - coily already installed via scripts/coily-install.sh.
#   - Caddy already running with the audit-dashboard server block in
#     caddy/Caddyfile.
#
# Run as the `kai` user from the repo checkout. Sudo is invoked per-step.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> create /var/lib/coily as kai:kai"
sudo install -d -m 0755 -o kai -g kai /var/lib/coily

echo "==> install unit files"
sudo install -m 0644 "${REPO_DIR}/systemd/coily-audit-dashboard.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/coily-audit-dashboard.timer"   /etc/systemd/system/

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
sudo systemctl enable --now coily-audit-dashboard.timer

echo
echo "==> kick one run now so the dashboard exists before the next tick"
sudo systemctl start coily-audit-dashboard.service || true

echo
echo "==> status"
sudo systemctl --no-pager status coily-audit-dashboard.timer | head -10 || true
echo
echo "Verify with:"
echo "  systemctl list-timers coily-audit-dashboard.timer"
echo "  journalctl -u coily-audit-dashboard.service -n 30 --no-pager"
echo "  ls -la /var/lib/coily/dashboard.html"
echo
echo "Then open http://kai-server:8082/dashboard.html in a browser on the tailnet."
