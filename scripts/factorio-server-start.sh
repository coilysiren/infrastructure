#!/usr/bin/bash
# Launch the factorio dedicated server, loading the newest save under SAVES_DIR.
# Needs >=1 .zip save and server-settings.json; first save: `factorio --create`.

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

# RCON feeds the fdr-remake Discord bridge. Soft-fail if /factorio/rcon-password
# is absent: factorio still starts, bridge connects next restart (infrastructure#101).
RCON_ARGS=()
if rcon_password=$(aws ssm get-parameter --name /factorio/rcon-password --with-decryption --query Parameter.Value --output text 2>/dev/null); then
  RCON_ARGS=(--rcon-port "${RCON_PORT}" --rcon-password "${rcon_password}")
else
  echo "factorio-server-start: /factorio/rcon-password not in SSM, starting without RCON (fdr bridge will not connect)" >&2
fi

cd "${SERVER_DIR}"
# Pick the newest .zip explicitly: --start-server-load-latest looks in an
# uncontrolled ~/.factorio/saves/, so an explicit path is more portable.
LATEST=$(find "${SAVES_DIR}" -maxdepth 1 -name '*.zip' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
echo "factorio-server-start: loading ${LATEST}"
exec ./bin/x64/factorio --start-server "${LATEST}" \
  --server-settings ./server-settings.json \
  --server-whitelist ./server-whitelist.json --use-server-whitelist \
  --server-adminlist ./server-adminlist.json \
  --console-log "${CONSOLE_LOG}" \
  "${RCON_ARGS[@]}"
