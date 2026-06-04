#!/usr/bin/python
# GPL-3.0-or-later (https://www.gnu.org/licenses/gpl-3.0.txt). The /usr/bin/python
# shebang is the Ansible convention - the controller rewrites it; env-style fails.
"""Ansible module: discover the live repo layout across GitHub + Forgejo.

Read-only fact-gatherer for the `repos` role. Returns which owned repos are
recently active on either remote but absent locally (clone targets) and which
are present. Ported from the legacy converger's step-6 discovery
(agentic-os-kai/scripts/up-to-date.py). The role does the converging
(ansible.builtin.git); this module only reports, so check mode is a no-op.

No opaque values: owner, forgejo host, and the SSM token path are meaningful
names passed in as module args. The Forgejo PAT is fetched from SSM at runtime
and only ever sent to the canonical host (token_destination_allowed).
"""
from __future__ import annotations

import datetime
import json
import os
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from ansible.module_utils.basic import AnsibleModule

CANONICAL_FORGEJO_HOST = "forgejo.coilysiren.me"


def _have(binary):
    return shutil.which(binary) is not None


def _run_stdout(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except (OSError, ValueError) as exc:
        return 1, str(exc)
    return r.returncode, r.stdout


def _within_days(ts, days):
    if not ts:
        return False
    try:
        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return False
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    return 0 <= (now - t).total_seconds() <= days * 86_400


def _token_destination_allowed(api):
    """Only https://forgejo.coilysiren.me may receive the PAT.

    Pinned in code, not config: the allowlist exists to survive a tampered
    config, and a config-driven allowlist could be edited by the same attacker.
    A swapped api/ssm path therefore cannot exfiltrate the token (inbox#36).
    """
    try:
        parsed = urllib.parse.urlparse(api)
    except (ValueError, AttributeError):
        return False
    return parsed.scheme == "https" and parsed.hostname == CANONICAL_FORGEJO_HOST


def _github_inventory(owner, limit=300):
    if not _have("gh"):
        return {}
    rc, out = _run_stdout([
        "gh", "repo", "list", owner, "--limit", str(limit),
        "--json", "name,pushedAt,isArchived,isFork",
    ])
    if rc != 0 or not out:
        return {}
    try:
        data = json.loads(out)
    except ValueError:
        return {}
    return {
        r["name"]: {
            "pushed": r.get("pushedAt") or "",
            "archived": bool(r.get("isArchived")),
            "fork": bool(r.get("isFork")),
        }
        for r in data if r.get("name")
    }


def _forgejo_token(ssm_path):
    if not ssm_path or not _have("coily"):
        return None
    rc, out = _run_stdout([
        "coily", "ops", "aws", "ssm", "get-parameter",
        "--name", ssm_path, "--with-decryption",
        "--query", "Parameter.Value", "--output", "text",
    ])
    out = (out or "").strip()
    if rc != 0 or not out or any(c.isspace() for c in out):
        return None
    return out


def _forgejo_inventory(api, owner, token, max_pages=10, page_size=50):
    if not token:
        return {}
    inv = {}
    for page in range(1, max_pages + 1):
        base = api.rstrip("/")
        url = f"{base}/users/{owner}/repos?limit={page_size}&page={page}"
        req = urllib.request.Request(url, headers={"Authorization": f"token {token}"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
        except (urllib.error.URLError, ValueError, TimeoutError, OSError):
            break
        if not isinstance(data, list) or not data:
            break
        for r in data:
            if r.get("name"):
                inv[r["name"]] = {
                    "pushed": r.get("updated_at") or "",
                    "archived": bool(r.get("archived")),
                    "fork": bool(r.get("fork")),
                }
        if len(data) < page_size:
            break
    return inv


def _present_repos(root, known_orgs):
    present = {}
    parent = os.path.dirname(os.path.abspath(root))
    org_dirs = [os.path.join(parent, o) for o in known_orgs] or [root]
    for org_dir in org_dirs:
        if not os.path.isdir(org_dir):
            continue
        for name in os.listdir(org_dir):
            repo = os.path.join(org_dir, name)
            if os.path.isdir(os.path.join(repo, ".git")):
                present[name] = repo
    return present


def run_module():
    module = AnsibleModule(
        argument_spec={
            "owner": {"type": "str", "required": True},
            "root": {"type": "path", "required": True},
            "known_orgs": {"type": "list", "elements": "str", "default": []},
            "forgejo_api": {"type": "str", "default": ""},
            "forgejo_token_ssm": {"type": "str", "default": ""},
            "recent_days": {"type": "int", "default": 7},
            "forgejo_only": {"type": "list", "elements": "str", "default": []},
        },
        supports_check_mode=True,
    )
    p = module.params
    forgejo_only = set(p["forgejo_only"])

    present_paths = _present_repos(p["root"], p["known_orgs"])
    gh_inv = _github_inventory(p["owner"])

    fj_inv = {}
    if p["forgejo_api"]:
        if not _token_destination_allowed(p["forgejo_api"]):
            module.fail_json(msg=(
                f"forgejo_api {p['forgejo_api']!r} is not the canonical https "
                "Forgejo host; refusing to fetch/send the token"
            ))
        fj_inv = _forgejo_inventory(
            p["forgejo_api"], p["owner"], _forgejo_token(p["forgejo_token_ssm"]),
        )

    if not gh_inv and not fj_inv:
        module.fail_json(msg="no inventory reachable (gh absent/failed and forgejo unreachable)")

    present_names = set(present_paths)
    missing, present = [], []
    for name in sorted(set(gh_inv) | set(fj_inv)):
        g, f = gh_inv.get(name), fj_inv.get(name)
        archived = bool((g and g["archived"]) or (f and f["archived"]))
        fork = bool((g and g["fork"]) or (f and f["fork"]))
        if archived or fork:
            continue
        if name in present_names:
            present.append(name)
            continue
        if name in forgejo_only:
            continue
        recent = (g and _within_days(g["pushed"], p["recent_days"])) or (
            f and _within_days(f["pushed"], p["recent_days"])
        )
        if recent:
            missing.append({"name": name, "source": "github" if g else "forgejo"})

    module.exit_json(
        changed=False,
        missing=missing,
        present=sorted(present),
        github_count=len(gh_inv),
        forgejo_count=len(fj_inv),
    )


if __name__ == "__main__":
    run_module()
