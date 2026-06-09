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

- **`ward exec ansible-sync`** - sync this host: Homebrew + agent-compose +
  repo clone + layout reconcile + git remote-sync sweep + cross-org dep-tree
  check. Defaults to **check mode** (`--check --diff`): mutates nothing, prints
  the plan. `action=apply` converges for real. Scope to one role with
  `tags=<csv>` (e.g. `tags=git`), which the verb forwards to
  `ansible-playbook --tags`. (Backed by `scripts/ansible/sync.py`; the
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
- **`inventory/hosts.yml`** - bare `localhost` over a local connection (ansible
  drives the box it runs on, no SSH). The sync play's first task `group_by`s
  it into the `mac` or `linux` group by `ansible_system`, so one inventory is
  correct on any machine. Remote hosts would need `ansible_host` + tailnet SSH.
- **`inventory/group_vars/mac.yml`** - the declared baseline for the `mac` group:
  `homebrew_taps`, `homebrew_installed_packages`, `homebrew_cask_apps`,
  `agent_compose_scopes`, and `system_python3_packages` (pip packages
  force-installed into the brew system python3 so `language: system` pre-commit
  hooks that `import yaml` against it don't crash - see the homebrew role).
  Auto-loaded because it sits next to the inventory (the reason it lives under
  `inventory/`, not `ansible/`).
- **`inventory/group_vars/linux.yml`** - the `linux` baseline (kai-server, ser8).
  Seeded with the cross-platform subset of `mac.yml`: the CLI toolkit plus the
  k3s (`helm`, `stern`), terraform (`tfenv`, `tflint`), and security (`grype`,
  `trufflehog`) tooling, and the source-built fleet tools (`coily`, `o2r`,
  `ward`, `mcporter`, which ship no linux bottle). Dropped: GUI casks, macOS-only
  formulae (`duti`, `lima`, `pinentry-mac`, `scrcpy`, `diff-pdf`),
  `system_python3_packages` (its pip path is macOS-only), and the workstation
  dev toolchains (`docker`, `tailscale`, JVM, .NET) that a host re-adds in its
  own group/host_vars when needed. `default_app_editor_bundle_id` is empty, so
  the macOS-only default-apps role skips cleanly.
- **`inventory/group_vars/all.yml`** - fleet-wide vars for the `repos` role
  (`repos_owner`, `repos_forgejo_api`, `repos_forgejo_token_ssm`,
  `repos_recent_days`, `repos_forgejo_only`, `repos_known_orgs`, `repos_root`).
  All meaningful names; the Forgejo PAT is resolved from SSM at runtime.
- **`playbooks/sync.yml`** - a `group_by` classify play (OS -> mac/linux),
  then the host-sync play. Runs `fleet-orgs`, `shell`, `homebrew`,
  `default-apps`, `agent-compose`, `codex-permissions`, `claude-hooks`,
  `kai-config`, `repos`, `reconcile`, `skills`, `agents-pointer`, `git`, `lockdown`, `precommit-hooks`,
  `repo-data`, and `deptree` in order, each tagged so you can run one in
  isolation (e.g. `tags=git`). `fleet-orgs` carries the `always` tag so
  tag-scoped runs still resolve the org list first.
- **`library/repo_registry.py`** - the read-only discovery module the `repos`
  role calls (local custom module, found via `library = library` in ansible.cfg).
- **`library/repo_status.py`** - the per-repo git sweep module the `git` role
  calls (fetch + status + drift; pull + remote-topology wiring on apply).
- **`library/repo_reconcile.py`** - the layout-reconcile module the `reconcile`
  role calls (move/remove drifted checkouts to match origin org; check-aware).
- **`library/repo_deptree.py`** - the read-only dep-tree validator the `deptree`
  role calls (FAIL on flight-deck -> bridge `dependsOn` edges).
- **`roles/shell/`**, **`roles/homebrew/`**, **`roles/default-apps/`**,
  **`roles/agent-compose/`**, **`roles/codex-permissions/`**, **`roles/repos/`**,
  **`roles/reconcile/`**, **`roles/git/`**, **`roles/deptree/`** - the units of work, detailed below.
- **`roles/fleet-orgs/`**, **`roles/lockdown/`**, **`roles/precommit-hooks/`**,
  **`roles/repo-data/`** - the fleet-management rollout roles, detailed below.

## The shell role

Symlinks the host shell config, the ansible-native replacement for `agentic-os/setup.sh`'s `ensure_link`. Points `~/.zshrc -> agentic-os/shell/zshrc` and `~/.bashrc -> agentic-os/shell/bashrc` (both source the shared `shell/common.sh`), the `gpg-ssm` wrapper and the `~/.local/bin` PATH helpers (`verbatim-echo`, `anthropic-pulse`, `github-pulse`, `git-diff-global`), and on macOS `~/.hammerspoon/init.lua`. A pre-existing regular `~/.zshrc` / `~/.bashrc` is backed up to `<path>.bak` before linking, matching setup.sh's first-run behaviour. Uses `ansible.builtin.file` with `state: link`, so it is idempotent and check-mode honest. Host branching is by `ansible_system` (the gpg-ssm `.cmd` variant and hammerspoon are guarded).

## The homebrew role

Ensures the declared taps, formulae, and casks are present, using the
`community.general.homebrew_tap`, `homebrew`, and `homebrew_cask` modules. Taps
converge first so tap-qualified formulae resolve. The tap task carries
`check_mode: false` so it adds taps even under `--check`: a dry-run tap is only
"would-change", but the next task probes brew live for tap-qualified formulae
(`<org>/<tap>/<formula>`), which fail to resolve if the tap was never really
added. Adding taps in check mode trades a little check purity for an honest
formula check - the only way `--check` passes on a host missing a baseline tap
(#243). **Present by default, with an explicit removal surface**: it ensures the
`homebrew_installed_packages` / `homebrew_cask_apps` lists are installed and
never touches anything merely omitted from them, but the
`homebrew_installed_packages_absent` / `homebrew_cask_apps_absent` lists are
uninstalled (`state: absent`) so a tool can be retired fleet-wide instead of
lingering on machines that once had it - e.g. `warp` (Stable) was retired in
favour of `warp@preview` (see the default-apps role). Removal is idempotent (a
no-op once the tool is gone). Casks use
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

Finally the role converges `pipx_packages` via `community.general.pipx` (`state:
present`, the idempotent install alias), backed by the brew `pipx` formula in the
baseline. This is for Python CLIs that ship as pipx apps rather than brew
formulae, each in its own isolated venv with no system-python pollution. Today
just `python-kasa`, which provides the `kasa` command for the home-1 Kasa HS300
smart strip (see the `machine-power-strip` skill).

## The default-apps role

Sets macOS default file-type handlers via `duti` (the formula ships from the homebrew baseline), so editor-shaped files open in the editor Kai actually uses. Driven by `default_app_editor_bundle_id` and `default_app_editor_extensions` in `group_vars/mac.yml`; today that is Warp Preview (`dev.warp.Warp-Preview`) over ~35 extensions. The role queries `duti -x <ext>` per extension and only runs `duti -s <bundle> <ext> all` when the resolved handler differs, so it is idempotent and reports `changed` honestly. A no-op when `default_app_editor_bundle_id` is empty (the role default), so non-mac hosts skip it cleanly.

The hard constraint: **LaunchServices only accepts a handler for a real UTI.** Extensions whose only UTI is dynamic (`dyn.*` - `go`, `rs`, `toml`, `tsx`, `tf`, `ini`, `dockerfile`, ...) fail `duti -s` with error -50 and are deliberately **not** in the list. Those are handled structurally instead: the homebrew baseline installs only `warp@preview`, not Stable (`warp`), so Preview is the sole Warp claimant and wins their open-by-default. With both builds installed, Stable out-ranked Preview and grabbed every dynamic-UTI dev file. `html`/`xhtml` are intentionally omitted so a double-clicked page still opens in the browser. Scope with `tags=default-apps`.

## The agent-compose role

Owns the per-machine cross-harness context config. It renders
`~/.config/agent-compose/agent-compose.yaml` from `agent_compose_sources`
(per host class in group_vars) plus the fleet-static load points in
`roles/agent-compose/defaults/main.yml`, then runs the composer
(`python3 -m agentic_os.agent_compose`) to write `COMPOSED.md` and point each
harness's global load point (Claude Code `~/.claude/CLAUDE.md`, Codex
`~/.codex/AGENTS.md`) at it by symlink. The only per-machine bit is the source
list, which is why this is an Ansible var lookup rather than a hand-edited file.
The composer is **idempotent and opt-in** (no config => no-op) and backs up any
pre-existing real load-point file to `<name>.bak`. In check mode it runs
`--dry-run` and mutates nothing.

Per-host source selection scopes the fleet, so the composer's own scope-filtering
is left off and `agent_compose_sources` is a flat ordered list. The `mac` group's
default is the personal-machine pair (public base + kai-private overlay). The
`work` child group (`group_vars/work.yml`) is for employer-owned machines: public
base + a work overlay, **never kai-private**.

The work overlay lives in the employer workspace, so its path carries the
employer name, which must not land in tracked vars. `work.yml` instead names an
SSM param (`agent_compose_work_subdir_ssm`) holding the local projects subdir.
The role resolves it at converge time (`coily ops aws ssm get-parameter`) into
`agent_compose_work_root`, so the name surfaces only in SSM and the host-local
rendered config, both untracked. A personal mac leaves the SSM path empty and the
resolve step is skipped.

## The skills role

Converges the Claude/Codex skill surface by running agentic-os-kai's idempotent `mount-skills.sh`: empties the always-global `~/.claude/skills`, self-mounts agentic-os-kai's own skills into its `.claude/skills`, aggregates the `repo-<name>` pointer skills across the org dirs, and pulls per-repo capabilities. The script rebuilds symlinks each run and has no dry-run, so the role skips it in check mode (like repo-data) and no-ops on a host without the agentic-os-kai checkout. Replaces agentic-os-kai/setup.sh's skill section.

## The claude-hooks role

Converges Claude Code harness wiring in `~/.claude/settings.json`. Renders the o2r cross-node nudge hook script and wires it as a `PreToolUse` Bash hook via the `claude_settings_hook` module. It also runs the idempotent agentic-os mergers `install-agent-name.py` (statusLine + SessionStart self-name) and `install-session-pulse.py` (SessionStart pulse hook) - wrapped, not reimplemented, with `--dry-run` driving check mode. These two replace the corresponding `agentic-os/setup.sh` steps.

## The kai-config role

Converges agentic-os-kai host config, the ansible-native replacement for that repo's `setup.sh` config steps. Runs `merge-mcporter.py` (home `~/.mcporter/mcporter.json` from the coilysiren + kapwing sources) and `merge-claude-settings.py` (cross-machine shared rules), and wires the SSM-backed forgejo HTTPS credential helper via `community.general.git_config`. mcporter rewrites identical content every run, so the role reports change by content checksum (before/after stat), not the script's always-"wrote" output. The whole role is a no-op on a host without the agentic-os-kai checkout (a `block` guarded on the scripts dir).

## The codex-permissions role

Manages a named profile in `~/.codex/config.toml` that extends Codex's workspace
defaults while narrowing Kai's project access. `coilyco-flight-deck` and
`coilysiren` are explicit workspace roots. `coilyco-bridge`, Claude's config,
the Claude-only composed context, and the composer source config are denied.
The profile becomes the user-level `default_permissions`, so new Codex sessions
inherit the boundary even when launched from the projects umbrella.

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

### Remote topology

Three remotes, all normal fetch+push remotes (nothing is push-disabled):

* `origin` - canonical forgejo (`forgejo.coilysiren.me/<org>/<repo>.git`). The default for pull and push.
* `forgejo` - the same canonical forgejo URL under an explicit name, so `git push forgejo` is unambiguous.
* `github` - the github mirror (`git@github.com:<org>/<repo>.git`).

`origin == forgejo` by URL: they point at the same host and never drift from each other. `github` is the only one that can lag or run ahead.

### Push / pull rules

* **Pull** - from `origin` (canonical forgejo). The default branch's `branch.<main>.remote` is pinned to `origin`.
* **Push** - to `origin` (canonical forgejo). The default branch's `branch.<main>.pushRemote` is pinned to `origin`, so a bare `git push` always lands on forgejo.
* **Pushing github** - github keeps a real push URL but is never any branch's default, so it only takes a push when named on purpose: `git push github <branch>`. That is git's "be explicit to push here" gate (`pushRemote` selects the implicit target; everything else is opt-in by name). The github copy is normally refreshed by CI, so a manual `git push github` is the rare deliberate case, not the default path.
* **Divergence** - on `action=apply`, if local has diverged from `origin`, the sweep rebases local commits onto origin via explicit `--rebase` (not the host's ambient `pull.rebase`, so it is deterministic before the git role has converged a host). A failed rebase is aborted at once and reported `BLOCKED`, never left mid-op. `forgejo` stays `--ff-only`; `github` is never auto-pulled.
* **Mirror-drift** - the github HEAD sha compared against canonical, flagged `DRIFT github!=origin`. **Reported, never resolved** - no force, no push - matching `up-to-date.py` step 6, because resolving it automatically could silently drop commits on whichever side is behind.

On `action=apply` the module converges the topology above (adding any missing remote, repointing a stray URL, dropping a legacy dual-push pushurl, and pinning the default branch's pull/push to `origin`) before integrating divergence. The `git` role also converges `pull.rebase=true` globally so Kai's own `git pull` rebases the same way; the module passes `--rebase` explicitly and never depends on it. In **check mode** the module reports
only - but it still fetches, since ahead/behind and drift are meaningless
without current remote-tracking refs (fetch touches no working tree). Repos are
**data looped inside the module** (a bounded `parallel` thread pool, default 8),
not inventory hosts, so the sweep composes into the one `mac` play.

### Freshness gate (fails the run)

A repo flagged in `action_required` needs a human - the sweep surfaces it, never
touches it. The set is the hard, host-is-not-fresh signals: **uncommitted /
untracked** changes, **stashed** work, an **unmerged local branch** (work parked
off the default branch, repo-recall's land-or-delete signal), an **in-progress
op**, **detached HEAD**, **mirror-drift**, or a **blocked pull** (a `--ff-only`
or rebase that could not happen automatically, reported `BLOCKED`). The git role
prints these, and the play's `post_tasks` **freshness gate** (`ansible.builtin.fail`)
then fails the whole `sync` run on any of them - so `ward exec ansible-sync`
goes red, in check mode too, until the host is clean. The gate is deferred to
`post_tasks` (not raised inside the git role) so every role still converges and
all reports print before the run goes red; it is a no-op when `git` is tagged out
(the `repo_sweep` fact is undefined).

**`needs_push` (informational, never fails).** Commits on the default branch not
yet on `origin` are a clean `git push` away, not a freshness failure. They are
reported separately - `N repo(s) have unpushed commits on the default branch` -
and deliberately kept out of `action_required`. Being merely ahead of origin
informs Kai to push; it does not block a fresh host.

Because the git role runs after `repos`, a repo cloned in the same pass is swept
too.

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

## The agents-pointer role

Report-only convergence for the managed AGENTS.md workspace-pointer block (authored in `agentic-os#196`). It runs the agentic-os applier in `--dry-run` and surfaces any managed repo whose working tree lacks the current block. It never writes and never fails the run - informational like the git role's `needs_push`, because the block is committed to canonical once by `scripts/agents-pointer-migrate.py` (`coily agents-pointer-migrate`) and guarded from there on by the `agents-pointer` pre-commit hook. The migration is the rollout: per managed repo it files a same-repo Forgejo issue (the `closes-issue` hook needs one, with no bot bypass), renders the block, commits, and pushes to Forgejo, skipping any repo not clean-on-`main`. Dry-runs by default; `execute=1` to act. `tags=agents-pointer` scopes the role.

## Fleet-management rollout roles

These four roles enforce the **authoring-vs-rollout** rule (see `agentic-os/AGENTS.md`): a tool or validator is authored in its home repo, and the rollout that fans it across every checkout is an ansible role here. Install-time mass mutation never lives in `coily setup` or a brew post-install.

- **`fleet-orgs`** - resolves the fleet org list once and overrides `repos_known_orgs` with it, so every later role walks the same set. Order: env `COILYSIREN_FLEET_ORGS` fast-path, then SSM `/coilysiren/fleet/orgs` (`coily ops aws ssm get-parameter`, comma- or whitespace-separated; coily's argv policy rejects literal newlines so the value is comma-joined), else the static `repos_known_orgs` fallback from `group_vars/all.yml`. Carries the `always` tag so tag-scoped runs resolve it first. A pure fact-gather (`changed_when: false`, runs in check mode).
- **`lockdown`** - fleet-wide lockdown convergence, moved out of `coily setup`. Per org, `coily lockdown --recursive --apply --replace --path ~/projects/<org>`, then `coily lockdown --user --apply` once. In check mode it drops `--apply` to preview via coily's own dry-run.
- **`precommit-hooks`** - the ansible reimplementation of `agentic-os/scripts/apply-agentic-os-hooks.py`. Discovers every on-disk repo across the fleet orgs and, per repo (skipping the `agentic-os` source repo and any `.agentic-os-ignore` opt-out): strips legacy per-hook managed blocks (`ansible.builtin.replace`), upserts the single agentic-os managed block (`ansible.builtin.blockinfile`, markers carry the 2-space indent so the existing Python-written block is refreshed in place, never duplicated), drops legacy stamped `check-*.py` scripts, and runs `pre-commit install`. Hook IDs come from `precommit_hooks_default_ids` (lockstep with the script); `eco-*` repos skip `code-comments`. Bump `precommit_hooks_rev` on each agentic-os release. Full check-mode/`--diff` support.
- **`repo-data`** - the rollout/invocation layer for the repo-data collectors authored in `agentic-os-kai` (`make -C <kai-root> {build-catalog-graph,sync-repo-registry,compile-repo-digests}`), passing the resolved org list via `COILYSIREN_FLEET_ORGS`. Replaces the GitHub Actions daily crons. Skipped in check mode (the collectors have no dry-run).

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

Add the host under the `mac` group in `inventory/hosts.yml`. A personal Mac goes
straight under `mac` and picks up both the Homebrew baseline and the default
(public base + kai-private) agent-compose config. An employer-owned Mac goes
under the `work` child group instead, so it inherits the Homebrew baseline but
swaps kai-private for the work overlay. Linux / kai-server roles are future work
- the inventory and roles layout already accommodates more groups.

On a bare host, run `bootstrap.sh` (the one script that survived the setup.sh
retirement): it installs uv, clones the anchor repos (infrastructure, agentic-os,
agentic-os-kai), `uv sync`s, and hands off to the sync play, which converges
everything else. Prereqs: git auth to forgejo and AWS credentials. After that,
re-converge anytime with `ward exec ansible-sync`.

## See also

- [../ansible/README.md](../ansible/README.md) - quickstart.
- [FEATURES.md](FEATURES.md) - feature inventory.
- [../AGENTS.md](../AGENTS.md) - agent-facing operating rules.

Cross-reference convention from [coilysiren/agentic-os-kai#313](https://github.com/coilysiren/agentic-os-kai/issues/313).
