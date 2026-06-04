#!/usr/bin/bash
# Render the fdr-remake bridge config (0600) from SSM /factorio/* each start, so
# rotations apply on restart. Needs the fdr binary prebuilt (see agentic-os-kai/SSM.md).

set -euo pipefail

FDR_DIR="${FDR_DIR:-/home/kai/.local/share/fdr-remake}"
CONFIG_PATH="${FDR_DIR}/config.cfg"
FACTORIO_LOG="${FACTORIO_LOG:-/home/kai/Steam/steamapps/common/FactorioServer/factorio-current.log}"
RCON_PORT="${FACTORIO_RCON_PORT:-27015}"

# Wait for factorio's console log before starting the bridge: fdr tails it for
# inbound chat, so without it the bridge is useless even with RCON connected.
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
