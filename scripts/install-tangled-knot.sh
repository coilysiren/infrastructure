#!/usr/bin/env bash
# Install the Tangled knot as a host systemd service on kai-server. Idempotent: nix-builds
# the knot, pins /opt/tangled-knot/current, wires the unit, env, git user, and sshd.

# Run via bash. Caddy, the Route 53 A record, and the auto-deploy timer are separate
# follow-ups. See infrastructure#280.

set -euo pipefail

KNOT_TAG="v1.14.1-alpha"
FLAKE="git+https://tangled.org/tangled.org/core?ref=refs/tags/${KNOT_TAG}#knot"
INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"

echo ">>> building knot ${KNOT_TAG} via nix"
STORE_PATH="$(nix build "$FLAKE" --no-link --print-out-paths)"
echo "    built: $STORE_PATH"

echo ">>> pinning /opt/tangled-knot/current"
sudo mkdir -p /opt/tangled-knot
sudo ln -sfn "$STORE_PATH" /opt/tangled-knot/current

echo ">>> ensuring the git system user"
if ! id git >/dev/null 2>&1; then
  sudo useradd --system --create-home --home-dir /var/lib/tangled-knot \
    --shell /bin/bash git
fi

echo ">>> repo store + git committer config"
sudo install -d -o git -g git /var/lib/tangled-knot/repos
sudo install -d -o git -g git /var/lib/tangled-knot/.config/git
sudo install -m 0644 -o git -g git /dev/stdin \
  /var/lib/tangled-knot/.config/git/config <<'GITCFG'
[user]
    name = Tangled
    email = noreply@tangled.org
[receive]
    advertisePushOptions = true
[uploadpack]
    allowFilter = true
    allowReachableSHA1InWant = true
GITCFG

echo ">>> installing unit, env, keyfetch wrapper, sshd drop-in"
sudo install -d /etc/tangled-knot
sudo install -m 0644 "$INFRA_SRC/systemd/tangled-knot.env"     /etc/tangled-knot/knot.env
sudo install -m 0644 "$INFRA_SRC/systemd/tangled-knot.service" /etc/systemd/system/tangled-knot.service
sudo install -m 0555 "$INFRA_SRC/scripts/tangled-knot-keyfetch.sh" /etc/ssh/tangled-knot-keyfetch
sudo install -m 0644 "$INFRA_SRC/sshd/tangled-knot.conf"       /etc/ssh/sshd_config.d/tangled-knot.conf

echo ">>> validating + reloading sshd"
sudo sshd -t
sudo systemctl reload ssh

echo ">>> enabling + starting the knot"
sudo systemctl daemon-reload
sudo systemctl enable --now tangled-knot.service

echo
echo "status:  systemctl status tangled-knot.service"
echo "logs:    journalctl -u tangled-knot.service -n 50 --no-pager"
echo "still to do, separately: reload Caddy for the tangled.coilysiren.me"
echo "site, add the Route 53 A record, and register the knot with the appview."
