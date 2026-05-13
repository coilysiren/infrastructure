#!/usr/bin/env python3
"""Install (or uninstall) the coily-audit-dashboard launchd agents on Mac.

Mac analog of scripts/coily-audit-dashboard-install.sh (which installs the
systemd timer + service on kai-server). Reads two source plists from
scripts/launchd/, expands {{HOME}} to the current user's home, copies the
results to ~/Library/LaunchAgents/, and bootstraps them into launchd's
gui/UID domain. Idempotent.

Two agents:
  1. me.coilysiren.coily-audit-dashboard - 5-minute regeneration tick.
     Runs `coily audit dashboard --since 7d`, writes to
     ~/.coily/dashboard.html (coily's default; `coily audit open` finds it).
  2. me.coilysiren.coily-dashboard-server - long-lived Caddy file-server
     bound to 127.0.0.1:8082. Lets Safari's "File -> Add to Dock" work
     (file:// URLs are not eligible). Open http://localhost:8082/dashboard.html.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

LABELS = [
    "me.coilysiren.coily-audit-dashboard",
    "me.coilysiren.coily-dashboard-server",
]
LAUNCHD_DIR = Path(__file__).resolve().parent / "launchd"
AGENT_DIR = Path.home() / "Library" / "LaunchAgents"
OUT_DIR = Path.home() / ".coily"
LOG_DIR = Path.home() / "Library" / "Logs"


def domain() -> str:
    return f"gui/{os.getuid()}"


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    print(f"[coily-audit-dashboard-install-mac] $ {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, check=check, text=True)


def install_one(label: str) -> int:
    source = LAUNCHD_DIR / f"{label}.plist"
    target = AGENT_DIR / f"{label}.plist"
    if not source.exists():
        print(f"[coily-audit-dashboard-install-mac] missing source plist: {source}")
        return 1

    rendered = source.read_text().replace("{{HOME}}", str(Path.home()))
    if target.exists() and target.read_text() == rendered:
        print(f"[coily-audit-dashboard-install-mac] {target} already up to date")
    else:
        target.write_text(rendered)
        print(f"[coily-audit-dashboard-install-mac] wrote {target}")

    run(["launchctl", "bootout", domain(), str(target)], check=False)
    run(["launchctl", "bootstrap", domain(), str(target)])
    run(["launchctl", "enable", f"{domain()}/{label}"])
    print(f"[coily-audit-dashboard-install-mac] {label} installed and enabled")
    return 0


def install() -> int:
    if sys.platform != "darwin":
        print("[coily-audit-dashboard-install-mac] launchd agents are Mac-only; skipping.")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    AGENT_DIR.mkdir(parents=True, exist_ok=True)

    for label in LABELS:
        rc = install_one(label)
        if rc != 0:
            return rc

    print(f"[coily-audit-dashboard-install-mac] output: {OUT_DIR}/dashboard.html")
    print("[coily-audit-dashboard-install-mac] dashboard URL: http://localhost:8082/dashboard.html")
    print(f"[coily-audit-dashboard-install-mac] regen logs: {LOG_DIR}/coily-audit-dashboard.log")
    print(f"[coily-audit-dashboard-install-mac] server logs: {LOG_DIR}/coily-dashboard-server.log")
    return 0


def uninstall_one(label: str) -> None:
    target = AGENT_DIR / f"{label}.plist"
    if target.exists():
        run(["launchctl", "bootout", domain(), str(target)], check=False)
        target.unlink()
        print(f"[coily-audit-dashboard-install-mac] removed {target}")
    else:
        print(f"[coily-audit-dashboard-install-mac] {target} was not present")


def uninstall() -> int:
    if sys.platform != "darwin":
        return 0
    for label in LABELS:
        uninstall_one(label)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    parser.add_argument("--uninstall", action="store_true", help="Remove the launchd agents.")
    args = parser.parse_args()
    return uninstall() if args.uninstall else install()


if __name__ == "__main__":
    sys.exit(main())
