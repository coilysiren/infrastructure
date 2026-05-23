#!/usr/bin/env bash
# install-caddy-config-deploy.sh - one-time bootstrap on kai-server for
# the auto-deploy of /etc/caddy/Caddyfile from the repo Caddyfile.
#
# Installs:
#   - caddy-config-deploy.service (oneshot, runs install-caddy-config.sh
#     as root)
#   - caddy-config-deploy.path    (watches repo Caddyfile for changes)
#
# Then enables the path unit and fires an initial deploy so the current
# repo Caddyfile lands at /etc/caddy/Caddyfile before the first inotify
# event arrives.
#
# Run as: sudo bash /home/kai/projects/coilysiren/infrastructure/scripts/install-caddy-config-deploy.sh
#
# After this runs once, every change to caddy/Caddyfile (via daily
# coilysiren-pull-all.timer, manual git pull, or hand edit) auto-deploys
# without further operator action. See infrastructure#292.

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
