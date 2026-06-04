#!/usr/bin/python
# GPL-3.0-or-later (https://www.gnu.org/licenses/gpl-3.0.txt). The /usr/bin/python
# shebang is the Ansible convention - the controller rewrites it; env-style fails.
"""Ansible module: reconcile the local checkout layout against origin remotes.

Step 7 of the up-to-date.py port. For each git checkout across the known org
dirs whose parent dir != its origin remote's org, MOVE it to
<parent>/<origin-org>/<name> when no correct-location copy exists yet, or
REMOVE it when a canonical copy already lives there and the drifted one is
clean + fully pushed. Dirty/unpushed trees, in-progress ops, worktrees, and
the harness anchor are FAIL-flagged, never touched.

Mutating, but only outside check mode: in check mode it reports the
would-move / would-remove plan and changes nothing. Returns structured rows;
the role renders them, mirroring the repo_status / repo_registry split.

No opaque values and no secrets: pure local git + filesystem.
"""
from __future__ import annotations

import os
import shutil
import subprocess

from ansible.module_utils.basic import AnsibleModule

# The harness anchor (CLAUDE.md import + setup.sh symlinks). Relocating it is a
# setup.sh migration, not a sweep move, so reconcile flags but never touches it.
RECONCILE_PIN = frozenset({"agentic-os-kai"})


def _git(repo, *args):
    """Run git in `repo`, returning (rc, stripped-stdout)."""
    try:
        r = subprocess.run(
            ["git", "-C", repo, *args], capture_output=True, text=True, check=False,
        )
    except (OSError, ValueError) as exc:
        return 1, str(exc)
    return r.returncode, r.stdout.strip()


def _present_repos(root, known_orgs):
    """Every git checkout across the sibling org dirs under the checkout root's
    parent. Mirrors repo_registry / repo_status discovery so the roles agree."""
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


def _origin_org(repo):
    """The org segment of origin's URL (e.g. coilyco-bridge), "" if unparseable."""
    rc, url = _git(repo, "remote", "get-url", "origin")
    if rc != 0 or not url:
        return ""
    tail = url.strip()
    for sep in ("://", "@"):
        if sep in tail:
            tail = tail.split(sep, 1)[1]
    # tail is now host[:/]owner/repo(.git); normalize the host delimiter to /
    tail = tail.replace(":", "/", 1)
    parts = [p for p in tail.split("/") if p]
    if len(parts) < 3:
        return ""
    return parts[-2]


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


def _relocation_blockers(repo, require_pushed):
    """Reasons it is unsafe to relocate/remove `repo`, empty if safe.

    A move preserves history, but the convention is to act only on clean trees,
    so any local state blocks. `require_pushed` adds an unpushed-commits check
    (REMOVE only - deleting a duplicate must never drop commits); it fetches
    first so the remote-tracking refs are current."""
    blockers = []
    _, porcelain = _git(repo, "status", "--porcelain")
    lines = [line for line in porcelain.splitlines() if line]
    if lines:
        blockers.append(f"{len(lines)} uncommitted")
    _, stash_out = _git(repo, "stash", "list")
    if [line for line in stash_out.splitlines() if line]:
        blockers.append("stash")
    if (op := _in_progress_op(repo)):
        blockers.append(f"{op} in progress")
    _, branch = _git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if branch.strip() in ("", "HEAD"):
        blockers.append("detached HEAD")
    if _worktrees(repo):
        blockers.append("worktree(s)")
    if require_pushed:
        # Unpushed = HEAD reachable from no remote-tracking ref. Branch-agnostic
        # and ancestor-covering (compares HEAD's exact sha). Fetch first.
        _git(repo, "fetch", "--all", "--prune", "--quiet")
        _, on_remote = _git(repo, "branch", "-r", "--contains", "HEAD")
        if not [line for line in on_remote.splitlines() if line.strip()]:
            blockers.append(f"unpushed commit(s) on {branch.strip()}")
    return blockers


def _plan(root, known_orgs, check_mode):
    """Walk every checkout, decide move/remove/skip, and (outside check mode)
    apply it. Returns (rows, changed)."""
    repos = _present_repos(root, known_orgs)
    # name -> org dirs already holding a correct-location checkout (parent == org).
    # Drives move (no correct copy yet) vs remove (a canonical copy exists).
    correct = {}
    for repo in repos:
        org = _origin_org(repo)
        if org and os.path.basename(os.path.dirname(repo)) == org:
            correct.setdefault(os.path.basename(repo), set()).add(org)

    rows = []
    changed = False
    for repo in repos:
        name = os.path.basename(repo)
        cur_org = os.path.basename(os.path.dirname(repo))
        org = _origin_org(repo)
        if not org:
            rows.append({"repo": name, "org": cur_org, "status": "skip", "reason": "no origin remote"})
            continue
        if cur_org == org:
            continue
        if name in RECONCILE_PIN:
            rows.append({"repo": name, "org": cur_org, "status": "fail", "dest_org": org,
                         "reason": "harness anchor - relocate manually, then re-run setup.sh"})
            continue
        dest = os.path.join(os.path.dirname(os.path.dirname(repo)), org, name)
        has_correct_copy = org in correct.get(name, set())

        if has_correct_copy or os.path.exists(dest):
            blockers = _relocation_blockers(repo, require_pushed=True)
            if blockers:
                rows.append({"repo": name, "org": cur_org, "status": "fail", "dest_org": org,
                             "reason": f"duplicate of {org}/ but {', '.join(blockers)}"})
                continue
            if not check_mode:
                shutil.rmtree(repo)
                changed = True
            rows.append({"repo": name, "org": cur_org, "status": "remove", "dest_org": org})
        else:
            blockers = _relocation_blockers(repo, require_pushed=False)
            if blockers:
                rows.append({"repo": name, "org": cur_org, "status": "fail", "dest_org": org,
                             "reason": ", ".join(blockers)})
                continue
            if not check_mode:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.move(repo, dest)
                correct.setdefault(name, set()).add(org)
                changed = True
            rows.append({"repo": name, "org": cur_org, "status": "move", "dest_org": org})
    return rows, changed


def _summarize(row, check_mode):
    label = f"{row['org']}/{row['repo']}"
    status = row["status"]
    if status == "skip":
        return f"skip {label}: {row['reason']}"
    if status == "fail":
        return f"FAIL {label} -> {row['dest_org']}/: {row['reason']} - left in place"
    verb = {"move": "would move" if check_mode else "moved",
            "remove": "would remove duplicate" if check_mode else "removed duplicate"}[status]
    return f"{verb} {label} -> {row['dest_org']}/{row['repo']}"


def run_module():
    module = AnsibleModule(
        argument_spec={
            "root": {"type": "path", "required": True},
            "known_orgs": {"type": "list", "elements": "str", "default": []},
        },
        supports_check_mode=True,
    )
    p = module.params
    rows, changed = _plan(p["root"], p["known_orgs"], module.check_mode)
    rows.sort(key=lambda row: (row["repo"], row.get("org", "")))
    module.exit_json(
        changed=bool(changed),
        repos=rows,
        summaries=[_summarize(r, module.check_mode) for r in rows if r["status"] != "ok"],
        action_required=[f"{r['org']}/{r['repo']}" for r in rows if r["status"] == "fail"],
        repo_count=len(rows),
    )


if __name__ == "__main__":
    run_module()
