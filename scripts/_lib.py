"""Shared helpers for the per-verb scripts under scripts/k8s/ and scripts/llama/.

Each verb script puts scripts/ on sys.path with a short cookie:

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from _lib import run  # noqa: E402
"""

import os
import shlex
import subprocess
import sys

import boto3


CERT_MANAGER_VERSION = "v1.12.16"


def ssm():
    return boto3.client("ssm", region_name="us-east-1")


def terraform_run(chdir, *, env=None, auto_approve=False):
    """Run terraform against `terraform/<chdir>/`, taking the action from
    argv[1] (default `plan`).

    `init` is special-cased - no action flags. For apply/destroy,
    auto_approve=True appends -auto-approve so terraform's interactive
    approval prompt does not EOF when run without a TTY (e.g. via
    coily); review must happen via a separate `plan` first.
    """
    action = sys.argv[1] if len(sys.argv) > 1 else "plan"
    base = f"terraform -chdir=terraform/{chdir}"
    if action == "init":
        run(f"{base} init", env=env)
        return
    flags = " -auto-approve" if auto_approve and action in ("apply", "destroy") else ""
    run(f"{base} {action}{flags}", env=env)


def tailscale_admin_oauth_env():
    """A copy of os.environ with the admin Tailscale OAuth pair from SSM
    added, ready to hand to terraform.

    The admin pair (/tailscale/admin/oauth-client-{id,secret}, all:write
    scope) mints tagged keys and manages federated identities. Distinct
    from the runtime CI client at /tailscale/oauth-*. Plaintext is
    passed via env, never echoed or persisted.
    """
    client = ssm()
    env = os.environ.copy()
    env["TAILSCALE_OAUTH_CLIENT_ID"] = client.get_parameter(
        Name="/tailscale/admin/oauth-client-id", WithDecryption=True,
    )["Parameter"]["Value"]
    env["TAILSCALE_OAUTH_CLIENT_SECRET"] = client.get_parameter(
        Name="/tailscale/admin/oauth-client-secret", WithDecryption=True,
    )["Parameter"]["Value"]
    return env


def run(cmd, *, env=None, warn=False):
    """Echo + run a shell command. `warn=True` mirrors invoke's warn semantics
    (don't raise on non-zero exit)."""
    if isinstance(cmd, str):
        printable = cmd
        shell = True
    else:
        printable = " ".join(shlex.quote(c) for c in cmd)
        shell = False
    print(f"$ {printable}")
    result = subprocess.run(cmd, shell=shell, env=env, check=False)
    if result.returncode != 0 and not warn:
        sys.exit(result.returncode)
    return result
