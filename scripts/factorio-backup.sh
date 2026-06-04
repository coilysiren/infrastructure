#!/usr/bin/bash
# Copy the factorio saves dir to S3 (kai-game-backups) nightly or via
# `coily gaming factorio saves backup-now`. Bucket lifecycle rotates; never deletes.

set -euo pipefail

BUCKET="${FACTORIO_BACKUP_BUCKET:-kai-game-backups}"
SAVES_DIR="${FACTORIO_SAVES_DIR:-/home/kai/Steam/steamapps/common/FactorioServer/saves}"
HOST="${HOSTNAME:-$(hostname -s)}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX="factorio/${HOST}/${STAMP}"

if [ ! -d "${SAVES_DIR}" ]; then
  # No-op when the server is installed but never run (no saves dir yet), so the
  # nightly timer doesn't alert during onboarding. Exit 0 with a one-liner.
  echo "factorio-backup: nothing to back up (saves dir does not exist yet): ${SAVES_DIR}"
  exit 0
fi

# Saves dir exists but is empty (server ran, no autosave fired, or
# all saves got deleted). Same handling: clean no-op.
if [ -z "$(find "${SAVES_DIR}" -maxdepth 1 -name '*.zip' -print -quit)" ]; then
  echo "factorio-backup: nothing to back up (no .zip saves under ${SAVES_DIR})"
  exit 0
fi

# --size-only because Factorio rewrites autosaves with new mtimes even when bytes
# are identical, so size-only avoids needless re-uploads.
aws s3 sync \
  --size-only \
  --no-progress \
  "${SAVES_DIR}/" \
  "s3://${BUCKET}/${PREFIX}/"

echo "factorio-backup: ok ${PREFIX}"
