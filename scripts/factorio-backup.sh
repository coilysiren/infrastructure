#!/usr/bin/bash
# factorio-backup.sh - copy the factorio saves dir to S3.
#
# Runs on kai-server. Invoked nightly by factorio-backup.timer and
# ad-hoc by `coily gaming factorio saves backup-now`.
#
# Auth: uses the existing /home/kai/.aws credentials (kai-server-k3s
# IAM user) which gets an inline S3 policy granting Put/List on the
# kai-game-backups bucket.
#
# RPO target: ~24h. RPO is bounded tighter by Factorio's autosave
# rotation (autosave_interval=5min, autosave_slots=10) which keeps a
# rolling local 50min of history regardless of this script.
#
# The bucket lifecycle policy rotates these objects; this script does
# not delete anything itself.

set -euo pipefail

BUCKET="${FACTORIO_BACKUP_BUCKET:-kai-game-backups}"
SAVES_DIR="${FACTORIO_SAVES_DIR:-/home/kai/Steam/steamapps/common/FactorioServer/saves}"
HOST="${HOSTNAME:-$(hostname -s)}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX="factorio/${HOST}/${STAMP}"

if [ ! -d "${SAVES_DIR}" ]; then
  echo "factorio-backup: saves dir not found: ${SAVES_DIR}" >&2
  exit 2
fi

# --size-only because Factorio rewrites autosave files with new mtimes
# even when the byte content is identical mid-session; size-only
# defeats unnecessary re-uploads. Uses the default profile from
# /home/kai/.aws/credentials.
aws s3 sync \
  --size-only \
  --no-progress \
  "${SAVES_DIR}/" \
  "s3://${BUCKET}/${PREFIX}/"

echo "factorio-backup: ok ${PREFIX}"
