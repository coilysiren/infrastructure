#!/usr/bin/env bash
# Copy the repo Caddyfile to /etc/caddy as a real root-owned file (not a symlink,
# since /home/kai is mode 750), then reload Caddy on diff. See infrastructure#292.

# Runs as root from caddy-config-deploy.service or by hand via sudo bash. Idempotent:
# validates the source first, reloads only when destination content changed.

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
# `caddy validate` is good enough as a syntax + import gate.
caddy validate --config "$SRC" --adapter caddyfile

# Force a real-file install when DST is a symlink (the #292 failure mode), even if
# contents match. Skip install + reload only when DST is a matching real file.
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

# `install` writes a temp file then renames atomically, so a concurrent caddy read
# sees the old or new inode, never a partial write.
install -m 0644 -o root -g root "$SRC" "$DST"
echo ">>> installed $DST"

# Reload over restart: it is a zero-downtime config swap via the admin API.
# Falls back to restart if reload fails (rare, the validate above gates that).
if systemctl reload caddy; then
  echo ">>> reloaded caddy"
else
  echo ">>> reload failed; restarting caddy" >&2
  systemctl restart caddy
fi
