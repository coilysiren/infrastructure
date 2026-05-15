#!/usr/bin/bash
# fdr-remake-pre.sh - render the fdr config from SSM each start.
#
# Writes /home/kai/.local/share/fdr-remake/config.cfg with the bot
# token, channel id, and rcon password fetched from SSM. Idempotent:
# rewrites the file every start, so SSM rotations apply on the next
# `coily gaming factorio restart` without manual edits. Secrets never
# touch the transcript - they're piped from `aws ssm` straight into
# the config file via a here-doc, which is rendered as 0600 by the
# leading umask.
#
# SSM keys (see agentic-os-kai/SSM.md /factorio/* section):
#   /factorio/fdr/discord-bot-token (SecureString)
#   /factorio/fdr/channel-id        (String)
#   /factorio/rcon-password         (SecureString) - shared with
#                                     factorio-server-start.sh
#
# Pre-conditions:
#   - fdr binary built once at /home/kai/.local/share/fdr-remake/fdr.
#     First-time setup: git clone https://codeberg.org/Jaskowicz/fdr-remake,
#     install D++ 10.0.30+ per dpp.dev/installing.html, cmake build,
#     drop the binary at the path above.
#   - aws cli + /home/kai/.aws credentials present (same IAM user as
#     factorio-backup.sh).
#   - factorio-server.service started factorio with --rcon-port=27015
#     and --console-log=<FACTORIO_LOG>. Without these flags the bridge
#     loses both directions but factorio still runs.
#
# Waits up to 60s for the factorio console log to appear, since the
# unit's After= dependency only sequences process start, not the
# first log write. If it never appears, fail loudly - the systemd
# RestartSec=30 will retry.

set -euo pipefail

FDR_DIR="${FDR_DIR:-/home/kai/.local/share/fdr-remake}"
CONFIG_PATH="${FDR_DIR}/config.cfg"
FACTORIO_LOG="${FACTORIO_LOG:-/home/kai/Steam/steamapps/common/FactorioServer/factorio-current.log}"
RCON_PORT="${FACTORIO_RCON_PORT:-27015}"

# Wait for factorio's console log to appear before we start the bridge.
# fdr tails this file for inbound chat; without it the bridge does nothing
# useful even though it'd connect to RCON fine.
deadline=$(( $(date +%s) + 60 ))
while [ ! -e "${FACTORIO_LOG}" ]; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "fdr-remake-pre: factorio console log never appeared at ${FACTORIO_LOG}" >&2
    echo "fdr-remake-pre: check factorio-server.service launched with --console-log" >&2
    exit 2
  fi
  sleep 1
done

bot_token=$(aws ssm get-parameter --name /factorio/fdr/discord-bot-token --with-decryption --query Parameter.Value --output text)
channel_id=$(aws ssm get-parameter --name /factorio/fdr/channel-id --query Parameter.Value --output text)
rcon_password=$(aws ssm get-parameter --name /factorio/rcon-password --with-decryption --query Parameter.Value --output text)

mkdir -p "${FDR_DIR}"
umask 077
cat > "${CONFIG_PATH}" <<EOF
ip=127.0.0.1
port=${RCON_PORT}
pass=${rcon_password}
bot_token=${bot_token}
msg_channel=${channel_id}
allow_achievements=true
console_log_path=${FACTORIO_LOG}
admin_role=
EOF
echo "fdr-remake-pre: rendered ${CONFIG_PATH}"
