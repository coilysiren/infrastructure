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
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import tailscale_admin_oauth_env, terraform_run  # noqa: E402


def main():
    terraform_run(
        "tailscale-oidc", env=tailscale_admin_oauth_env(), auto_approve=True)


if __name__ == "__main__":
    main()
