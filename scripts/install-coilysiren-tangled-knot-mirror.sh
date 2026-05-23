#!/usr/bin/env bash
# install-coilysiren-tangled-knot-mirror.sh - install the tangled-knot
# mirror unit + timer on kai-server. Idempotent.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-coilysiren-tangled-knot-mirror.sh
#
# What this installs:
#   - /etc/systemd/system/coilysiren-tangled-knot-mirror.service
#   - /etc/systemd/system/coilysiren-tangled-knot-mirror.timer
#   - /home/kai/.ssh/tangled-knot-mirror_ed25519{,.pub} (mode 600 / 644)
#
# Manual step required after first install: the public half of the
# generated keypair must be registered against Kai's knot-owner DID
# (KNOT_SERVER_OWNER in /etc/tangled-knot/knot.env) through the
# appview at https://tangled.org. Without that registration, the
# AuthorizedKeysCommand at /etc/ssh/tangled-knot-keyfetch will not
# return this key to sshd and every push will fail. The script prints
# the public key at the end so it can be pasted into the appview.
#
# Mirror also depends on the knot being installed (install-tangled-
# knot.sh) and on the GitHub user having a working SSH key for
# git@github.com:coilysiren/* clones (kai-server's existing key).
#
# See infrastructure#294.

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
