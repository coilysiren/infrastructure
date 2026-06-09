#!/usr/bin/env python3
"""Run ansible/playbooks/sync.yml to bring this host up to date.

action (argv[1], default `check`):
  check  - dry run with --check --diff, mutates nothing, shows the plan
  apply  - converge for real

A bare `tags=<csv>` token (any position) scopes the run to those role tags,
e.g. `tags=git` to sweep clones without touching homebrew/agent-compose/repos.

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
    tokens = sys.argv[1:]
    tags = ""
    positional = []
    for tok in tokens:
        if tok.startswith("tags="):
            tags = tok.split("=", 1)[1]
        else:
            positional.append(tok)
    action = positional[0] if positional else "check"
    if action not in ("check", "apply"):
        print(f"unknown action {action!r}; use check|apply", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env["ANSIBLE_CONFIG"] = str(REPO / "ansible" / "ansible.cfg")

    flags = " --check --diff" if action == "check" else ""
    if tags:
        flags += f" --tags {tags}"
    run(f"ansible-playbook ansible/playbooks/sync.yml{flags}", env=env)
    return 0


if __name__ == "__main__":
    sys.exit(main())
