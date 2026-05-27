#!/usr/bin/env python3
"""Push TS_CLIENT_ID + TS_AUDIENCE to each repo in `repos.yaml`.

Reads the `client_ids` + `audiences` outputs from the terraform/tailscale/
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

CHDIR = "terraform/tailscale"


def tf_output_json(name: str) -> dict[str, str]:
    """Pull a sensitive map output as JSON. Captured (not via _lib.run)
    so the raw value never lands on stdout."""
    out = subprocess.check_output(
        ["terraform", f"-chdir={CHDIR}", "output", "-json", name],
        text=True,
    )
    return json.loads(out)


def set_secret(repo: str, name: str, value: str) -> bool:
    # This vintage of gh has no --body-file, and stdin doesn't propagate
    # through the coily passthrough. Pass --body <value> directly: it
    # lands on argv (subprocess uses execvp, not shell), so there is no
    # expansion risk. Federated-identity ids and OIDC audiences are
    # alphanumeric plus `-`, `_`, `.`, `/` - all argv-safe and accepted
    # by coily's metacharacter gate.
    print(f"$ gh secret set {name} --repo coilysiren/{repo}  # body redacted")
    result = subprocess.run(
        ["coily", "ops", "gh", "secret", "set", name, "--repo", f"coilysiren/{repo}", "--body", value],
        check=False,
    )
    return result.returncode == 0


def main() -> None:
    client_ids = tf_output_json("client_ids")
    audiences = tf_output_json("audiences")
    if client_ids.keys() != audiences.keys():
        print(f"mismatched keys: client_ids={list(client_ids)} audiences={list(audiences)}", file=sys.stderr)
        sys.exit(1)
    failed: list[str] = []
    for repo in sorted(client_ids):
        ok_id = set_secret(repo, "TS_CLIENT_ID", client_ids[repo])
        ok_aud = set_secret(repo, "TS_AUDIENCE", audiences[repo])
        if not (ok_id and ok_aud):
            failed.append(repo)
    synced = len(client_ids) - len(failed)
    print(f"synced {synced}/{len(client_ids)} repos")
    if failed:
        print(f"failed: {failed} (repo missing on github or no actions:write access)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
