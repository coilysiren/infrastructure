#!/usr/bin/bash
# Intentional no-op ExecStartPre target. Auto-update on start was dropped (1.4 GB
# per restart, 90s timeout overruns); updates are now `coily gaming factorio update`.

exit 0
