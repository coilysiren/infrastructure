#!/usr/bin/bash
# factorio-server-pre.sh - intentional no-op.
#
# Previous version ran steamcmd to auto-update Factorio on every start.
# Two problems with that:
#   1. Downloads ~1.4 GB on every (re)start even when nothing changed.
#   2. Routinely exceeds systemd's default 90s ExecStartPre timeout,
#      so the unit fails to start at all on slow links.
#
# Updates are now an explicit, separate verb:
#   coily gaming factorio update
#
# Which calls steamcmd directly via ssh, with no systemd timeout
# pressure. Run it before a restart when you want the latest stable
# headless build.
#
# This file stays as the unit's ExecStartPre target so factorio-server.service
# doesn't need a sudo-required edit.

exit 0
