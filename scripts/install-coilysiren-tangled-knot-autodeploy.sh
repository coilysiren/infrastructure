#!/usr/bin/env bash
# Install the tangled-knot autodeploy unit + timer on kai-server. Idempotent.
# Run via bash. install-tangled-knot.sh must run first. See infrastructure#293.

# The autodeploy runs as root (writes /opt/tangled-knot/current, backups, restarts
# the service), sidestepping a per-verb sudoers entry.

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/coilysiren-tangled-knot-autodeploy.service"
TIMER_DST="/etc/systemd/system/coilysiren-tangled-knot-autodeploy.timer"

echo ">>> installing unit + timer"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-tangled-knot-autodeploy.service" "$UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-tangled-knot-autodeploy.timer"   "$TIMER_DST"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + starting timer"
sudo systemctl enable --now coilysiren-tangled-knot-autodeploy.timer

echo
echo "manual trigger:"
echo "  sudo bash $INFRA_SRC/scripts/coilysiren-tangled-knot-autodeploy.sh"
echo "or fire the unit:"
echo "  coily systemctl start coilysiren-tangled-knot-autodeploy.service"
echo "  journalctl -u coilysiren-tangled-knot-autodeploy.service -n 100 --no-pager"
