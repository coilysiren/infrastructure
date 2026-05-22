#!/usr/bin/env bash
# install-coilysiren-forgejo-mirror.sh - install the forgejo-mirror unit +
# timer on kai-server. Idempotent.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-coilysiren-forgejo-mirror.sh

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/coilysiren-forgejo-mirror.service"
TIMER_DST="/etc/systemd/system/coilysiren-forgejo-mirror.timer"

echo ">>> installing unit + timer"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-forgejo-mirror.service" "$UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-forgejo-mirror.timer"   "$TIMER_DST"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + starting timer"
sudo systemctl enable --now coilysiren-forgejo-mirror.timer

echo
echo "manual trigger:"
echo "  bash $INFRA_SRC/scripts/coilysiren-forgejo-mirror.sh"
echo "or fire the unit:"
echo "  coily systemctl start coilysiren-forgejo-mirror.service"
echo "  journalctl -u coilysiren-forgejo-mirror.service -n 50 --no-pager"
