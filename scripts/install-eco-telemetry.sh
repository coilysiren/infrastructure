#!/usr/bin/env bash
# Pull the latest EcoTelemetry release zip from GitHub and unzip it into
# the Eco Mods tree. Idempotent: re-run to upgrade.
#
# Run as: sudo bash /home/kai/projects/coilysiren/infrastructure/scripts/install-eco-telemetry.sh
# (file ops drop to the eco-server user via `sudo -u`; root is only here
# because the deploy verb expects a root entry-point.)

set -euo pipefail

REPO="coilysiren/eco-telemetry"
ECO_USER="kai"
SERVER_DIR="/home/kai/Steam/steamapps/common/EcoServer"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "must run as root (sudo)" >&2
  exit 1
fi

if [[ ! -d "$SERVER_DIR" ]]; then
  echo "EcoServer dir not found at $SERVER_DIR" >&2
  exit 1
fi

# Cruft from the pre-2026-04-28 zip layout (top-level EcoTelemetry/
# instead of Mods/EcoTelemetry/). Eco never loaded it; remove on sight.
if [[ -e "$SERVER_DIR/EcoTelemetry" && ! -L "$SERVER_DIR/EcoTelemetry" ]]; then
  echo ">>> removing stale $SERVER_DIR/EcoTelemetry (wrong-layout cruft)"
  sudo -u "$ECO_USER" rm -rf "$SERVER_DIR/EcoTelemetry"
fi

tmp="$(sudo -u "$ECO_USER" mktemp -d)"
trap 'sudo -u "$ECO_USER" rm -rf "$tmp"' EXIT

echo ">>> resolving latest release of $REPO"
asset_url="$(curl -sfL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+EcoTelemetry-[^"]+\.zip"' \
  | head -n1 \
  | sed -E 's/.*"(https[^"]+)".*/\1/')"

if [[ -z "$asset_url" ]]; then
  echo "no EcoTelemetry-*.zip asset on latest release" >&2
  exit 1
fi

echo ">>> downloading $asset_url"
sudo -u "$ECO_USER" curl -sfL -o "$tmp/EcoTelemetry.zip" "$asset_url"

echo ">>> unzipping into $SERVER_DIR"
sudo -u "$ECO_USER" bash -c "cd '$SERVER_DIR' && unzip -o '$tmp/EcoTelemetry.zip'"

echo ">>> done. server not restarted; run 'coily eco restart' when ready."
