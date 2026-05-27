#!/usr/bin/env python3
"""Dump the current tailnet policy file via the admin OAuth pair.

Round-trip target for `terraform/tailscale/`. Prints the HuJSON policy
body as returned by the API (api.tailscale.com/api/v2/tailnet/-/acl) so
it can be pasted into the module's `tailscale_acl.policy` body before
`terraform import` adopts current state.

Admin OAuth pair at /tailscale/admin/oauth-client-{id,secret}. all:write
scope needed; acl:read alone would also work but the admin pair is
already wired.

Usage: dump_tailscale_acl.py
"""
# pylint: disable=wrong-import-position
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import tailscale_admin_bearer  # noqa: E402


def main():
    token = tailscale_admin_bearer()
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/tailnet/-/acl",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/hujson",
        },
    )
    with urllib.request.urlopen(req) as resp:
        sys.stdout.write(resp.read().decode())


if __name__ == "__main__":
    main()
