#!/usr/bin/env python3
"""Run terraform against `terraform/tailscale-oidc/`.

Wires the admin Tailscale OAuth client (all:write scope, long-lived;
provider auto-rotates short-lived tokens it mints) into the provider
env from SSM. Plaintext values are passed via env, never echoed or
persisted. See docs/tailscale-oidc.md.

Admin OAuth pair lives at /tailscale/admin/oauth-client-{id,secret},
wrapped under the alias/admin-only KMS key. Distinct from the runtime
CI client at /tailscale/oauth-* (devices/auth_keys scope only), which
cannot manage ACLs or federated identities.

Per-repo TS_CLIENT_ID + TS_AUDIENCE secrets are pushed by a separate
sync_tailscale_oidc_secrets.py via the gh CLI's live auth; this module
exposes them as outputs but no longer writes them itself (no PAT).

Usage: terraform_tailscale_oidc.py [action]   # default: plan
"""
# pylint: disable=wrong-import-position
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run, ssm  # noqa: E402


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "plan"
    ssm_client = ssm()
    client_id = ssm_client.get_parameter(
        Name="/tailscale/admin/oauth-client-id",
        WithDecryption=True,
    )["Parameter"]["Value"]
    client_secret = ssm_client.get_parameter(
        Name="/tailscale/admin/oauth-client-secret",
        WithDecryption=True,
    )["Parameter"]["Value"]
    env = os.environ.copy()
    env["TAILSCALE_OAUTH_CLIENT_ID"] = client_id
    env["TAILSCALE_OAUTH_CLIENT_SECRET"] = client_secret
    if action == "init":
        run("terraform -chdir=terraform/tailscale-oidc init", env=env)
        return
    # Run via coily passes no TTY, so terraform's interactive approval
    # prompt EOFs. Append -auto-approve for write actions; review must
    # happen via a separate `action=plan` first.
    flags = " -auto-approve" if action in ("apply", "destroy") else ""
    run(f"terraform -chdir=terraform/tailscale-oidc {action}{flags}", env=env)


if __name__ == "__main__":
    main()
