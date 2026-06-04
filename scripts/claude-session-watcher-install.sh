#!/usr/bin/env bash
# claude-session-watcher-install.sh - install the Claude session watcher
# as a systemd unit on a Linux host. The intended target is the WSL side
# of kai-desktop-tower; it also works on any other systemd Linux box
# that runs Claude Code sessions.
#
# NOT for kai-server itself: prod repo-recall reads kai-server's
# sessions off local disk directly, so kai-server needs no watcher.
#
# Component 1 of the cross-machine session-aggregation pipeline
# (coilyco-flight-deck/infrastructure#224). Watches ~/.claude/projects and HTTP
# POSTs each changed session file to the tailnet-only session-sink.
#
# Idempotent: re-run to upgrade the script, refresh the venv, or change
# the machine id.
#
# Usage:
#   bash scripts/claude-session-watcher-install.sh --machine kai-desktop-tower-wsl
#   bash scripts/claude-session-watcher-install.sh --uninstall
#
# SESSION_SINK_URL is resolved from SSM (/coilysiren/session-sink/url) or
# taken from the SESSION_SINK_URL env var. It embeds a tailnet FQDN (an
# opaque id) so it is never committed - it lands only in the local env
# file /etc/claude-session-watcher.env.
#
# Prereqs: uv on PATH, aws CLI configured (unless SESSION_SINK_URL is
# passed explicitly). Run as the `kai` user; sudo is invoked per-step.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${HOME}/.local/share/claude-session-watcher"
UNIT_DST="/etc/systemd/system/claude-session-watcher.service"
ENV_DST="/etc/claude-session-watcher.env"
SSM_PARAM="/coilysiren/session-sink/url"

MACHINE=""
UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine) MACHINE="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "${UNINSTALL}" == "1" ]]; then
  echo "==> stop + disable unit"
  sudo systemctl disable --now claude-session-watcher.service 2>/dev/null || true
  sudo rm -f "${UNIT_DST}" "${ENV_DST}"
  sudo systemctl daemon-reload
  echo "==> remove install dir ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"
  echo "done. ~/.claude/projects is untouched."
  exit 0
fi

if [[ -z "${MACHINE}" ]]; then
  echo "ERROR: --machine <id> is required (e.g. kai-desktop-tower-wsl)." >&2
  exit 2
fi

# --- resolve the sink URL --------------------------------------------
SINK_URL="${SESSION_SINK_URL:-}"
if [[ -z "${SINK_URL}" ]]; then
  echo "==> resolve SESSION_SINK_URL from SSM ${SSM_PARAM}"
  SINK_URL="$(aws ssm get-parameter --name "${SSM_PARAM}" \
    --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
fi
if [[ -z "${SINK_URL}" || "${SINK_URL}" == "None" ]]; then
  echo "ERROR: could not resolve the session-sink URL." >&2
  echo "  Pass it explicitly:  SESSION_SINK_URL=http://<host>:<port>/ingest $0 --machine ${MACHINE}" >&2
  echo "  or create the SSM param once the session-sink Flask app ships." >&2
  exit 1
fi

# --- provision the install dir + venv --------------------------------
echo "==> install script + venv into ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
install -m 0755 "${REPO_DIR}/scripts/claude-session-watcher.py" "${INSTALL_DIR}/claude-session-watcher.py"
if [[ ! -d "${INSTALL_DIR}/venv" ]]; then
  uv venv "${INSTALL_DIR}/venv"
fi
uv pip install --python "${INSTALL_DIR}/venv/bin/python" --quiet watchdog requests

# --- write the env file (opaque URL stays out of version control) ----
echo "==> write ${ENV_DST}"
sudo install -m 0640 -o root -g root /dev/stdin "${ENV_DST}" <<EOF
# Written by claude-session-watcher-install.sh. Not version-controlled:
# SESSION_SINK_URL embeds a tailnet FQDN (an opaque id).
SESSION_SINK_URL=${SINK_URL}
SESSION_WATCHER_MACHINE=${MACHINE}
EOF

# --- install + enable the unit ---------------------------------------
echo "==> install unit + enable --now"
sudo install -m 0644 "${REPO_DIR}/systemd/claude-session-watcher.service" "${UNIT_DST}"
sudo systemctl daemon-reload
sudo systemctl enable --now claude-session-watcher.service

echo
echo "installed. machine id: ${MACHINE}"
echo "==> status"
sudo systemctl --no-pager status claude-session-watcher.service | head -10 || true
echo
echo "Verify with:"
echo "  journalctl -u claude-session-watcher.service -n 50 --no-pager -f"
