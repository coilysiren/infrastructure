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
  repo-layout reconcile. Defaults to **check mode** (`--check --diff`): mutates
  nothing, prints the plan. `action=apply` converges for real. Scope to one unit
  with `--tags` (e.g. `--tags repos`). (Backed by `scripts/ansible/freshen.py`;
  the Ansible port of `agentic-os-kai/scripts/up-to-date.py`.)
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
  `homebrew_taps`, `homebrew_installed_packages`, `homebrew_cask_apps`, and
  `agent_compose_scopes`. Auto-loaded because it sits next to the inventory (the
  reason it lives under `inventory/`, not `ansible/`).
- **`inventory/group_vars/all.yml`** - fleet-wide vars for the `repos` role
  (`repos_owner`, `repos_forgejo_api`, `repos_forgejo_token_ssm`,
  `repos_recent_days`, `repos_forgejo_only`, `repos_known_orgs`, `repos_root`).
  All meaningful names; the Forgejo PAT is resolved from SSM at runtime.
- **`playbooks/freshen.yml`** - the host-freshen play. Runs the `homebrew`,
  `agent-compose`, and `repos` roles, each tagged so you can run one in isolation
  (e.g. `--tags repos`).
- **`library/repo_registry.py`** - the read-only discovery module the `repos`
  role calls (local custom module, found via `library = library` in ansible.cfg).
- **`roles/homebrew/`**, **`roles/agent-compose/`**, **`roles/repos/`** - the
  units of work, detailed below.

## The homebrew role

Ensures the declared taps, formulae, and casks are present, using the
`community.general.homebrew_tap`, `homebrew`, and `homebrew_cask` modules. Taps
converge first so tap-qualified formulae resolve. **Additive only**: it ensures
presence and never uninstalls anything absent from the lists. Casks use
`accept_external_apps: true` to avoid reinstall churn for apps first installed
outside brew (Chrome, Docker Desktop). Because the baseline is seeded from the
live machine, a first apply on a seeded host is a no-op (`changed=0`).

Gotcha surfaced in practice: `brew install` validates the whole list up front and
aborts the batch if any name is unresolvable. An **orphaned keg** (a tapped
formula the tap later renamed) shows up as a hard failure - drop it from the
baseline and `brew uninstall` the stale keg.

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
config so a tampered var set cannot exfiltrate it (coilysiren/inbox#36). This is
the first slice of the `up-to-date.py` port; git remote-sync (with github<->
forgejo mirror-drift), org-aware layout reconcile, and the catalog deptree check
land as further roles.

## Safety model

- **Check first.** The default verb is a dry run with a diff. Apply only after
  reviewing it.
- **Additive.** Homebrew convergence never removes packages. agent-compose backs
  up real files before symlinking.
- **Seeded baseline.** Seeding from the live machine makes the first apply a
  near no-op, so the diff is the signal - anything non-empty is real drift.

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
