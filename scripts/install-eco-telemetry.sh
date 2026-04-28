#!/usr/bin/env bash
# Pull the latest EcoTelemetry release zip from GitHub and unzip it into
# the Eco Mods tree. Idempotent: re-run to upgrade.
#
# Run as kai (or whichever user owns the EcoServer tree). No root needed:
# everything lives under /home/kai/.

set -euo pipefail

REPO="coilysiren/eco-telemetry"
SERVER_DIR="/home/kai/Steam/steamapps/common/EcoServer"

if [[ ! -d "$SERVER_DIR" ]]; then
  echo "EcoServer dir not found at $SERVER_DIR" >&2
  exit 1
fi

# Cruft from the pre-2026-04-28 zip layout (top-level EcoTelemetry/
# instead of Mods/EcoTelemetry/). Eco never loaded it; remove on sight.
if [[ -e "$SERVER_DIR/EcoTelemetry" && ! -L "$SERVER_DIR/EcoTelemetry" ]]; then
  echo ">>> removing stale $SERVER_DIR/EcoTelemetry (wrong-layout cruft)"
  rm -rf "$SERVER_DIR/EcoTelemetry"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
curl -sfL -o "$tmp/EcoTelemetry.zip" "$asset_url"

echo ">>> unzipping into $SERVER_DIR"
(cd "$SERVER_DIR" && unzip -o "$tmp/EcoTelemetry.zip")

echo ">>> done. server not restarted; run 'coily eco restart' when ready."
