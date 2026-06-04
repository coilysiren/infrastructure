#!/usr/bin/bash
# factorio-server-start.sh - launch the factorio dedicated server.
#
# Loads the most recent save under SAVES_DIR via
# --start-server-load-latest, so cycle rotations (new save names per
# cycle, autosave rotation within a cycle) don't require touching
# this script. The previously-hardcoded ./saves/q4-2025.zip is gone.
#
# Pre-conditions:
#   - SAVES_DIR exists and contains at least one .zip save. First-time
#     setup: `factorio --create $SAVES_DIR/<name>.zip` once before the
#     first start.
#   - server-settings.json under SERVER_DIR (auto_pause, autosave_slots,
#     visibility, whitelist, etc) lives next to mods/ and saves/.

set -euo pipefail

SERVER_DIR="${FACTORIO_SERVER_DIR:-/home/kai/Steam/steamapps/common/FactorioServer}"
SAVES_DIR="${FACTORIO_SAVES_DIR:-${SERVER_DIR}/saves}"
CONSOLE_LOG="${FACTORIO_CONSOLE_LOG:-${SERVER_DIR}/factorio-current.log}"
RCON_PORT="${FACTORIO_RCON_PORT:-27015}"

if [ ! -d "${SAVES_DIR}" ] || [ -z "$(find "${SAVES_DIR}" -maxdepth 1 -name '*.zip' -print -quit)" ]; then
  echo "factorio-server-start: no saves under ${SAVES_DIR}." >&2
  echo "First-time setup: ${SERVER_DIR}/bin/x64/factorio --create ${SAVES_DIR}/<name>.zip" >&2
  exit 2
fi

# RCON is for the fdr-remake Discord bridge sidecar. Soft-fail if the
# password isn't in SSM yet (e.g. first boot after install, or AWS
# creds rotated): factorio still starts, the bridge just won't connect
# until the next restart picks up the password. coilyco-flight-deck/infrastructure#101.
RCON_ARGS=()
if rcon_password=$(aws ssm get-parameter --name /factorio/rcon-password --with-decryption --query Parameter.Value --output text 2>/dev/null); then
  RCON_ARGS=(--rcon-port "${RCON_PORT}" --rcon-password "${rcon_password}")
else
  echo "factorio-server-start: /factorio/rcon-password not in SSM, starting without RCON (fdr bridge will not connect)" >&2
fi

cd "${SERVER_DIR}"
# Pick the newest .zip explicitly. --start-server-load-latest looks in
# ~/.factorio/saves/ (a path we don't control), and --write-data isn't
# a recognized flag. The explicit-path approach is more portable and
# robust to multiple saves.
LATEST=$(find "${SAVES_DIR}" -maxdepth 1 -name '*.zip' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
echo "factorio-server-start: loading ${LATEST}"
exec ./bin/x64/factorio --start-server "${LATEST}" \
  --server-settings ./server-settings.json \
  --server-whitelist ./server-whitelist.json --use-server-whitelist \
  --server-adminlist ./server-adminlist.json \
  --console-log "${CONSOLE_LOG}" \
  "${RCON_ARGS[@]}"
