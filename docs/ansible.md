# Ansible

First-class Ansible subsystem for converging workstation and host state across
the fleet. Today it converges macOS workstations (Homebrew packages + the
agent-compose cross-harness context config); the layout is built to grow into
Linux hosts and kai-server roles. `ansible/README.md` is the quickstart - this
doc explains each moving part.

## How it is wired

Ansible is a **uv-managed dependency** (`ansible` in `pyproject.toml`, pinned in
`uv.lock`), so it installs with the rest of the repo's Python env and the
`community.general` Homebrew modules come bundled. Every entry point is a coily
verb that delegates to a Make target running `uv run python scripts/ansible/*.py`,
matching the repo's k8s / terraform verb pattern. The runner sets `ANSIBLE_CONFIG`
to `ansible/ansible.cfg` so playbooks run from the repo root.

## Verbs

- **`coily ansible-freshen`** - freshen this host: Homebrew + agent-compose +
  repo clone + layout reconcile + git remote-sync sweep + cross-org dep-tree
  check. Defaults to **check mode** (`--check --diff`): mutates nothing, prints
  the plan. `action=apply` converges for real. Scope to one role with
  `tags=<csv>` (e.g. `tags=git`), which the verb forwards to
  `ansible-playbook --tags`. (Backed by `scripts/ansible/freshen.py`; the
  Ansible port of `agentic-os-kai/scripts/up-to-date.py`.)
- **`coily ansible-mac-seed`** - capture the live machine's `brew leaves`, casks,
  and third-party taps into `inventory/group_vars/mac.yml`, so a subsequent check
  run is a near no-op. Re-run when the machine drifts ahead of the declared state,
  then hand-curate the file. (Backed by `scripts/ansible/seed_mac_brew.py`; calls
  `brew` via subprocess, sidestepping the coily bash lockdown.)

## Layout

- **`ansible.cfg`** - repo-local config: inventory + roles paths, yaml-formatted
  task results (`result_format=yaml`, since the old `community.general.yaml`
  stdout callback was removed in v12), host-key checking off, retry files off.
- **`inventory/hosts.yml`** - the `mac` group. Today just `localhost` over a
  local connection (ansible drives the box it runs on, no SSH). New Macs are
  added here; remote ones need `ansible_host` + tailnet SSH reachability.
- **`inventory/group_vars/mac.yml`** - the declared baseline for the `mac` group:
  `homebrew_taps`, `homebrew_installed_packages`, `homebrew_cask_apps`,
  `agent_compose_scopes`, and `system_python3_packages` (pip packages
  force-installed into the brew system python3 so `language: system` pre-commit
  hooks that `import yaml` against it don't crash - see the homebrew role).
  Auto-loaded because it sits next to the inventory (the reason it lives under
  `inventory/`, not `ansible/`).
- **`inventory/group_vars/all.yml`** - fleet-wide vars for the `repos` role
  (`repos_owner`, `repos_forgejo_api`, `repos_forgejo_token_ssm`,
  `repos_recent_days`, `repos_forgejo_only`, `repos_known_orgs`, `repos_root`).
  All meaningful names; the Forgejo PAT is resolved from SSM at runtime.
- **`playbooks/freshen.yml`** - the host-freshen play. Runs the `homebrew`,
  `agent-compose`, `repos`, `reconcile`, `git`, and `deptree` roles in order,
  each tagged so you can run one in isolation (e.g. `tags=git`).
- **`library/repo_registry.py`** - the read-only discovery module the `repos`
  role calls (local custom module, found via `library = library` in ansible.cfg).
- **`library/repo_status.py`** - the per-repo git sweep module the `git` role
  calls (fetch + status + drift; pull + remote-topology wiring on apply).
- **`library/repo_reconcile.py`** - the layout-reconcile module the `reconcile`
  role calls (move/remove drifted checkouts to match origin org; check-aware).
- **`library/repo_deptree.py`** - the read-only dep-tree validator the `deptree`
  role calls (FAIL on flight-deck -> bridge `dependsOn` edges).
- **`roles/homebrew/`**, **`roles/agent-compose/`**, **`roles/repos/`**,
  **`roles/reconcile/`**, **`roles/git/`**, **`roles/deptree/`** - the units of
  work, detailed below.

## The homebrew role

Ensures the declared taps, formulae, and casks are present, using the
`community.general.homebrew_tap`, `homebrew`, and `homebrew_cask` modules. Taps
converge first so tap-qualified formulae resolve. The tap task carries
`check_mode: false` so it adds taps even under `--check`: a dry-run tap is only
"would-change", but the next task probes brew live for tap-qualified formulae
(`<org>/<tap>/<formula>`), which fail to resolve if the tap was never really
added. Adding taps in check mode trades a little check purity for an honest
formula check - the only way `--check` passes on a host missing a baseline tap
(#243). **Additive only**: it ensures
presence and never uninstalls anything absent from the lists. Casks use
`accept_external_apps: true` to avoid reinstall churn for apps first installed
outside brew (Chrome, Docker Desktop). Because the baseline is seeded from the
live machine, a first apply on a seeded host is a no-op (`changed=0`).

Gotcha surfaced in practice: `brew install` validates the whole list up front and
aborts the batch if any name is unresolvable. An **orphaned keg** (a tapped
formula the tap later renamed) shows up as a hard failure - drop it from the
baseline and `brew uninstall` the stale keg.

After the casks, the role force-installs `system_python3_packages` into the brew
system python3 via that python's own `pip3` (`/opt/homebrew/bin/pip3`, the same
Cellar `/opt/homebrew/bin/python3` resolves to - **not** ansible's uv-env
interpreter). This exists because the catalog pre-commit suite ships hooks
declared `language: system` (`check-coily-yaml`, `catalog-block-present`) that
run `python3 script.py` and `import yaml` against that interpreter rather than an
isolated venv. A freshly-provisioned Mac's brew python3 carries no PyYAML, so
those hooks crash with `ModuleNotFoundError` and block every commit in
catalog-using repos until the package lands. Homebrew python is
externally-managed (PEP 668), so the install passes `--break-system-packages`;
the `ansible.builtin.pip` module keeps it idempotent. Origin:
coilyco-flight-deck/infrastructure#228.

## The agent-compose role

Owns the per-machine cross-harness context config. It renders
`~/.config/agent-compose/agent-compose.yaml` from `agent_compose_scopes`
(per host class in group_vars) plus the fleet-static sources / load points in
`roles/agent-compose/defaults/main.yml`, then runs the composer
(`python3 -m agentic_os.agent_compose`) to write `COMPOSED.md` and point each
harness's global load point (Claude Code `~/.claude/CLAUDE.md`, Codex
`~/.codex/AGENTS.md`) at it by symlink. The only per-machine bit is the scope
list, which is why this is an Ansible var lookup rather than a hand-edited file.
The composer is **idempotent and opt-in** (no config => no-op) and backs up any
pre-existing real load-point file to `<name>.bak`. In check mode it runs
`--dry-run` and mutates nothing.

A source composes onto a host iff its declared scopes intersect the host's
`agent_compose_scopes`, so one source set is correct fleet-wide. Personal Macs
run `[kai-private]` today; a work Mac would want `[work, kai-public]` in its own
group/host_vars, never private.

## The repos role

Reconciles local clones against the live repo layout. The `repo_registry`
module lists owned repos on GitHub (`gh repo list`) and Forgejo (REST API),
skips forks and archived repos, and returns those pushed-to within
`repos_recent_days` that are absent across every `repos_known_orgs` checkout dir.
The role then clones each missing GitHub repo (`ansible.builtin.git`,
check-mode aware); repos recent on Forgejo only are flagged for manual clone.
Repos are **data looped over the host**, not inventory hosts - the inventory
stays machines, so this composes with the other roles in one play.

The Forgejo PAT is fetched from SSM (`repos_forgejo_token_ssm`) at runtime and
sent only to the canonical Forgejo host, pinned in the module code rather than
config so a tampered var set cannot exfiltrate it (coilysiren/inbox#36). The
org-aware layout reconcile and the dep-tree check are the `reconcile` and
`deptree` roles, below.

## The git role

Sweeps every local clone across the `repos_known_orgs` dirs, the maintenance
counterpart to `repos` (which clones what is missing; `git` syncs what is
present). The read-only `repo_status` module (`library/repo_status.py`, same
local-custom-module pattern as `repo_registry`) does all the per-repo git work
and returns structured rows; the role just renders them. Per repo it runs
`git fetch --all --prune`, then reports ahead/behind vs each remote,
uncommitted/untracked, in-progress op (rebase/merge/cherry-pick/revert/bisect),
detached HEAD, worktrees, stash, and stale unmerged branches (tip older than 24h,
unmerged into the default branch - repo-recall's land-or-delete signal).

**github<->forgejo mirror-drift** is the HEAD sha compared across the `origin`
(github) and `forgejo` remotes: a mismatch is flagged `DRIFT forgejo!=origin`.
Drift is **reported, never resolved** - no force, no push - matching
`up-to-date.py` step 6, because resolving it automatically could silently drop
commits on whichever side is behind.

On `action=apply` the module additionally converges the fleet remote topology
(origin pushes both github + forgejo, a `forgejo` fetch remote exists, the
default branch pulls forgejo and pushes origin) and pulls `--ff-only` from each
remote whose default branch matches the checked-out branch; a non-fast-forward
pull reports `BLOCKED` rather than merging. In **check mode** the module reports
only - but it still fetches, since ahead/behind and drift are meaningless
without current remote-tracking refs (fetch touches no working tree). Repos are
**data looped inside the module** (a bounded `parallel` thread pool, default 8),
not inventory hosts, so the sweep composes into the one `mac` play.

A repo flagged in `action_required` (dirty tree, in-progress op, detached HEAD,
mirror-drift, or a blocked pull) needs a human - the sweep surfaces it, never
touches it. Because it runs after `repos`, a repo cloned in the same pass is
swept too.

## The reconcile role

Makes the local `~/projects/<org>/` tree reflect the remotes. The
`repo_reconcile` module walks every checkout across `repos_known_orgs`; for each
whose parent dir is not its origin remote's org it either **moves** it to
`<parent>/<origin-org>/<name>` (when no correct-location copy exists yet) or
**removes** it (when a canonical copy already lives there and the drifted one is
a clean, fully-pushed duplicate). It runs **before** the `git` role so the sweep
operates on the corrected layout. Repos are data looped inside the module, not
inventory hosts.

It is conservative by construction. Any local state - uncommitted changes,
stash, in-progress op, detached HEAD, worktrees, and (for removes) unpushed
commits - FAIL-flags the checkout and leaves it untouched; the remove path
fetches first so the unpushed check sees current remote refs. The harness anchor
(`agentic-os-kai`, the `~/.claude/CLAUDE.md` import + `setup.sh` symlink source)
is pinned and never moved - relocating it is a `setup.sh` migration. In check
mode the module reports the would-move / would-remove plan and changes nothing.

## The deptree role

Validates the cross-org dependency tree, read-only. The `repo_deptree` module
walks the `dependsOn` edges of `catalog-graph.json`, maps each endpoint to its
bucket (`bridge` / `flight-deck` / `stay` / `archive`) from the `decisions:`
block of `repo-split-decisions.yaml`, and **fails the play on any
flight-deck -> bridge edge** - an external-facing repo must not depend on one of
Kai's private tools. Both data files ship in `agentic-os-kai/data/`
(`deptree_kai_root` points at the checkout; override per host). Absent or
unparseable data degrades to a skip with a note, never a hard failure, and the
module runs identically in check and apply mode.

## Safety model

- **Check first.** The default verb is a dry run with a diff. Apply only after
  reviewing it.
- **Additive.** Homebrew convergence never removes packages. agent-compose backs
  up real files before symlinking.
- **Seeded baseline.** Seeding from the live machine makes the first apply a
  near no-op, so the diff is the signal - anything non-empty is real drift.

## The fix-pyexpat playbook

`playbooks/fix-pyexpat.yml` is a one-off macOS Tahoe workaround. The
`python@3.14` 3.14.5 `arm64_tahoe` bottle ships
`pyexpat.cpython-314-darwin.so` linked against `/usr/lib/libexpat.1.dylib`
for `_XML_SetAllocTrackerActivationThreshold`, a symbol Tahoe's system
libexpat does not export (`brew reinstall python@3.14` reproduces the broken
bottle). The play repoints the `.so` at Homebrew's own expat with
`install_name_tool`, re-signs it ad-hoc so dyld accepts the modified Mach-O,
then verifies `import pyexpat`, the aws CLI, and an end-to-end SSM fetch. It
is idempotent - it probes whether `import pyexpat` already works and skips the
rewrite if so - and safe to re-run after `brew upgrade python@3.14`. Remove it
once Homebrew ships a fixed Tahoe bottle.

## Adding a host

Add the host under the `mac` group in `inventory/hosts.yml`. A new Mac picks up
both the Homebrew baseline and the agent-compose config; set its
`agent_compose_scopes` if it is not a personal machine. Linux / kai-server roles
are future work - the inventory and roles layout already accommodates more groups.

## See also

- [../ansible/README.md](../ansible/README.md) - quickstart.
- [FEATURES.md](FEATURES.md) - feature inventory.
- [../AGENTS.md](../AGENTS.md) - agent-facing operating rules.

Cross-reference convention from [coilysiren/agentic-os-kai#313](https://github.com/coilysiren/agentic-os-kai/issues/313).
