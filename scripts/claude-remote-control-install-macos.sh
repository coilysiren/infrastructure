#!/usr/bin/env bash
# claude-remote-control-install-macos.sh - install the Claude Code
# remote-control daemon as a user LaunchAgent on kais-macbook-pro.
# Idempotent: re-run after changing args; it rewrites the plist and
# re-bootstraps.
#
# Why launchd LaunchAgent (user-scoped) and not a LaunchDaemon (root):
# the daemon needs Kai's login keychain, PATH, SSH/git creds and the
# workspace under /Users/kai - none of which a root LaunchDaemon sees.
#
# Prereqs:
#   - `claude` on PATH (standalone or npm install).
#   - `claude login` already run as this user against the active claude.ai
#     subscription (Pro/Max/Team/Enterprise; API keys not supported).
#   - `claude remote-control --help` lists the subcommand (recent CLI).
#
# Laptop caveat: a LaunchAgent only runs while logged in and awake. Closed
# lid -> the claude.ai/code dropdown entry goes offline. Unlike always-on
# kai-server, this host is best-effort.
#
# Run as the target user (no sudo) from the repo checkout.

set -euo pipefail

# NAME and WORKDIR are overridable for additional macOS hosts (each host
# needs a distinct --name or the claude.ai/code dropdown rows collide).
# Defaults target kais-macbook-pro; kai-mac-kapwing sets both via env.
NAME="${CLAUDE_RC_NAME:-kais-macbook-pro}"
WORKDIR="${CLAUDE_RC_WORKDIR:-${HOME}/projects/coilysiren}"
LABEL="me.coilysiren.claude-remote-control"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
CLAUDE_JSON="${HOME}/.claude.json"
LOG_DIR="${HOME}/Library/Logs"

CLAUDE_BIN="$(command -v claude || true)"
[[ -n "${CLAUDE_BIN}" ]] || { echo "ERROR: claude not on PATH. Install it and re-run." >&2; exit 1; }
"${CLAUDE_BIN}" remote-control --help >/dev/null 2>&1 || {
  echo "ERROR: this claude lacks the remote-control subcommand. Upgrade the CLI." >&2; exit 1; }

[[ -d "${WORKDIR}" ]] || { echo "ERROR: ${WORKDIR} missing. Clone the workspace there first." >&2; exit 1; }
[[ -f "${CLAUDE_JSON}" ]] || {
  echo "ERROR: ${CLAUDE_JSON} missing. Run \`claude login\` once as this user first." >&2; exit 1; }

echo "==> patch ${CLAUDE_JSON} (idempotent; bail on unexpected pre-existing values)"
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

# PATH for spawned sessions: dirname(claude) + homebrew + system. launchd
# hands agents a sparse PATH, so the spawned `coily` / `git` / `node` need
# this set explicitly or they won't resolve.
CLAUDE_DIR="$(cd "$(dirname "${CLAUDE_BIN}")" && pwd)"
BREW_BIN="$(/opt/homebrew/bin/brew --prefix 2>/dev/null || echo /opt/homebrew)/bin"
AGENT_PATH="${CLAUDE_DIR}:${BREW_BIN}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "${HOME}/Library/LaunchAgents" "${LOG_DIR}"

echo "==> write ${PLIST}"
cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${CLAUDE_BIN}</string>
    <string>remote-control</string>
    <string>--spawn</string><string>same-dir</string>
    <string>--name</string><string>${NAME}</string>
    <string>--remote-control-session-name-prefix</string><string>${NAME}</string>
  </array>
  <key>WorkingDirectory</key><string>${WORKDIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${AGENT_PATH}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/claude-remote-control.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/claude-remote-control.err</string>
</dict>
</plist>
PLISTEOF

echo "==> (re)bootstrap LaunchAgent"
GUI="gui/$(id -u)"
launchctl bootout "${GUI}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "${GUI}" "${PLIST}"
launchctl enable "${GUI}/${LABEL}"
launchctl kickstart -k "${GUI}/${LABEL}" || true

echo
echo "==> status"
launchctl print "${GUI}/${LABEL}" 2>/dev/null | grep -iE "state =|pid =|program =" | head -10 || true
echo
echo "Verify with:"
echo "  launchctl print gui/\$(id -u)/${LABEL}"
echo "  tail -f ${LOG_DIR}/claude-remote-control.log"
echo "  # then check the claude.ai/code Remote Control dropdown for '${NAME}'"
echo "Uninstall with:"
echo "  launchctl bootout gui/\$(id -u)/${LABEL} && rm ${PLIST}"
