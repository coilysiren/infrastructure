# Features

Baseline inventory of what `coilysiren/infrastructure` does. Update when scope changes (added/removed/migrated features) so we can evaluate scope drift over time.

Last refreshed: 2026-05-08.

## Kubernetes and container orchestration

- **K3s single-node cluster** - Lightweight Kubernetes runtime on `kai-server` (Ubuntu 22.04, 18-core, 32 GiB). Traefik LoadBalancer routes host :80/:443. Files: `systemd/k3s.service`, `scripts/k3s-start.sh`, `src/k8s.py`. Tasks: `inv k8s.service-*`.
- **Tailscale operator integration** - Per-Service StatefulSet proxies, MagicDNS for tailnet peers, kubeconfig pinned to `100.69.164.66:6443`. OAuth via `tag:ci`. Reference: `docs/k3s-deploy-notes.md` §1.
- **cert-manager with DNS-01 (Route 53)** - ClusterIssuers (prod + staging) prove ownership via TXT records in zone `Z06714552N3MO04UBWF33`. Replaces retired HTTP-01 hairpin-NAT path. Files: `deploy/cert_manager.yml`, `docs/certificates.md`. Task: `inv k8s.cert-manager`.
- **Namespace layout** - `kube-system`, `cert-manager`, `external-secrets`, `tailscale`, `observability`, `llama`, `coilysiren-backend`, plus sibling-repo namespaces (`eco-mcp-app`, `eco-jobs-tracker`, `galaxy-gen`). Reference: `docs/architecture.md`.

## Secrets and credential management

- **SSM-backed external-secrets** - external-secrets operator syncs AWS SSM Parameter Store to k8s Secrets on a 1h refresh. Canonical paths: `/github/pat`, `/tailscale/oauth-client-id`, `/tailscale/oath-secret` (typo preserved), `/grafana/admin-password`, `/eco/server-api-token`. Files: `deploy/secretstore.yml`, `deploy/externalsecret.yml`, `src/k8s.py`. Inventory: `docs/k3s-deploy-notes.md` §2.
- **Route 53 IAM scoping for cert-manager** - IAM user `kai-server-k3s` in group `route53-coilysiren-me`, scoped to the hosted zone for DNS-01. Rotation steps in `docs/certificates.md`.
- **GitHub repo secret sync** - Six canonical secrets (`K8S_SERVER`, `K8S_CA_DATA`, `K8S_CLIENT_CERT_DATA`, `K8S_CLIENT_KEY_DATA`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`) populated into every deployable repo via piped `yq`. Never written to disk. Reference: `docs/k3s-deploy-notes.md` §3.

## Game servers

- **Eco game server** - Steam-installed at `/home/kai/Steam/steamapps/common/EcoServer/`, run by `eco-server.service` with API token from SSM. Pre-script runs `steamcmd` updates. HTTP API on :3001 reachable via `hostAliases` workaround. Files: `systemd/eco-server.service`, `scripts/eco-server-pre.sh`, `src/eco.py`, `eco.md`.
- **Eco mod deployment** - Three-step push (zip, scp, unzip) for UserCode mods (eco-mods, eco-mods-public) and ModKit DLLs (eco-jobs-tracker). Canonical entry: `coily eco mod push --src <zip>`. Sequencing: push mod, restart server, verify, then deploy web app. Files: `src/eco.py`, `eco.md` §4.
- **Eco config-as-code** - Configs sync from `coilysiren/eco-configs` (git clone with `.git` backup). Skill-gain multiplier adjustable via `inv eco.increase-skill-gain`. World reset via `Difficulty.eco` plus Storage deletion. Reference: `eco.md` §3-8.
- **Core Keeper, Icarus, Factorio servers** - Parallel systemd units with tail/restart/start/stop tasks. Factorio adds a backup timer plus script. Files: `systemd/`, `src/core_keeper.py`, `src/icarus.py`, `scripts/factorio-backup.sh`.

## Observability

- **VictoriaMetrics + Grafana stack** - vmsingle (10 GiB PVC, tailnet-only :8428), vmagent (30s scrape), prometheus-node-exporter (most collectors disabled), Grafana (2 GiB PVC, public HTTPS at `grafana.coilysiren.me`). Files: `deploy/observability/`, `src/k8s.py`. Task: `inv k8s.observability`.
- **Grafana dashboards via Terraform** - All dashboards (except auto-imported "Node Exporter Full") managed by the `grafana` provider. Admin password from SSM. S3 native locking (no DynamoDB). Files: `terraform/grafana/main.tf`, `terraform/grafana/dashboards.tf`. Task: `inv k8s.terraform-grafana`.
- **Thermal heartbeat (30s)** - Reads lm-sensors, nvme-cli, kernel thermal zones. Writes Prometheus textfile, pings Sentry cron, fires breach events (CPU 90C, NVMe 70C, zones 95C, throttled 1h). Files: `scripts/thermal-heartbeat.py`, `systemd/thermal-heartbeat.{service,timer}`.
- **Process memory heartbeat (5m)** - Sentry cron check-in for process memory. Files: `scripts/process-memory-heartbeat.py`, `systemd/process-memory-heartbeat.{service,timer}`.

## Application deploy and CI/CD

- **Invoke task runner** - `tasks.py` aggregates `k8s`, `eco`, `icarus`, `core_keeper`, `core`, `llama` collections. Primary mobile-friendly entry surface for the homelab.
- **GitHub Actions config-validation CI** - `.github/workflows/config.yml` runs pylint on Python 3.11. Per-repo CI workflows (in sibling repos) build to GHCR and `kubectl apply` against the tailnet IP. Canonical shape: test, build-publish, deploy. Reference: `docs/k3s-deploy-notes.md` §4.
- **llama.cpp inference service** - k8s Deployment in `llama` namespace, initContainer pulls TinyLLama-1.1B from HuggingFace, serves on :8080. Requests 10 cores / 5 GiB. Files: `llama/deploy.yml`, `src/llama.py`.

## Network and access

- **DNS and routing** - `coilysiren.me` Route 53 hosted zone. Service A records (`api`, `eco-mcp`, `eco-jobs-tracker`, `eco`, `galaxy-gen`) point to public `99.110.50.213`, NAT'd to `192.168.0.194`. Tailnet kubeconfig uses `100.69.164.66`.
- **Caddy reverse proxy (legacy)** - `caddy/Caddyfile` routes `api.coilysiren.me` to `localhost:4000`. Marked pre-traefik. Traefik Ingress is the canonical path now.

## Tooling and policy

- **coily CLI integration** - `.coily/coily.yaml` permits `k3s-list-dns` diagnostic. Long-running AWS / kubectl ops migrating to `coily` wrappers.
- **Sudoers for game-server ops** - `sudoers/kai-game-servers`. Not auto-deployed.
- **Pre-commit hooks** - Lint and secret scanning via `.pre-commit-config.yaml`.
- **Single source of truth** - `docs/k3s-deploy-notes.md` is authoritative for homelab topology, SSM inventory, GitHub secrets, deploy shapes, triage. Mandatory read before touching k3s, Tailscale, or cert-manager.
- **Post-push verification** - After pushing to main, verify CI via `coily gh run list --repo coilysiren/infrastructure --limit 1`. Skip for docs-only pushes. Reference: `AGENTS.md`.

## Out of scope (intentional non-features)

- Multi-node k3s, HA control plane.
- Public ingress for VictoriaMetrics (tailnet-only by design).
- Automatic sudoers rollout.
- HTTP-01 ACME (replaced by DNS-01).
- DynamoDB-backed Terraform locking (replaced by S3 native locking).
