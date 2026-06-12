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


def tailscale_admin_bearer():
    """Exchange the admin OAuth client_credentials for a short-lived bearer.

    Returned token authorizes the Tailscale REST API at api.tailscale.com.
    Used by helpers that need to hit the API directly rather than via the
    terraform provider (dump_tailscale_acl, list_tailscale_devices, etc.).
    """
    import base64  # pylint: disable=import-outside-toplevel
    import json as _json  # pylint: disable=import-outside-toplevel
    import urllib.parse  # pylint: disable=import-outside-toplevel
    import urllib.request  # pylint: disable=import-outside-toplevel

    env = tailscale_admin_oauth_env()
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/oauth/token",
        data=urllib.parse.urlencode({"grant_type": "client_credentials"}).encode(),
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": "Basic " + base64.b64encode(
                f"{env['TAILSCALE_OAUTH_CLIENT_ID']}:{env['TAILSCALE_OAUTH_CLIENT_SECRET']}".encode()
            ).decode(),
        },
    )
    with urllib.request.urlopen(req) as resp:
        return _json.loads(resp.read())["access_token"]


def tailscale_admin_oauth_env():
    """A copy of os.environ validated to carry the admin Tailscale OAuth
    pair, ready to hand to terraform.

    The admin pair (all:write scope) rewrites the tailnet ACL, the
    boundary that decides which machines an agent can SSH into - so it
    must never sit in SSM or any other agent-readable store. The
    operator mints it in the Tailscale admin console and exports both
    halves in the shell that runs the verb. Distinct from the runtime
    CI clients under /tailscale/oauth/. Plaintext is passed via env,
    never echoed or persisted.
    """
    env = os.environ.copy()
    missing = [
        name
        for name in ("TAILSCALE_OAUTH_CLIENT_ID", "TAILSCALE_OAUTH_CLIENT_SECRET")
        if not env.get(name)
    ]
    if missing:
        sys.exit(
            "missing env: " + ", ".join(missing) + ". Mint an all:write OAuth "
            "client at https://login.tailscale.com/admin/settings/trust-credentials "
            "and export both halves in this shell. The admin pair stays out of SSM "
            "by design (docs/tailscale.md)."
        )
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
