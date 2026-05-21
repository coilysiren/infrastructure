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
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import tailscale_admin_oauth_env, terraform_run  # noqa: E402


def main():
    terraform_run(
        "tailscale-devices", env=tailscale_admin_oauth_env(), auto_approve=True)


if __name__ == "__main__":
    main()
