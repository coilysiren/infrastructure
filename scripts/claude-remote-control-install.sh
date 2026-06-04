#!/usr/bin/env bash
# Install the remote-control daemon + 3am restart timer on kai-server.
# Run as kai. See docs/claude-remote-control.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="/home/kai/projects/coilysiren"
CLAUDE_JSON="${HOME}/.claude.json"

if [[ ! -d "${WORKDIR}" ]]; then
  echo "ERROR: ${WORKDIR} missing. Create it (or clone into it) before installing the unit." >&2
  exit 1
fi

echo "==> patch ${CLAUDE_JSON} (idempotent; bail on unexpected pre-existing values)"
if [[ ! -f "${CLAUDE_JSON}" ]]; then
  echo "ERROR: ${CLAUDE_JSON} missing. Run \`claude login\` once as kai before re-running this installer." >&2
  exit 1
fi
tmp="$(mktemp)"
jq --arg wd "${WORKDIR}" '
  if (.remoteControlAtStartup // true) != true then error("remoteControlAtStartup already set to a non-true value; refusing to overwrite") else . end
  | if (.remoteDialogSeen // true) != true then error("remoteDialogSeen already set to a non-true value; refusing to overwrite") else . end
  | if ((.projects[$wd].hasTrustDialogAccepted // true) != true) then error("projects[\($wd)].hasTrustDialogAccepted already set to a non-true value; refusing to overwrite") else . end
  | .remoteControlAtStartup = true
  | .remoteDialogSeen = true
  | .projects[$wd].hasTrustDialogAccepted = true
' "${CLAUDE_JSON}" > "${tmp}"
mv "${tmp}" "${CLAUDE_JSON}"

echo "==> install unit files"
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control.service"            /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-restart.service"    /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-restart.timer"      /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/kai-server-node-tooling-ensure.service"   /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/kai-server-node-tooling-ensure.timer"     /etc/systemd/system/

echo "==> ensure required npm globals exist NOW (so the daemon can resolve claude)"
# Run the ensure step inline before (re)starting the daemon. On a fresh node
# version this is what re-materializes the orphaned global that broke things.
"${REPO_DIR}/scripts/kai-server-node-tooling-ensure.sh"

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
# Clear any latched `failed` state from a prior orphan before (re)starting.
sudo systemctl reset-failed claude-remote-control.service 2>/dev/null || true
sudo systemctl enable --now kai-server-node-tooling-ensure.timer
sudo systemctl enable --now claude-remote-control.service
sudo systemctl enable --now claude-remote-control-restart.timer
# If it was already running with the old unit, pick up the new self-heal
# settings.
sudo systemctl restart claude-remote-control.service

echo
echo "==> status"
sudo systemctl --no-pager status claude-remote-control.service            | head -10 || true
echo
sudo systemctl --no-pager status claude-remote-control-restart.timer      | head -10 || true
echo
sudo systemctl --no-pager status kai-server-node-tooling-ensure.timer     | head -10 || true
echo
echo "Verify with:"
echo "  systemctl list-timers claude-remote-control-restart.timer kai-server-node-tooling-ensure.timer"
echo "  journalctl -u claude-remote-control.service -n 50 --no-pager"
echo "  coily systemctl start kai-server-node-tooling-ensure.service  # force a globals refresh"
echo "  coily systemctl start claude-remote-control-restart.service   # force one restart"
