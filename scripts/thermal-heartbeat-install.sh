#!/usr/bin/bash
# thermal-heartbeat-install.sh - bring up (or refresh) the thermal heartbeat
# on kai-server. Idempotent: safe to re-run after pulls that change the
# script, the unit files, or the helm values.
#
# Prereqs:
#   - lm-sensors and nvme-cli will be apt-installed.
#   - The two SSM params /sentry-dsn/kai-server and
#     /kai-server/thermal-heartbeat-cron-url already exist.
#   - helm repos for prometheus-community are already added (they were
#     added when the observability stack first went in).
#
# Run as the `kai` user from the repo checkout. Sudo is invoked per-step.

set -euo pipefail

# Source brew's shellenv when running non-interactively so coily and helm
# (both installed via Linuxbrew) land on PATH. ~/.bashrc isn't read by
# `bash scripts/foo.sh`, only by interactive logins.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEXTFILE_DIR="/var/lib/node-exporter/textfile"
ENV_FILE="/etc/thermal-heartbeat.env"

echo "==> apt: lm-sensors + nvme-cli"
sudo apt-get install -y lm-sensors nvme-cli

echo "==> sensors-detect --auto"
# Writes /etc/modules entries for hwmon kernel modules. Safe to re-run.
sudo sensors-detect --auto >/dev/null

echo "==> textfile collector dir + unit files"
sudo install -d -m 0755 -o root "${TEXTFILE_DIR}"
sudo install -m 0644 "${REPO_DIR}/systemd/thermal-heartbeat.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/thermal-heartbeat.timer"   /etc/systemd/system/

echo "==> /etc/thermal-heartbeat.env (from SSM)"
# Render via a tmpfile so a partial fetch never leaves a half-written env
# in place. Permissions land at 0600 root:root before the rename.
DSN_VAL="$(coily aws ssm get-parameter --name /sentry-dsn/kai-server --with-decryption --query Parameter.Value --output text)"
CRON_VAL="$(coily aws ssm get-parameter --name /kai-server/thermal-heartbeat-cron-url --with-decryption --query Parameter.Value --output text)"
TMP="$(sudo mktemp /etc/thermal-heartbeat.env.XXXXXX)"
sudo chmod 0600 "${TMP}"
sudo tee "${TMP}" >/dev/null <<EOF
SENTRY_DSN=${DSN_VAL}
SENTRY_CRON_URL=${CRON_VAL}
EOF
sudo mv "${TMP}" "${ENV_FILE}"
unset DSN_VAL CRON_VAL

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
sudo systemctl enable --now thermal-heartbeat.timer

echo "==> helm upgrade node-exporter"
helm upgrade node-exporter prometheus-community/prometheus-node-exporter \
  --namespace observability \
  -f "${REPO_DIR}/deploy/observability/node-exporter-values.yml"

echo
echo "==> first-run status"
sudo systemctl --no-pager status thermal-heartbeat.timer | head -10 || true
echo
echo "Verify with:"
echo "  sudo journalctl -u thermal-heartbeat.service -n 5 --no-pager"
echo "  curl -s http://localhost:9100/metrics | grep node_thermal_  # from inside the node-exporter pod"
