#!/usr/bin/env bash
# install-coilysiren-tangled-knot-autodeploy.sh - install the
# tangled-knot autodeploy unit + timer on kai-server. Idempotent.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-coilysiren-tangled-knot-autodeploy.sh
#
# See infrastructure#293. The autodeploy itself runs as root because
# it writes /opt/tangled-knot/current, /var/backups/tangled-knot, and
# restarts tangled-knot.service - root sidesteps a per-verb sudoers
# entry. The tangled-knot install (install-tangled-knot.sh) must have
# run first so /opt/tangled-knot/current already exists.

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
