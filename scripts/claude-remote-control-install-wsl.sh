#!/usr/bin/env bash
# Install the remote-control daemon + 3am restart timer on the WSL side of
# kai-desktop-tower. Run as kai. See docs/claude-remote-control.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="/mnt/x/projects-x/coilysiren"
CLAUDE_JSON="${HOME}/.claude.json"

if [[ ! -d "${WORKDIR}" ]]; then
  echo "ERROR: ${WORKDIR} not reachable. Check the DrvFs mount and that the X: drive is attached on the Windows host." >&2
  exit 1
fi

# Distinct WSL hostname avoids colliding with the Windows-native daemon in the
# dropdown; applied after `wsl --shutdown`. See docs/claude-remote-control.md.
WSL_HOSTNAME="kai-desktop-tower-wsl"
echo "==> ensure /etc/wsl.conf sets hostname=${WSL_HOSTNAME}"
if [[ -f /etc/wsl.conf ]] && grep -Eq '^\s*hostname\s*=' /etc/wsl.conf; then
  current="$(awk -F= '/^[[:space:]]*hostname[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/wsl.conf)"
  if [[ "${current}" != "${WSL_HOSTNAME}" ]]; then
    echo "ERROR: /etc/wsl.conf already has hostname=${current}; refusing to overwrite. Resolve by hand." >&2
    exit 1
  fi
  echo "    (already set to ${WSL_HOSTNAME})"
else
  # Append [network] block; preserves any unrelated sections already present.
  sudo tee -a /etc/wsl.conf >/dev/null <<EOF

[network]
hostname=${WSL_HOSTNAME}
generateHosts=true
EOF
  echo "    wrote [network] hostname=${WSL_HOSTNAME} to /etc/wsl.conf"
  echo "    NOTE: run \`wsl --shutdown\` from Windows once to apply; the daemon will read the new hostname on next start."
fi

echo "==> install unit files"
# Repo names it *-wsl.service to coexist with the kai-server unit; on disk it
# installs as claude-remote-control.service so the shared timer targets it.
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-wsl.service"     /etc/systemd/system/claude-remote-control.service
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-restart.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_DIR}/systemd/claude-remote-control-restart.timer"   /etc/systemd/system/

echo "==> install sudoers drop-in for rc-restart (no TTY)"
sudo install -m 0440 /dev/stdin /etc/sudoers.d/claude-remote-control <<EOF
# Allow kai to bounce the remote-control daemon without a TTY prompt.
# Scoped narrowly to the three subcommands rc-restart needs.
kai ALL=(root) NOPASSWD: /usr/bin/systemctl start claude-remote-control.service, /usr/bin/systemctl stop claude-remote-control.service, /usr/bin/systemctl restart claude-remote-control.service
EOF

echo "==> patch ${CLAUDE_JSON} (idempotent; bail on unexpected pre-existing values)"
if [[ ! -f "${CLAUDE_JSON}" ]]; then
  echo "ERROR: ${CLAUDE_JSON} missing. Run \`claude login\` once as kai before re-running this installer." >&2
  exit 1
fi
# jq edits in place, preserves keys we don't touch. Read-modify-write
# via tmp file so a crashed jq can't truncate the original.
tmp="$(mktemp)"
jq --arg wd "${WORKDIR}" '
  # Bail-don'\''t-overwrite: if any of the three keys is set to a value
  # that is neither absent nor the expected `true`, surface and abort.
  if (.remoteControlAtStartup // true) != true then error("remoteControlAtStartup already set to a non-true value; refusing to overwrite") else . end
  | if (.remoteDialogSeen // true) != true then error("remoteDialogSeen already set to a non-true value; refusing to overwrite") else . end
  | if ((.projects[$wd].hasTrustDialogAccepted // true) != true) then error("projects[\($wd)].hasTrustDialogAccepted already set to a non-true value; refusing to overwrite") else . end
  | .remoteControlAtStartup = true
  | .remoteDialogSeen = true
  | .projects[$wd].hasTrustDialogAccepted = true
' "${CLAUDE_JSON}" > "${tmp}"
mv "${tmp}" "${CLAUDE_JSON}"

echo "==> systemd: daemon-reload + enable --now"
sudo systemctl daemon-reload
sudo systemctl enable --now claude-remote-control.service
sudo systemctl enable --now claude-remote-control-restart.timer

echo
echo "==> status"
sudo systemctl --no-pager status claude-remote-control.service       | head -10 || true
echo
sudo systemctl --no-pager status claude-remote-control-restart.timer | head -10 || true
echo
echo "Verify with:"
echo "  systemctl list-timers claude-remote-control-restart.timer"
echo "  journalctl -u claude-remote-control.service -n 50 --no-pager"
echo "  coily systemctl start claude-remote-control-restart.service  # force one restart"
echo
echo "In claude.ai/code, the Remote Control dropdown should now list 'kai-desktop-tower-wsl'."
