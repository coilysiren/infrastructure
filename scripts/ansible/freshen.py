#!/usr/bin/env python3
"""Run ansible/playbooks/freshen.yml to bring this host up to date.

action (argv[1], default `check`):
  check  - dry run with --check --diff, mutates nothing, shows the plan
  apply  - converge for real

Sets ANSIBLE_CONFIG so ansible-playbook picks up ansible/ansible.cfg while
running from the repo root.
"""
# pylint: disable=wrong-import-position
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "check"
    if action not in ("check", "apply"):
        print(f"unknown action {action!r}; use check|apply", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env["ANSIBLE_CONFIG"] = str(REPO / "ansible" / "ansible.cfg")

    flags = " --check --diff" if action == "check" else ""
    run(f"ansible-playbook ansible/playbooks/freshen.yml{flags}", env=env)
    return 0


if __name__ == "__main__":
    sys.exit(main())
