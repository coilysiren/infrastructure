#!/usr/bin/env python3
"""List every tailnet device with its hostname, user, tags, addresses.

Useful when an ACL rule isn't matching the way devices.yaml suggests it
should - the tags the Tailscale API reports are what the policy actually
filters on, regardless of what terraform thinks it set.
"""
# pylint: disable=wrong-import-position
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import tailscale_admin_bearer  # noqa: E402


def main():
    token = tailscale_admin_bearer()
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/tailnet/-/devices",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req) as resp:
        devices = json.loads(resp.read())["devices"]

    print(f"{'hostname':30} {'user':25} {'tags':40} addresses")
    for d in sorted(devices, key=lambda d: d["hostname"]):
        tags = ",".join(d.get("tags", [])) or "-"
        user = d.get("user", "-")
        addrs = ",".join(d.get("addresses", []))
        print(f"{d['hostname']:30} {user:25} {tags:40} {addrs}")


if __name__ == "__main__":
    main()
