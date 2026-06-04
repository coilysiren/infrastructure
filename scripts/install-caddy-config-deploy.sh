#!/usr/bin/env bash
# One-time root bootstrap on kai-server: installs the caddy-config-deploy .service
# + .path units, enables the path watcher, and fires an initial Caddyfile deploy.

# Run via sudo bash. Repo Caddyfile changes then auto-deploy. See infrastructure#292.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "install-caddy-config-deploy.sh must run as root (sudo bash $0)" >&2
  exit 2
fi

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
SERVICE_SRC="$INFRA_SRC/systemd/caddy-config-deploy.service"
PATH_SRC="$INFRA_SRC/systemd/caddy-config-deploy.path"
SERVICE_DST="/etc/systemd/system/caddy-config-deploy.service"
PATH_DST="/etc/systemd/system/caddy-config-deploy.path"

echo ">>> installing systemd units"
install -m 0644 -o root -g root "$SERVICE_SRC" "$SERVICE_DST"
install -m 0644 -o root -g root "$PATH_SRC" "$PATH_DST"

echo ">>> reloading systemd"
systemctl daemon-reload

echo ">>> enabling + starting caddy-config-deploy.path"
systemctl enable --now caddy-config-deploy.path

echo ">>> running initial deploy"
bash "$INFRA_SRC/scripts/install-caddy-config.sh"

echo
echo "done. future changes to $INFRA_SRC/caddy/Caddyfile auto-deploy via"
echo "caddy-config-deploy.path -> caddy-config-deploy.service -> install-caddy-config.sh."
echo
echo "inspect:"
echo "  systemctl status caddy-config-deploy.path"
echo "  journalctl -u caddy-config-deploy.service -n 50 --no-pager"
