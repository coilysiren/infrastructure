#!/usr/bin/env bash
# Install the github-mirror unit + timer on kai-server. Idempotent. Run via bash.

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/coilysiren-github-mirror.service"
TIMER_DST="/etc/systemd/system/coilysiren-github-mirror.timer"

echo ">>> installing unit + timer"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-github-mirror.service" "$UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-github-mirror.timer"   "$TIMER_DST"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + starting timer"
sudo systemctl enable --now coilysiren-github-mirror.timer

echo
echo "manual trigger:"
echo "  bash $INFRA_SRC/scripts/coilysiren-github-mirror.sh"
echo "or fire the unit:"
echo "  coily systemctl start coilysiren-github-mirror.service"
echo "  journalctl -u coilysiren-github-mirror.service -n 50 --no-pager"
