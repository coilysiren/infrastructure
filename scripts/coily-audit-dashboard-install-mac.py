#!/usr/bin/env python3
"""Install (or uninstall) the coily-audit-dashboard launchd agent on Mac.

Mac analog of scripts/coily-audit-dashboard-install.sh (which installs the
systemd timer + service on kai-server). Reads
scripts/launchd/me.coilysiren.coily-audit-dashboard.plist, expands {{HOME}}
to the current user's home, copies the result to ~/Library/LaunchAgents/,
and bootstraps the agent into launchd's gui/UID domain. Idempotent.

The agent re-runs `coily audit dashboard --since 7d` every 5 minutes,
writing to coily's default ~/.coily/dashboard.html so `coily audit open`
(no args) finds it.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

LABEL = "me.coilysiren.coily-audit-dashboard"
SOURCE = Path(__file__).resolve().parent / "launchd" / f"{LABEL}.plist"
AGENT_DIR = Path.home() / "Library" / "LaunchAgents"
TARGET = AGENT_DIR / f"{LABEL}.plist"
OUT_DIR = Path.home() / ".coily"
LOG_DIR = Path.home() / "Library" / "Logs"


def domain() -> str:
    return f"gui/{os.getuid()}"


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    print(f"[coily-audit-dashboard-install-mac] $ {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, check=check, text=True)


def install() -> int:
    if sys.platform != "darwin":
        print("[coily-audit-dashboard-install-mac] launchd agent is Mac-only; skipping.")
        return 0
    if not SOURCE.exists():
        print(f"[coily-audit-dashboard-install-mac] missing source plist: {SOURCE}")
        return 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    AGENT_DIR.mkdir(parents=True, exist_ok=True)

    rendered = SOURCE.read_text().replace("{{HOME}}", str(Path.home()))
    if TARGET.exists() and TARGET.read_text() == rendered:
        print(f"[coily-audit-dashboard-install-mac] {TARGET} already up to date")
    else:
        TARGET.write_text(rendered)
        print(f"[coily-audit-dashboard-install-mac] wrote {TARGET}")

    run(["launchctl", "bootout", domain(), str(TARGET)], check=False)
    run(["launchctl", "bootstrap", domain(), str(TARGET)])
    run(["launchctl", "enable", f"{domain()}/{LABEL}"])
    print(f"[coily-audit-dashboard-install-mac] {LABEL} installed and enabled")
    print(f"[coily-audit-dashboard-install-mac] output: {OUT_DIR}/dashboard.html")
    print(f"[coily-audit-dashboard-install-mac] logs: {LOG_DIR}/coily-audit-dashboard.log")
    return 0


def uninstall() -> int:
    if sys.platform != "darwin":
        return 0
    if TARGET.exists():
        run(["launchctl", "bootout", domain(), str(TARGET)], check=False)
        TARGET.unlink()
        print(f"[coily-audit-dashboard-install-mac] removed {TARGET}")
    else:
        print(f"[coily-audit-dashboard-install-mac] {TARGET} was not present")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    parser.add_argument("--uninstall", action="store_true", help="Remove the launchd agent.")
    args = parser.parse_args()
    return uninstall() if args.uninstall else install()


if __name__ == "__main__":
    sys.exit(main())
