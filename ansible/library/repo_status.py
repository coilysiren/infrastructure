#!/usr/bin/python
# GPL-3.0-or-later (https://www.gnu.org/licenses/gpl-3.0.txt). The /usr/bin/python
# shebang is the Ansible convention - the controller rewrites it; env-style fails.
"""Ansible module: git remote-sync + github<->forgejo mirror-drift sweep.

Per local repo across the known org dirs (the same dirs the `repos` role
discovers): `git fetch --all --prune`, then report ahead/behind vs each remote,
uncommitted/untracked, in-progress op, detached HEAD, worktrees, stash, and
stale unmerged branches. In apply mode it also converges the fleet remote
topology and pulls `--ff-only` from each remote; check mode reports only.

github<->forgejo mirror-drift is the HEAD sha compared across the github
(`origin`) and forgejo remotes: divergence is flagged, never resolved - no
force, no push (matches agentic-os-kai/scripts/up-to-date.py, step 6).

Fetch runs in check mode too: it only refreshes remote-tracking refs (no
working-tree change) and reporting ahead/behind/drift requires it. The
mutating steps (pull, remote-config writes) are gated on apply mode.

No opaque values and no secrets: this module only runs git locally. The forgejo
URL it wires points at the canonical host, a meaningful name pinned in code.
"""
from __future__ import annotations

import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

from ansible.module_utils.basic import AnsibleModule

CANONICAL_FORGEJO_HOST = "forgejo.coilysiren.me"
DEFAULT_BRANCHES = ("main", "master")
STALE_BRANCH_SECS = 86_400  # tip older than 24h => land-or-delete (repo-recall parity)


def _git(repo, *args):
    """Run git in `repo`, returning (rc, stripped-stdout)."""
    try:
        r = subprocess.run(
            ["git", "-C", repo, *args], capture_output=True, text=True, check=False,
        )
    except (OSError, ValueError) as exc:
        return 1, str(exc)
    return r.returncode, r.stdout.strip()


def _remote_branch(repo, remote):
    for b in DEFAULT_BRANCHES:
        rc, _ = _git(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/{remote}/{b}")
        if rc == 0:
            return b
    return ""


def _local_default_branch(repo):
    for b in DEFAULT_BRANCHES:
        rc, _ = _git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{b}")
        if rc == 0:
            return b
    return ""


def _in_progress_op(repo):
    """A half-finished git operation (repo-recall's in_progress_op signal)."""
    _, gitdir = _git(repo, "rev-parse", "--git-dir")
    if not gitdir:
        return ""
    base = gitdir if os.path.isabs(gitdir) else os.path.join(repo, gitdir)
    markers = (
        ("rebase", ("rebase-merge", "rebase-apply")),
        ("merge", ("MERGE_HEAD",)),
        ("cherry-pick", ("CHERRY_PICK_HEAD",)),
        ("revert", ("REVERT_HEAD",)),
        ("bisect", ("BISECT_LOG",)),
    )
    for op, names in markers:
        if any(os.path.exists(os.path.join(base, m)) for m in names):
            return op
    return ""


def _worktrees(repo):
    _, out = _git(repo, "worktree", "list", "--porcelain")
    return max(0, sum(1 for line in out.splitlines() if line.startswith("worktree ")) - 1)


def _stale_branches(repo, current):
    """Local branches with unmerged work whose tip is older than 24h - land them
    or delete them (repo-recall's stale_branch signal)."""
    main = _local_default_branch(repo)
    if not main:
        return []
    _, merged_out = _git(repo, "branch", "--merged", main, "--format=%(refname:short)")
    merged = {line.strip() for line in merged_out.splitlines() if line.strip()}
    now = int(time.time())
    out = []
    _, refs = _git(repo, "for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)", "refs/heads")
    for line in refs.splitlines():
        if "\t" not in line:
            continue
        name, ts = line.split("\t", 1)
        if name in (main, current) or name in merged:
            continue
        try:
            age = now - int(ts)
        except ValueError:
            continue
        if age > STALE_BRANCH_SECS:
            out.append(f"{name}({age // 86_400}d)")
    return out


def _github_origin_slug(repo, known_orgs):
    """`<owner>/<name>` if origin's fetch URL is a GitHub repo under a known org,
    else "". Deriving the owner from the URL (not assuming coilysiren) follows a
    repo through the org split; forks under other owners are left untouched."""
    rc, url = _git(repo, "remote", "get-url", "origin")
    if rc != 0 or not url:
        return ""
    for prefix in ("git@github.com:", "https://github.com/", "ssh://git@github.com/"):
        if url.startswith(prefix):
            slug = url[len(prefix):]
            if slug.endswith(".git"):
                slug = slug[:-4]
            owner, _, name = slug.partition("/")
            return f"{owner}/{name}" if owner in known_orgs and name else ""
    return ""


def _ensure_remote_topology(repo, known_orgs, check_mode):
    """Converge `repo` onto the fleet remote convention: origin fetches github +
    pushes both; a `forgejo` fetch remote exists; the default branch pulls from
    forgejo and pushes to origin. Returns the changes applied (or, in check mode,
    that would apply); empty means already correct. No-op for non-known repos."""
    slug = _github_origin_slug(repo, known_orgs)
    if not slug:
        return []
    gh_url = f"git@github.com:{slug}.git"
    fj_url = f"https://{CANONICAL_FORGEJO_HOST}/{slug}.git"
    changes = []
    _, push_out = _git(repo, "remote", "get-url", "--push", "--all", "origin")
    if {u.strip() for u in push_out.splitlines() if u.strip()} != {gh_url, fj_url}:
        changes.append("origin->push both")
        if not check_mode:
            _git(repo, "config", "--unset-all", "remote.origin.pushurl")
            _git(repo, "remote", "set-url", "--add", "--push", "origin", gh_url)
            _git(repo, "remote", "set-url", "--add", "--push", "origin", fj_url)
    _, remotes = _git(repo, "remote")
    if "forgejo" not in remotes.split():
        changes.append("+forgejo remote")
        if not check_mode:
            _git(repo, "remote", "add", "forgejo", fj_url)
    main = _local_default_branch(repo)
    if main:
        changes += _wire_default_branch(repo, main, check_mode)
    return changes


def _wire_default_branch(repo, main, check_mode):
    changes = []
    _, cur_remote = _git(repo, "config", "--get", f"branch.{main}.remote")
    if cur_remote.strip() != "forgejo":
        changes.append(f"{main}.pull->forgejo")
        if not check_mode:
            _git(repo, "config", f"branch.{main}.remote", "forgejo")
    _, cur_push = _git(repo, "config", "--get", f"branch.{main}.pushRemote")
    if cur_push.strip() != "origin":
        changes.append(f"{main}.push->origin")
        if not check_mode:
            _git(repo, "config", f"branch.{main}.pushRemote", "origin")
    return changes


def _remote_states(repo, branch, remotes):
    """Per-remote {branch, sha, ahead, behind} for the default branch on each remote."""
    state = {}
    for r in remotes:
        rb = _remote_branch(repo, r)
        if not rb:
            continue
        _, sha = _git(repo, "rev-parse", f"{r}/{rb}")
        ahead = behind = 0
        if branch != "(detached)":
            _, counts = _git(repo, "rev-list", "--left-right", "--count", f"{branch}...{r}/{rb}")
            parts = counts.split()
            if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                ahead, behind = int(parts[0]), int(parts[1])
        state[r] = {"branch": rb, "sha": sha[:12], "ahead": ahead, "behind": behind}
    return state


def _drift(state):
    """github<->forgejo mirror-drift: remote pairs whose HEAD sha differs."""
    items = list(state.items())
    out = []
    for i, (an, a) in enumerate(items):
        for bn, b in items[i + 1:]:
            if a["sha"] and b["sha"] and a["sha"] != b["sha"]:
                out.append(f"{an}!={bn}")
    return out


def _working_state(repo, branch):
    _, porcelain = _git(repo, "status", "--porcelain")
    lines = [line for line in porcelain.splitlines() if line]
    untracked = sum(1 for line in lines if line.startswith("??"))
    _, stash_out = _git(repo, "stash", "list")
    return {
        "modified": len(lines) - untracked,
        "untracked": untracked,
        "stashes": len([line for line in stash_out.splitlines() if line]),
        "op": _in_progress_op(repo),
        "stale": _stale_branches(repo, branch),
        "worktrees": _worktrees(repo),
    }


def _pull_remotes(repo, branch, remotes):
    pulled = []
    for r in remotes:
        rb = _remote_branch(repo, r)
        if not rb or rb != branch:
            continue
        rc, _ = _git(repo, "pull", "--ff-only", r, branch)
        pulled.append(f"{r}:{'ok' if rc == 0 else 'BLOCKED'}")
    return pulled


def _sync_repo(repo, known_orgs, check_mode):
    # Converge remotes BEFORE fetch so a newly-added forgejo remote is fetched
    # this same pass and its drift is reported.
    wired = _ensure_remote_topology(repo, known_orgs, check_mode)
    _git(repo, "fetch", "--all", "--prune", "--quiet")
    _, branch_out = _git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    branch = branch_out or "(detached)"
    detached = branch in ("HEAD", "(detached)")
    if detached:
        branch = "(detached)"
    _, remotes_out = _git(repo, "remote")
    remotes = [r for r in remotes_out.splitlines() if r]
    state = _remote_states(repo, branch, remotes)
    row = {
        "repo": os.path.basename(repo),
        "org": os.path.basename(os.path.dirname(repo)),
        "branch": branch,
        "detached": detached,
        "drift": _drift(state),
        "remotes": state,
        "wired": wired,
        "pulled": [],
    }
    row.update(_working_state(repo, branch))
    if not check_mode and not detached:
        row["pulled"] = _pull_remotes(repo, branch, remotes)
    return row


def _present_repos(root, known_orgs):
    """Every git checkout across the sibling org dirs under the checkout root's
    parent. Mirrors repo_registry's discovery so the two roles agree on layout.

    The org-dir walk is deliberately duplicated rather than shared: each Ansible
    library module is self-contained (no module_utils) so it stays individually
    droppable, and the two return shapes differ (dict vs list)."""
    # pylint: disable=duplicate-code
    present = []
    parent = os.path.dirname(os.path.abspath(root))
    org_dirs = [os.path.join(parent, o) for o in known_orgs] or [root]
    for org_dir in org_dirs:
        if not os.path.isdir(org_dir):
            continue
        for name in sorted(os.listdir(org_dir)):
            repo = os.path.join(org_dir, name)
            if os.path.isdir(os.path.join(repo, ".git")):
                present.append(repo)
    return present


def _label(row):
    return f"{row.get('org', '?')}/{row['repo']}"


def _is_action_required(row):
    """Hard repo-recall signals: dirty tree, in-progress op, detached HEAD,
    mirror-drift, or a blocked (non-ff) pull."""
    if "error" in row:
        return True
    dirty = row["modified"] + row["untracked"]
    blocked = any("BLOCKED" in p for p in row["pulled"])
    return bool(dirty or row["op"] or row["detached"] or row["drift"] or blocked)


def _summarize(row):
    label = _label(row)
    if "error" in row:
        return f"FAIL {label}: {row['error']}"
    flags = []
    dirty = row["modified"] + row["untracked"]
    if dirty:
        flags.append(f"{dirty} uncommitted ({row['modified']} mod, {row['untracked']} untracked)")
    if row["op"]:
        flags.append(f"{row['op']} IN PROGRESS")
    if row["detached"]:
        flags.append("DETACHED HEAD")
    if row["worktrees"]:
        flags.append(f"{row['worktrees']} worktree(s)")
    if row["stale"]:
        flags.append("stale branch land-or-delete: " + ",".join(row["stale"]))
    if row["stashes"]:
        flags.append(f"{row['stashes']} stash")
    if row["drift"]:
        flags.append("DRIFT " + ",".join(row["drift"]))
    for name, rs in row["remotes"].items():
        if rs["ahead"] or rs["behind"]:
            flags.append(f"{name}:+{rs['ahead']}/-{rs['behind']}")
    if row["wired"]:
        flags.append("remotes wired: " + ",".join(row["wired"]))
    if row["pulled"]:
        flags.append("pull " + " ".join(row["pulled"]))
    status = "FAIL" if _is_action_required(row) else ("CHG" if (row["pulled"] or row["wired"]) else "ok")
    head = label + (f" [{row['branch']}]" if row["branch"] != "main" else "")
    return f"{status} {head}" + (" - " + ", ".join(flags) if flags else "")


def run_module():
    module = AnsibleModule(
        argument_spec={
            "root": {"type": "path", "required": True},
            "known_orgs": {"type": "list", "elements": "str", "default": []},
            "parallel": {"type": "int", "default": 8},
        },
        supports_check_mode=True,
    )
    p = module.params
    repos = _present_repos(p["root"], p["known_orgs"])
    if not repos:
        module.fail_json(msg=f"no git checkouts found across known_orgs under the parent of {p['root']}")

    rows = []
    workers = max(1, p["parallel"])
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_sync_repo, r, p["known_orgs"], module.check_mode): r for r in repos}
        for fut in as_completed(futures):
            repo = futures[fut]
            try:
                rows.append(fut.result())
            except (OSError, ValueError, RuntimeError) as exc:
                rows.append({
                    "repo": os.path.basename(repo),
                    "org": os.path.basename(os.path.dirname(repo)),
                    "error": str(exc),
                })
    rows.sort(key=lambda row: (row["repo"], row.get("org", "")))

    changed = any(r.get("pulled") or r.get("wired") for r in rows)
    module.exit_json(
        changed=bool(changed and not module.check_mode),
        repos=rows,
        summaries=[_summarize(r) for r in rows],
        action_required=[_label(r) for r in rows if _is_action_required(r)],
        repo_count=len(rows),
    )


if __name__ == "__main__":
    run_module()
