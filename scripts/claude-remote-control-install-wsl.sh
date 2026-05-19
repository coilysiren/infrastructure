#!/usr/bin/env bash
# claude-remote-control-install-wsl.sh - install the Claude Code
# remote-control daemon unit on the WSL side of kai-desktop-tower, plus
# its daily 3am restart timer. Idempotent: re-run after editing the
# unit files.
#
# This host registers as `kai-desktop-tower-wsl` in claude.ai/code's
# Remote Control dropdown. The Windows-native installer registers the
# same physical tree as `kai-desktop-tower-native`; the two `--name`s
# must stay distinct or the dropdown collapses them to one entry.
#
# Prereqs:
#   - nvm installed for kai with a default node version selected.
#   - `claude` (npm package) installed under that node version.
#   - `claude login` already run as kai against the active claude.ai
#     subscription (Pro/Max/Team/Enterprise; API keys not supported).
#   - /mnt/x/projects-x/coilysiren reachable (DrvFs auto-mount).
#
# Run as the `kai` user from the repo checkout. Sudo is invoked per-step.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="/mnt/x/projects-x/coilysiren"
CLAUDE_JSON="${HOME}/.claude.json"

if [[ ! -d "${WORKDIR}" ]]; then
  echo "ERROR: ${WORKDIR} not reachable. Check the DrvFs mount and that the X: drive is attached on the Windows host." >&2
  exit 1
fi

# Without this WSL inherits the Windows host's COMPUTERNAME, which
# collides with the Windows-native daemon in the claude.ai/code Remote
# Control dropdown (both report the same gethostname(2)). /etc/wsl.conf
# is read by /init at distro boot, so the change takes effect after the
# next `wsl --shutdown` on Windows. Bail-don't-overwrite if a different
# hostname is already configured.
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
# The WSL service file in the repo is named *-wsl.service so the
# kai-server and WSL units can coexist in version control; on disk the
# canonical name stays claude-remote-control.service so the restart
# timer (shared with kai-server) targets the right unit.
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
