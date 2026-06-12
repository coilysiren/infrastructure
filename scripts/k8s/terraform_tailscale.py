#!/usr/bin/env python3
"""Run terraform against `terraform/tailscale/`.

Single stack owning the full tailnet surface: ACL policy, per-physical
device tags, federated identities for CI repos, per-service auth keys,
and the SSM params holding those keys. Merged from the prior
tailscale-{policy,oidc,devices} stacks.

Admin OAuth pair comes from the operator's shell env
(TAILSCALE_OAUTH_CLIENT_ID + TAILSCALE_OAUTH_CLIENT_SECRET), never SSM.
all:write needed for tailscale_acl, tailscale_device_tags,
tailscale_tailnet_key, and tailscale_federated_identity.

Usage: terraform_tailscale.py [action]   # default: plan
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import tailscale_admin_oauth_env, terraform_run  # noqa: E402


def main():
    env = tailscale_admin_oauth_env()
    terraform_run("tailscale", env=env, auto_approve=True)


if __name__ == "__main__":
    main()
