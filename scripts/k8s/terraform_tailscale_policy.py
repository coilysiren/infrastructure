#!/usr/bin/env python3
"""Run terraform against `terraform/tailscale-policy/`.

Owns the tailnet policy file (tagOwners + ACL rules + ssh + nodeAttrs)
and the per-physical-device tag assignments enumerated in devices.yaml.
Companion to terraform/tailscale-devices/ which owns the per-service
auth keys for k8s sidecars.

Bootstrap sequence on first run (state is empty):
  1. action=init
  2. action=import-acl
       Adopts the current tailnet policy into tailscale_acl.policy
       state. Required before plan, otherwise the resource thinks it
       owns nothing and apply would clobber the live policy with the
       hard-coded body in main.tf on subsequent runs.
  3. action=plan
       Should show only additive diffs (new tagOwners + per-host tag
       assignments). Adjust main.tf until the diff matches what you
       expect, then apply.

Admin OAuth pair at /tailscale/admin/oauth-client-{id,secret}. all:write
needed for both tailscale_acl and tailscale_device_tags.

Usage: terraform_tailscale_policy.py [action]   # default: plan
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run, tailscale_admin_oauth_env, terraform_run  # noqa: E402


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "plan"
    env = tailscale_admin_oauth_env()

    if action == "import-acl":
        module = "terraform/tailscale-policy"
        run(f"terraform -chdir={module} init", env=env)
        run(
            f"terraform -chdir={module} import tailscale_acl.policy -",
            env=env,
        )
        return

    terraform_run("tailscale-policy", env=env, auto_approve=False)


if __name__ == "__main__":
    main()
