#!/usr/bin/env python3
"""Push TS_CLIENT_ID + TS_AUDIENCE to each repo in `repos.yaml`.

Reads the `client_ids` + `audiences` outputs from the tailscale-oidc
terraform state and writes each pair into the corresponding repo's GH
Actions secrets via `coily ops gh secret set`. The gh CLI uses Kai's
live device-auth session, so no PAT is needed in SSM (the /github/pat
path is retired).

Run after every `terraform apply` that touches federated identities.

Plaintext values never reach stdout - they're piped into `gh secret
set --body-` via stdin and the script prints only repo/secret names.

Usage: sync_tailscale_oidc_secrets.py
"""
# pylint: disable=wrong-import-position
import json
import subprocess
import sys

CHDIR = "terraform/tailscale-oidc"


def tf_output_json(name: str) -> dict[str, str]:
    """Pull a sensitive map output as JSON. Captured (not via _lib.run)
    so the raw value never lands on stdout."""
    out = subprocess.check_output(
        ["terraform", f"-chdir={CHDIR}", "output", "-json", name],
        text=True,
    )
    return json.loads(out)


def set_secret(repo: str, name: str, value: str) -> None:
    print(f"$ gh secret set {name} --repo coilysiren/{repo}  # via stdin")
    subprocess.run(
        ["coily", "ops", "gh", "secret", "set", name, "--repo", f"coilysiren/{repo}", "--body-file", "-"],
        input=value,
        text=True,
        check=True,
    )


def main() -> None:
    client_ids = tf_output_json("client_ids")
    audiences = tf_output_json("audiences")
    if client_ids.keys() != audiences.keys():
        print(f"mismatched keys: client_ids={list(client_ids)} audiences={list(audiences)}", file=sys.stderr)
        sys.exit(1)
    for repo in sorted(client_ids):
        set_secret(repo, "TS_CLIENT_ID", client_ids[repo])
        set_secret(repo, "TS_AUDIENCE", audiences[repo])
    print(f"synced {len(client_ids)} repos")


if __name__ == "__main__":
    main()
