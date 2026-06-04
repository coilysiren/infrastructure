# ansible

First-class Ansible for the coilysiren fleet. `coily ansible-freshen` brings a
host up to date: Homebrew state, the agent-compose context config, and a
reconcile of local clones against the live repo layout. The Ansible port of
`agentic-os-kai/scripts/up-to-date.py`; built to grow into Linux / kai-server.

## Layout

```
ansible/
├── ansible.cfg                     # repo-local config (inventory, roles, library, yaml output)
├── inventory/hosts.yml             # `mac` group -> localhost over a local connection
├── inventory/group_vars/mac.yml    # declared taps / formulae / casks + agent_compose_scopes
├── inventory/group_vars/all.yml    # fleet-wide repos role vars (owner, forgejo, ssm path)
├── library/repo_registry.py        # read-only repo-layout discovery module
├── playbooks/freshen.yml           # freshen a host (homebrew + agent-compose + repos)
├── roles/homebrew/                 # taps + formulae + casks via community.general
├── roles/agent-compose/            # render ~/.config/agent-compose + converge harness symlinks
└── roles/repos/                    # reconcile local clones against the live repo layout
```

## Usage

```bash
coily ansible-mac-seed              # capture this Mac's brew state into group_vars/mac.yml
coily ansible-freshen               # dry run (--check --diff), mutates nothing
coily ansible-freshen action=apply  # converge for real
```

Ansible ships as the `ansible` dependency in the repo's `pyproject.toml`
(uv-managed, version-locked in `uv.lock`); `community.general` Homebrew
modules come bundled. The playbook is **additive** - it ensures declared
packages are present and never uninstalls. Seeding makes a first apply on the
seeded machine a near no-op; curate `group_vars/mac.yml` by hand afterward to
set the fleet baseline.

## agent-compose

The `agent-compose` role owns the per-machine cross-harness context config. It
renders `~/.config/agent-compose/agent-compose.yaml` from `agent_compose_sources`
(set per host class in group_vars) plus the fleet-static load points in
`roles/agent-compose/defaults/main.yml`, then runs the composer to write
`COMPOSED.md` and point each harness's global load point (Claude Code `~/.claude/
CLAUDE.md`, Codex `~/.codex/AGENTS.md`) at it by symlink. The composer inlines
each source file's text verbatim, so `COMPOSED.md` is the full operating context
as real text (no `@import`), which every harness loads identically. It is opt-in
(no config => no-op) and backs up any pre-existing real load-point file to
`<name>.bak`.

The sources are the canonical `AGENTS.md` files themselves: personal machines
(`mac` group) compose the public base (`agentic-os/AGENTS.md`) plus the private
overlay (`agentic-os-kai/AGENTS.md`); a work laptop overrides
`agent_compose_sources` to the public base alone. Per-host source selection is
what scopes the fleet, so the composer's own scope-filtering stays off.

## Adding a Mac

Add the host under the `mac` group in `inventory/hosts.yml`. Remote Macs need
`ansible_host` + SSH reachability (tailnet); the local control host uses
`ansible_connection: local`. A new Mac picks up both the homebrew baseline and
the agent-compose config; set its `agent_compose_scopes` if it is not a personal
machine.
