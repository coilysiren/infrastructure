#!/usr/bin/env python3
"""Seed ansible/group_vars/mac.yml from this machine's live Homebrew state.

Captures top-level formulae (`brew leaves`), casks, and third-party taps, then
rewrites the group_vars so a subsequent `coily ansible-mac` check run is a
near no-op. Re-run any time the machine drifts ahead of the declared state;
hand-edit the file afterwards to curate what the fleet should actually carry.

Runs `brew` via subprocess (not the agent bash surface), so it works under the
coily lockdown the way the other uv-run helpers do.
"""
# pylint: disable=wrong-import-position
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GROUP_VARS = REPO / "ansible" / "group_vars" / "mac.yml"

# Core taps that ship with Homebrew and never need declaring.
SKIP_TAPS = {"homebrew/core", "homebrew/cask"}


def brew(*args):
    out = subprocess.run(
        ["brew", *args], check=True, capture_output=True, text=True
    ).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def yaml_list(name, items, comment):
    lines = [f"# {comment}", f"{name}:"]
    if not items:
        lines.append("  []")
    else:
        lines.extend(f"  - {item}" for item in items)
    return "\n".join(lines)


def main():
    taps = [t for t in brew("tap") if t not in SKIP_TAPS]
    formulae = brew("leaves")
    casks = brew("list", "--cask")

    body = "\n".join(
        [
            "# group_vars for the `mac` inventory group. Seeded from the live",
            "# machine by `coily ansible-mac-seed` (scripts/ansible/seed_mac_brew.py).",
            "# Additive: ansible ensures these are present, never uninstalls.",
            "# Curate by hand after seeding - this is the fleet's declared baseline.",
            "",
            yaml_list("homebrew_taps", taps, "Third-party taps (core/cask omitted)."),
            "",
            yaml_list(
                "homebrew_installed_packages",
                formulae,
                "Top-level formulae (brew leaves), not their dependencies.",
            ),
            "",
            yaml_list("homebrew_cask_apps", casks, "GUI apps + tools installed as casks."),
            "",
        ]
    )

    GROUP_VARS.parent.mkdir(parents=True, exist_ok=True)
    GROUP_VARS.write_text(body, encoding="utf-8")
    print(
        f"seeded {GROUP_VARS.relative_to(REPO)}: "
        f"{len(taps)} taps, {len(formulae)} formulae, {len(casks)} casks"
    )


if __name__ == "__main__":
    sys.exit(main())
