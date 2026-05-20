#!/usr/bin/env python3
"""Run terraform against `terraform/tailscale-devices/`.

Mints one tailscale_tailnet_key per service listed in services.yaml,
tagged tag:k8s, preauthorized, persistent. Each key lands in SSM at
/coilysiren/<service>/ts-authkey for a per-service ExternalSecret to
consume.

This module replaces the dynamic OAuth-driven tailscale-operator
pattern: the operator-oauth Secret minted auth keys at pod-start time
inside the cluster, which made the credential blast radius "any device
on tag:k8s-operator" and the inventory invisible to terraform. Static
keys per service push device enrollment into IaC where it belongs.

Admin OAuth pair at /tailscale/admin/oauth-client-{id,secret} (same
as terraform/tailscale-oidc/). all:write needed to mint tagged keys.

Usage: terraform_tailscale_devices.py [action]   # default: plan
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
        run("terraform -chdir=terraform/tailscale-devices init", env=env)
        return
    flags = " -auto-approve" if action in ("apply", "destroy") else ""
    run(f"terraform -chdir=terraform/tailscale-devices {action}{flags}", env=env)


if __name__ == "__main__":
    main()
