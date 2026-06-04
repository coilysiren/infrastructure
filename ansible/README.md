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
├── library/repo_status.py          # per-repo git sweep module (fetch/status/drift; pull on apply)
├── playbooks/freshen.yml           # freshen a host (homebrew + agent-compose + repos + git + keepawake)
├── roles/homebrew/                 # taps + formulae + casks via community.general
├── roles/agent-compose/            # render ~/.config/agent-compose + converge harness symlinks
├── roles/repos/                    # reconcile local clones against the live repo layout
├── roles/git/                      # git remote-sync + github<->forgejo mirror-drift sweep
└── roles/keepawake/                # root LaunchDaemon holding the system awake for remote dispatch
```

## Usage

```bash
coily ansible-mac-seed                       # capture this Mac's brew state into group_vars/mac.yml
coily ansible-freshen                        # dry run (--check --diff), mutates nothing
coily ansible-freshen action=apply           # converge for real
coily ansible-freshen tags=git               # scope to one role (here: the git sweep)
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

## The git role

Sweeps every local clone across the `repos_known_orgs` dirs. The `repo_status`
module fetches each repo (`--all --prune`) and reports ahead/behind per remote,
uncommitted/untracked, in-progress op, detached HEAD, worktrees, stash, stale
unmerged branches, and **github<->forgejo mirror-drift** (the HEAD sha compared
across the `origin` and `forgejo` remotes). On `action=apply` it also converges
the fleet remote topology (origin pushes both remotes, a `forgejo` fetch remote,
default branch pulls forgejo / pushes origin) and pulls `--ff-only` from each
remote; check mode reports only. Drift is **never resolved** - no force, no push
(matches `up-to-date.py` step 6). Fetch runs in check mode too, since reporting
ahead/behind/drift requires current remote-tracking refs. Runs after `repos` so
a repo cloned in the same pass is swept too; `tags=git` scopes to just this role.

## keepawake

The `keepawake` role keeps a workstation reachable so remote dispatch keeps
running after Kai walks away from the desk - whether or not the laptop is
plugged in. It installs a root LaunchDaemon (`me.coilysiren.keepawake`) that
ticks every 60s and reconciles `pmset disablesleep`: held on by default
(power-source-agnostic, so it survives battery and lid-closed, which is the
only state `disablesleep` covers), and **released** in two cases so the hold
can never do harm:

- the nightly maintenance window (`keepawake_maint_hour`, default `03`) so the
  macOS / ansible software-update + reboot cycle runs clean, then re-asserts, and
- a battery floor (`keepawake_floor_pct`, default 30) - on battery below it,
  sleep is allowed so an unattended pack can't drain to zero.

Display sleep is left untouched. Every flip is logged to `/var/log/keepawake.log`
with its reason (`default-hold` / `maint-window` / `battery-floor`). Set
`keepawake_schedule_wake: true` to also `pmset repeat wake` just before the
window so the box is reachable at the maintenance hour even if it slept overnight
(off by default - `pmset repeat` is a single global schedule).

Run just this role with `coily ansible-freshen action=apply` plus a tag filter
(`--tags keepawake`). Uninstall: `sudo launchctl bootout
system /Library/LaunchDaemons/me.coilysiren.keepawake.plist` then remove the
plist + `/usr/local/sbin/keepawake-manager.sh` and `sudo pmset -a disablesleep 0`.

## Adding a Mac

Add the host under the `mac` group in `inventory/hosts.yml`. Remote Macs need
`ansible_host` + SSH reachability (tailnet); the local control host uses
`ansible_connection: local`. A new Mac picks up both the homebrew baseline and
the agent-compose config; set its `agent_compose_scopes` if it is not a personal
machine.
