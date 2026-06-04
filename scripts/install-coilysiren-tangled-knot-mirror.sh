#!/usr/bin/env bash
# Install the tangled-knot mirror unit + timer on kai-server (plus a dedicated SSH
# keypair). Idempotent. Run via bash. Needs install-tangled-knot.sh first.

# Manual step after first install: register the printed public key against the
# knot-owner DID via https://tangled.org, else every push fails. See infrastructure#294.

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
UNIT_DST="/etc/systemd/system/coilysiren-tangled-knot-mirror.service"
TIMER_DST="/etc/systemd/system/coilysiren-tangled-knot-mirror.timer"
SSH_KEY="${TANGLED_MIRROR_KEY:-/home/kai/.ssh/tangled-knot-mirror_ed25519}"

if [[ ! -r /etc/tangled-knot/knot.env ]]; then
  echo "ABORT: /etc/tangled-knot/knot.env missing; run install-tangled-knot.sh first" >&2
  exit 1
fi

echo ">>> generating dedicated SSH keypair (if missing)"
if [[ ! -f "$SSH_KEY" ]]; then
  install -d -m 0700 -o kai -g kai /home/kai/.ssh
  sudo -u kai ssh-keygen -t ed25519 -N '' -C 'tangled-knot-mirror@kai-server' -f "$SSH_KEY"
  echo "    generated: $SSH_KEY"
else
  echo "    already present: $SSH_KEY"
fi
chmod 600 "$SSH_KEY"
chmod 644 "$SSH_KEY.pub"
chown kai:kai "$SSH_KEY" "$SSH_KEY.pub"

echo ">>> installing unit + timer"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-tangled-knot-mirror.service" "$UNIT_DST"
sudo install -m 0644 "$INFRA_SRC/systemd/coilysiren-tangled-knot-mirror.timer"   "$TIMER_DST"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

echo ">>> enabling + starting timer"
sudo systemctl enable --now coilysiren-tangled-knot-mirror.timer

echo
echo "public key to register against the knot-owner DID via https://tangled.org:"
echo
cat "$SSH_KEY.pub"
echo
echo "manual trigger:"
echo "  bash $INFRA_SRC/scripts/coilysiren-tangled-knot-mirror.sh"
echo "or fire the unit:"
echo "  coily systemctl start coilysiren-tangled-knot-mirror.service"
echo "  journalctl -u coilysiren-tangled-knot-mirror.service -n 50 --no-pager"
