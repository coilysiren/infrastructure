#!/usr/bin/env bash
# Install the Claude session watcher as a launchd agent on a Mac. Idempotent.
# Usage: --machine <id> | --uninstall. See docs/claude-session-watcher.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="me.coilysiren.claude-session-watcher"
INSTALL_DIR="${HOME}/.local/share/claude-session-watcher"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
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
  echo "==> unload + remove launchd agent"
  launchctl unload "${PLIST_DST}" 2>/dev/null || true
  rm -f "${PLIST_DST}"
  echo "==> remove install dir ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"
  echo "done. ~/.claude/projects is untouched."
  exit 0
fi

if [[ -z "${MACHINE}" ]]; then
  echo "ERROR: --machine <id> is required (e.g. kai-mac-desktop)." >&2
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
  echo "  or create the SSM param once the session-sink Flask app ships:" >&2
  echo "  coily ops aws ssm put-parameter --name ${SSM_PARAM} --type String --value http://<host>:<port>/ingest" >&2
  exit 1
fi

# --- provision the install dir + venv --------------------------------
echo "==> install script + venv into ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
install -m 0755 "${REPO_DIR}/scripts/claude-session-watcher.py" "${INSTALL_DIR}/claude-session-watcher.py"
if [[ ! -d "${INSTALL_DIR}/venv" ]]; then
  uv venv "${INSTALL_DIR}/venv"
fi
VENV_PY="${INSTALL_DIR}/venv/bin/python"
uv pip install --python "${VENV_PY}" --quiet watchdog requests

# --- render the plist from the repo template ------------------------
echo "==> render launchd plist -> ${PLIST_DST}"
mkdir -p "$(dirname "${PLIST_DST}")"
sed -e "s|{{HOME}}|${HOME}|g" \
    -e "s|{{SESSION_SINK_URL}}|${SINK_URL}|g" \
    -e "s|{{SESSION_WATCHER_MACHINE}}|${MACHINE}|g" \
    "${REPO_DIR}/scripts/launchd/${LABEL}.plist" > "${PLIST_DST}"

# --- (re)load --------------------------------------------------------
echo "==> launchctl reload"
launchctl unload "${PLIST_DST}" 2>/dev/null || true
launchctl load "${PLIST_DST}"

echo
echo "installed. machine id: ${MACHINE}"
echo "Verify with:"
echo "  launchctl list | grep claude-session-watcher"
echo "  tail -f ~/Library/Logs/claude-session-watcher.log"
