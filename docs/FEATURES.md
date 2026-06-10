# Features

Baseline of `coilysiren/infrastructure`. Update when scope changes.

## Kubernetes and container orchestration

- **K3s single-node** on `kai-server`. Traefik LoadBalancer routes :80/:443. Service ops via `coily ssh systemctl <verb> k3s.service`.
- **Tailscale operator** - Per-Service StatefulSet proxies, MagicDNS, kubeconfig on the `kai-server` MagicDNS name. OAuth via `tag:ci`.
- **cert-manager with DNS-01 (Route 53)** - ClusterIssuers (prod + staging) prove ownership via TXT records in the `coilysiren.me` hosted zone (id in SSM). Verb: `coily cert-manager`.
- **Namespaces** - kube-system, cert-manager, external-secrets, tailscale, observability, llama, coilysiren-backend, plus per-app namespaces (eco-mcp-app, eco-jobs-tracker, galaxy-gen).

## Secrets and credential management

- **SSM-backed external-secrets** - 1h sync from AWS SSM. Inventory in `docs/k3s-deploy-notes.md` §2. Bootstrap: `coily aws-secrets`.
- **Route 53 IAM scoping for cert-manager** - IAM user scoped to the hosted zone for DNS-01.
- **GitHub repo secret sync** - Six canonical k8s + Tailscale secrets piped into every deployable repo. Never written to disk.

## Game servers

- **Eco** - `eco-server.service` with API token from SSM. Mods pushed via `coily gaming eco mod push`. Service ops `coily gaming eco {status,tail,start,stop,restart}`.
- **Eco config-as-code** - Configs sync from `coilysiren/eco-configs`. World + config rewrites live in `eco-cycle-prep`.
- **Core Keeper, Icarus, Factorio** - Parallel systemd units. `coily gaming <name> ...`. Factorio adds a backup timer.
- **Factorio Discord chat bridge** - `fdr-remake` sidecar pinned to `factorio-server.service`. Reads `--console-log`, writes via localhost RCON. SSM keys at `/factorio/fdr/*`. Bringup: `bash scripts/install-fdr-remake.sh`. Reference: `coilyco-flight-deck/infrastructure#101`, `#139`.

## Observability

- **VictoriaMetrics + Grafana** - vmsingle 10 GiB PVC (tailnet-only :8428), vmagent 30s scrape, Grafana 2 GiB PVC at `grafana.coilysiren.me`. Verb: `coily observability`.
- **Grafana dashboards via Terraform** - All dashboards (except auto-imported "Node Exporter Full") managed by the `grafana` provider. S3 native locking. Verb: `coily terraform-grafana`.
- **Thermal heartbeat (30s)** - lm-sensors + nvme-cli + thermal zones. Writes textfile, pings Sentry cron, fires breach events.
- **Process memory heartbeat (5m)** - Sentry cron check-in.

## Application deploy and CI/CD

- **Coily verb surface** - Cluster-bootstrap verbs (cert-manager, aws-secrets, observability, terraform-grafana, llama-deploy, k3s-list-dns). Python helpers in `scripts/k8s.py` and `scripts/llama.py`.
- **GitHub Actions CI** - Config validation here. Per-repo CI in sibling repos builds to GHCR and `kubectl apply` against the tailnet. Canonical shape: test, build-publish, deploy.
- **Forgejo build runner** - In-cluster `act_runner` StatefulSet (`deploy/forgejo-runner.yml`), DinD sidecar, instance-level registration. Runs every repo's Forgejo Actions job.
- **Forgejo tap-writer runner** - Lightweight DinD-free `act_runner` (`deploy/forgejo-runner-tap-writer.yml`) for cross-repo formula bumps into the coilyco-flight-deck homebrew tap(s). Host executor, label `tap-writer`, opt-in via `runs-on: tap-writer`. Carries a repo-write token from SSM `/forgejo/tap-bump-token` through a git credential helper, so the token never enters a job env or a Forgejo Actions secret. Provision the token with `scripts/provision-tap-bump-token.sh`.
- **llama.cpp inference** - k8s Deployment in `llama` namespace, initContainer pulls TinyLLama-1.1B, serves :8080. Verbs: `coily llama-deploy`, `coily llama-deploy-secrets`.
- **Forgejo<->GitHub mirroring** - Forgejo (`forgejo.coilysiren.me`) is the canonical git upstream and GitHub a downstream mirror. `scripts/coilysiren-github-mirror.sh` (systemd timer daily 04:15) clones every Forgejo repo updated in the last 48h and `push --mirror`s it to GitHub. `scripts/coilysiren-forgejo-mirror.sh` (03:45) keeps the legacy reverse direction, and both can run. Forgejo token from SSM `/forgejo/api-token`. Local checkouts push to Forgejo only (`origin` = canonical forgejo); GitHub is refreshed by the mirror timer above, not a local dual-push. Remote topology (origin/forgejo/github) is owned by the ansible `git` role; `clone-coilysiren-repos.sh` only clones and fetches. Install with `bash scripts/install-coilysiren-github-mirror.sh`. See `coilyco-flight-deck/infrastructure#122`.

## Workstation and host convergence (Ansible)

- **First-class Ansible subsystem** - `ansible/` converges workstation/host state, shipped as a uv-managed dependency (`community.general` bundled) and driven by coily verbs in the repo's k8s/terraform pattern. Full walkthrough in `docs/ansible.md`.
- **Host sync** - `ward exec ansible-sync` brings a host up to date across the coilysiren surface via `playbooks/sync.yml` (shell config + Homebrew + agent-compose + claude-hooks + kai-config + repo clone + layout reconcile + skills + git remote-sync sweep + cross-org dep-tree check). A `group_by` play classifies the control host into the `mac` or `linux` group by OS, so one inventory is correct on any machine. Dry-runs by default (`--check --diff`); `action=apply` converges; `tags=<csv>` scopes to one role. The Ansible port of `agentic-os-kai/scripts/up-to-date.py`.
- **Host config = ansible (setup.sh retired)** - The old `agentic-os/setup.sh` + `agentic-os-kai/setup.sh` installers are gone; their work is now ansible roles - `shell` (zsh/bash symlinks + gpg-ssm + PATH helpers + hammerspoon), `claude-hooks` (agent self-name + session-pulse), `kai-config` (mcporter + Claude-settings merges + forgejo credential helper), `skills` (skill mount + repo-pointer aggregation + capability pull). A single `bootstrap.sh` seeds a bare host (install uv + clone the anchor repos) then hands off to the sync play; everything past it is ansible-converged.
- **macOS Homebrew convergence** - The `homebrew` role ensures declared taps, formulae, and casks are present, and uninstalls anything on the `homebrew_{installed_packages,cask_apps}_absent` lists (`state: absent`) so a tool can be retired fleet-wide rather than lingering. Things merely omitted are left alone. `coily ansible-mac-seed` captures the live machine's `brew leaves`/casks/taps into the baseline.
- **macOS default file-type handlers** - The `default-apps` role points editor-shaped file types (txt/md/json/yaml/py/sh/sql/... and ~35 more) at Warp Preview via `duti`, idempotently (queries `duti -x`, sets only on drift). Dynamic-UTI dev files (go/rs/toml/tsx/tf/...) can't take a `duti` handler, so they're handled structurally - only `warp@preview` is installed (Stable dropped), making Preview their sole claimant. Driven by `default_app_editor_{bundle_id,extensions}` in `group_vars/mac.yml`; html/xhtml deliberately stay in the browser. `tags=default-apps` scopes the run.
- **Local LLM (ollama)** - The `homebrew` role installs the `ollama` formula; the `ollama` role then converges what `brew install` leaves undone - starts the `brew services` launchd unit, waits on `127.0.0.1:11434`, and pulls every tag in `ollama_models` (`group_vars/mac.yml`), skipping any already present. **MLX tags only**: the Homebrew bottle ships solely the `mlx_metal_v3` runner (no `llama-server`), so GGUF tags fail to start - MLX is also faster on Apple Silicon. Current model `qwen3.5:9b-mlx` (4-bit, ~8.9GB, fits 18GB unified memory). The converge block is `not ansible_check_mode`-guarded - it depends on a binary only `apply` really installs, so there is nothing safe to dry-run. It also pins server env (`ollama_service_env`) into the launchd plist's `EnvironmentVariables` via `PlistBuddy` - additive, so the existing `OLLAMA_FLASH_ATTENTION`/`OLLAMA_KV_CACHE_TYPE` perf vars are untouched - and `launchctl bootout`/`bootstrap`-reloads the service only when a value drifts. `OLLAMA_KEEP_ALIVE` (default `30m`, `ollama_keep_alive`) keeps a loaded model resident for 30 min after each request instead of the 5-min default. `OLLAMA_DEBUG` (toggle `ollama_debug`, on for the mac group) raises the server log to DEBUG so `/opt/homebrew/var/log/ollama.log` records per-request `prompt_eval`/`eval_count` and prompt-cache hit/miss (`cache.go matched=N`) - the symmetric off-path deletes the key. The log is unrotated, so debug is a deliberate opt-in, not a permanent default. The role also renders `~/.config/opencode/opencode.json` (when `ollama_models` is non-empty), wiring the OpenCode terminal harness to the local `127.0.0.1:11434/v1` OpenAI-compatible endpoint via `@ai-sdk/openai-compatible`; the default model single-sources from `ollama_models` (the `ollama_opencode_model` default), so there is no second place to bump the model name. `opencode` itself installs as a Homebrew formula from the `anomalyco/tap` tap. `tags=ollama` scopes the run.
- **Repo discovery + clone** - The `repos` role discovers owned repos recently active on GitHub/Forgejo but absent locally (read-only `repo_registry` module, Forgejo PAT from SSM pinned to the canonical host) and clones the missing ones. Repos are data looped over the host; the inventory stays machines.
- **Layout reconcile** - The `reconcile` role (`repo_reconcile` module) makes the local `~/projects/<org>/` tree match the remotes: moves each drifted checkout to its origin org, or removes it when a clean, fully-pushed canonical copy already exists. Runs before the git sweep. Any local state (dirty/stash/op/worktree/unpushed) or the `agentic-os-kai` harness anchor FAIL-flags the checkout and leaves it untouched; check mode reports the plan.
- **Cross-org dep-tree check** - The `deptree` role (`repo_deptree` module) walks the `dependsOn` edges of `catalog-graph.json`, maps each end to its bucket from `repo-split-decisions.yaml`, and fails the play on any flight-deck -> bridge edge. Read-only; absent data degrades to a skip.
- **Git remote-sync + mirror-drift** - The `git` role sweeps every local clone (`repo_status` module): `git fetch --all --prune`, reports ahead/behind, uncommitted, in-progress op, detached HEAD, worktrees, stash, and stale branches, and flags github<->forgejo HEAD-sha drift. On apply it wires three normal remotes (`origin`/`forgejo` = canonical forgejo, `github` = the mirror), pins the default branch's pull+push to `origin` so a bare `git push` stays on forgejo (github takes a deliberate `git push github`), rebases the default branch from `origin` (explicit `--rebase`, abort-on-conflict so no repo is left mid-rebase), and pulls `--ff-only` from `forgejo`; mirror drift is reported, never resolved (no force, no push). It also converges `pull.rebase=true` globally so interactive pulls rebase too. A play-end **freshness gate** (`sync.yml` post_tasks) then **fails the whole run** on any repo needing manual action - uncommitted/stash/unmerged-local-branch/in-progress-op/detached-HEAD/mirror-drift/blocked-pull (a non-ff or rebase-conflict pull) - in check mode too, deferred so every role converges and all reports print first; repos merely ahead of `origin` are reported separately as informational **`needs_push`** ("push when ready") and never fail. `tags=git` scopes the run.
- **agent-compose convergence** - The `agent-compose` role renders `~/.config/agent-compose/agent-compose.yaml` from a per-host source list and composes `COMPOSED.md`, symlinking each harness global load point (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) at it. The `mac` group default is public base + kai-private overlay; the `work` child group is for employer-owned macs (public base + a work overlay, no kai-private), with the work path resolved from SSM at converge so the employer name stays out of tracked vars. Idempotent, opt-in, backs up real files to `<name>.bak`.
- **Codex project boundary** - The `codex-permissions` role allows the `coilyco-flight-deck` and `coilysiren` project trees while denying `coilyco-bridge` and Claude-only context/config paths.
- **AGENTS.md pointer rollout** - `scripts/agents-pointer-migrate.py` (`coily agents-pointer-migrate`) is the one-time rollout that lands the managed AGENTS.md workspace-pointer block (authored in agentic-os#196) on each managed repo's canonical Forgejo `main`: per repo it files a same-repo Forgejo issue (the `closes-issue` hook needs one and has no bot bypass), renders the block, commits, and pushes to Forgejo, skipping any repo not clean-on-`main`. Dry-runs by default (`execute=1` to act). After it runs once, the `agents-pointer` pre-commit hook guards drift forever, so the matching `agents-pointer` ansible role is report-only - it runs the applier in `--dry-run` and surfaces any managed repo whose tree lacks the current block (migration not yet run, or a hand-edit drifted it), informational like `needs_push`, never writing or failing the run. `tags=agents-pointer` scopes it.
- **Claude harness hooks** - The `claude-hooks` role wires Claude Code config into `~/.claude/settings.json`: the advisory o2r cross-node nudge (a PreToolUse Bash detector reminding agents to route agent-to-agent delivery over o2r / otel-a2a-relay when a command ssh/scp/rsyncs to another fleet node) via the idempotent `claude_settings_hook` module, plus the agent self-name (statusLine + SessionStart hook) and session-pulse SessionStart hook by running the idempotent agentic-os `install-*.py` mergers. All non-blocking and key-preserving. `tags=claude-hooks` scopes the run.
- **macOS keep-awake hold** - `scripts/keepawake-install-macos.sh` installs a root LaunchDaemon (`me.coilysiren.keepawake`) that holds `pmset disablesleep` on so remote dispatch survives Kai walking away (power-source-agnostic, covers battery and lid-closed), released nightly 03:00-03:59 for the update/reboot window and on battery below 30%. Standalone one-time `sudo` install, not a sync role - sync is deliberately password-free and TTY-less, like the `sudoers/` and `systemd/` artifacts.

## Cross-machine session aggregation

- **Claude session watcher** - Per-machine `watchdog`-driven process that ships `~/.claude/projects` session files to a tailnet-only sink so every machine's Claude sessions are queryable from one place. Runs on the 4 non-kai-server environments (Mac desktop/laptop, Windows native, WSL) via launchd / Scheduled Task / systemd. Component 1 of the pipeline in `coilyco-flight-deck/infrastructure#224`. See `docs/claude-session-watcher.md`.

## Network and access

- **DNS and routing** - `coilysiren.me` Route 53 zone. Service A records point to the WAN, NAT'd to the LAN side of the homelab. Tailnet kubeconfig uses the `kai-server` MagicDNS name. Concrete addresses live in the vault.
- **fail2ban sshd jail** - Brute-force throttling on the public sshd listener (`0.0.0.0:22`). `fail2ban/jail.local` enables the `sshd` jail with the systemd-journal backend, 1h ban after 5 failures in 10m, `ignoreip` over loopback + RFC1918 so LAN/tailscale keys never self-lock. Idempotent bringup: `bash scripts/fail2ban-install.sh`. No sshd binding or exposure change. See `docs/fail2ban.md`, `coilyco-flight-deck/infrastructure#104`.
- **Host Caddy on kai-server** - Tailnet-only front door. `caddy/sites/*.caddy` shortcuts to cluster Ingresses, `:8082` for the coily audit dashboard. `/etc/caddy/Caddyfile` auto-deploys from the repo via `systemd/caddy-config-deploy.{path,service}`. ACME pinned to LE prod.

## Tooling and policy

- **Sudoers for game-server ops** - `sudoers/kai-game-servers`. Not auto-deployed.
- **Pre-commit hooks** - Lint + secret scan.
- **Single source of truth** - `docs/k3s-deploy-notes.md` is authoritative for homelab topology, SSM inventory, GitHub secrets, deploy shapes, triage.
- **Tailscale OIDC for CI** - `terraform/tailscale/` mints a per-repo federated identity. Replaces the long-lived shared OAuth pair. See `docs/tailscale.md`.

## Out of scope

- Multi-node k3s, HA control plane.
- Public ingress for VictoriaMetrics.
- Automatic sudoers rollout.
- HTTP-01 ACME (replaced by DNS-01).

## See also

- [README.md](../README.md) - human-facing intro.
- [AGENTS.md](../AGENTS.md) - agent-facing operating rules.
- [.coily/coily.yaml](../.coily/coily.yaml) - allowlisted commands.
- [.ward/ward.yaml](../.ward/ward.yaml) - ward-allowlisted commands for this repo.

Cross-reference convention from [coilysiren/agentic-os-kai#313](https://github.com/coilysiren/agentic-os-kai/issues/313).
