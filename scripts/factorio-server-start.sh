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

if [ ! -d "${SAVES_DIR}" ] || [ -z "$(find "${SAVES_DIR}" -maxdepth 1 -name '*.zip' -print -quit)" ]; then
  echo "factorio-server-start: no saves under ${SAVES_DIR}." >&2
  echo "First-time setup: ${SERVER_DIR}/bin/x64/factorio --create ${SAVES_DIR}/<name>.zip" >&2
  exit 2
fi

cd "${SERVER_DIR}"
exec ./bin/x64/factorio --start-server-load-latest
