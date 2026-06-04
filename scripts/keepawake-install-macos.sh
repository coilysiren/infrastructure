#!/usr/bin/env bash
# Hold a macOS workstation awake (root LaunchDaemon reconciling `pmset disablesleep`
# every 60s) so remote dispatch survives Kai leaving the desk. Idempotent.

# Held by default, released only in the nightly maint window (MAINT_HOUR) and on battery
# below FLOOR%. Run as the target user, self-escalates via sudo. Override via env vars.

set -euo pipefail

FLOOR="${FLOOR:-30}"             # on battery below this %, release the hold
MAINT_HOUR="${MAINT_HOUR:-03}"   # local hour (00-23) released for maintenance
TICK="${TICK:-60}"               # daemon reconcile interval, seconds

LABEL=me.coilysiren.keepawake
MGR=/usr/local/sbin/keepawake-manager.sh
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG=/var/log/keepawake.log

if [[ "${EUID}" -ne 0 ]]; then
  echo "==> re-exec under sudo (needs root for pmset + LaunchDaemon)"
  exec sudo FLOOR="${FLOOR}" MAINT_HOUR="${MAINT_HOUR}" TICK="${TICK}" bash "$0" "$@"
fi

echo "==> write manager -> ${MGR}"
install -d -m 0755 "$(dirname "${MGR}")"
cat > "${MGR}" <<MGREOF
#!/bin/bash

# keepawake manager, one reconcile tick. Managed by keepawake-install-macos.sh:
# edit there and re-run, not here.
set -euo pipefail
FLOOR=${FLOOR}
MAINT_HOUR="${MAINT_HOUR}"
LOG="${LOG}"

hour=\$(date +%H)
batt=\$(pmset -g batt 2>/dev/null || true)
if printf '%s' "\$batt" | grep -q "AC Power"; then on_ac=1; else on_ac=0; fi
pct=\$(printf '%s' "\$batt" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
[ -z "\${pct:-}" ] && pct=100

desired=1
reason=default-hold
if [ "\$hour" = "\$MAINT_HOUR" ]; then desired=0; reason=maint-window; fi
if [ "\$on_ac" -eq 0 ] && [ "\$pct" -lt "\$FLOOR" ]; then desired=0; reason=battery-floor; fi

current=\$(pmset -g | awk '/SleepDisabled/{print \$2}')
[ -z "\${current:-}" ] && current=0
if [ "\$current" != "\$desired" ]; then
  pmset -a disablesleep "\$desired"
  printf '%s set disablesleep=%s (was %s) reason=%s ac=%s batt=%s%%\n' \\
    "\$(date '+%Y-%m-%dT%H:%M:%S')" "\$desired" "\$current" "\$reason" "\$on_ac" "\$pct" >> "\$LOG"
fi
MGREOF
chmod 0755 "${MGR}"

echo "==> write LaunchDaemon -> ${PLIST}"
cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${MGR}</string>
  </array>
  <key>StartInterval</key><integer>${TICK}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
PLISTEOF
chmod 0644 "${PLIST}"

echo "==> (re)bootstrap LaunchDaemon"
launchctl bootout system "${PLIST}" 2>/dev/null || true
launchctl bootstrap system "${PLIST}"
launchctl kickstart -k "system/${LABEL}"

echo "==> installed (FLOOR=${FLOOR}%, MAINT_HOUR=${MAINT_HOUR}, TICK=${TICK}s)"
echo "    tail flips: sudo tail -f ${LOG}"
echo "    optional pre-window wake so the box is reachable at the maintenance"
echo "    hour even if it slept overnight: sudo pmset repeat wake MTWRFSU 02:58:00"
