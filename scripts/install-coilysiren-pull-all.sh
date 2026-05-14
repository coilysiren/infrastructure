#!/usr/bin/env bash
# install-coilysiren-pull-all.sh - install the pull-all unit + timer on
# kai-server. Idempotent.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-coilysiren-pull-all.sh

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/coilysiren-pull-all.service"
TIMER_DST="/etc/systemd/system/coilysiren-pull-all.timer"

echo ">>> installing unit + timer"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-pull-all.service" "$UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-pull-all.timer"   "$TIMER_DST"

echo ">>> installing sudoers update (NOPASSWD for the start verb)"
sudo install -m 0440 -o root -g root \
  "$INFRA_SRC/sudoers/kai-coilysiren-updates" \
  /etc/sudoers.d/kai-coilysiren-updates
sudo visudo -cf /etc/sudoers.d/kai-coilysiren-updates

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + starting timer"
sudo systemctl enable --now coilysiren-pull-all.timer

echo
echo "manual trigger:"
echo "  bash $INFRA_SRC/scripts/coilysiren-pull-all.sh"
echo "or fire the unit:"
echo "  sudo systemctl start coilysiren-pull-all.service"
echo "  journalctl -u coilysiren-pull-all.service -n 50 --no-pager"
