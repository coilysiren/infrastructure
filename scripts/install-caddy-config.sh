#!/usr/bin/env bash
# install-caddy-config.sh - copy the repo Caddyfile to /etc/caddy/Caddyfile
# as a real root-owned file, then reload Caddy if anything changed.
#
# Intended to run as root from caddy-config-deploy.service (triggered by
# caddy-config-deploy.path when the repo Caddyfile changes). Also safe to
# run by hand on kai-server as a manual deploy:
#   sudo bash /home/kai/projects/coilysiren/infrastructure/scripts/install-caddy-config.sh
#
# Why a real file: /home/kai is mode 750, so the caddy service user
# cannot traverse it to read its own config. A symlink from /etc/caddy/
# into /home/kai works for a process that was started before the
# permissions tightened, but the next restart will fail with
# "permission denied". See infrastructure#292.
#
# Idempotent: compares source and destination, reloads only on diff.
# Validates the source before install so a broken Caddyfile in the repo
# does not knock production caddy off the air.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "install-caddy-config.sh must run as root" >&2
  exit 2
fi

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
SRC="$INFRA_SRC/caddy/Caddyfile"
DST="/etc/caddy/Caddyfile"

if [[ ! -f "$SRC" ]]; then
  echo "no such source: $SRC" >&2
  exit 1
fi

echo ">>> validating $SRC"
# `caddy validate` ignores the global { admin off } and similar quirks;
# good enough as a syntax + import gate.
caddy validate --config "$SRC" --adapter caddyfile

# Force a real-file install if the destination is a symlink (the failure
# mode #292 exists to prevent), even when contents already match. Skip
# install + reload only when DST is already a real file with matching
# content.
needs_install=0
if [[ -L "$DST" ]]; then
  echo ">>> $DST is a symlink; replacing with a real file"
  needs_install=1
elif [[ ! -f "$DST" ]]; then
  echo ">>> $DST does not exist yet"
  needs_install=1
elif ! cmp -s "$SRC" "$DST"; then
  echo ">>> $DST differs from $SRC"
  needs_install=1
fi

if (( needs_install == 0 )); then
  echo ">>> no change; caddy reload not needed"
  exit 0
fi

# `install` writes to a temp file in $DST's directory and renames into
# place atomically, so a concurrent caddy read sees either the old
# inode or the new one, never a partial write.
install -m 0644 -o root -g root "$SRC" "$DST"
echo ">>> installed $DST"

# Reload over restart: Caddy reload is a zero-downtime config swap via
# the admin API, no dropped connections. Restart works too but bounces
# the listeners. Falls back to restart if reload fails (rare; the
# validate above catches the common cases).
if systemctl reload caddy; then
  echo ">>> reloaded caddy"
else
  echo ">>> reload failed; restarting caddy" >&2
  systemctl restart caddy
fi
