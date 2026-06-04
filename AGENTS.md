# Agent instructions

See `../AGENTS.md` for workspace-level conventions (writing voice, readonly ops, SSM discipline). This file covers what is specific to this repo.

## Scope

Everything needed to stand up and operate **kai-server**: systemd units, shell scripts, k3s cluster manifests, and coily verbs for cluster-side bootstrap. This repo is the **source of truth for homelab deploy knowledge** across coilysiren/*.

## Project shape

`deploy/` holds cluster-wide manifests (cert-manager, external-secrets, SecretStore to AWS SSM). `terraform/` holds per-stack IaC. `ansible/` converges workstation/host state (today: macOS Homebrew via the `mac` inventory group, driven by `coily ansible-mac`). `scripts/` + `systemd/` carry unit ExecStart helpers and Python for coily verbs. `docs/` holds durable ops runbooks. `caddy/` is legacy pre-Traefik config.

## Repo boundaries

Infra config and deploy knowledge only. Application code lives in sibling repos (eco-jobs-tracker, backend, luca); their deploy manifests live with them. Don't scatter homelab fixes into sibling AGENTS.md files - they belong in `docs/k3s-deploy-notes.md`.

## Commands

Route every dev command through coily, which reads [`.coily/coily.yaml`](.coily/coily.yaml). The lockdown denies bare `kubectl` / `make` / `uv` / `python`. Add new verbs to that file before invoking them.

## Validation

CI is config-validation only (Forgejo Actions via in-cluster runners, `deploy/forgejo-runner.yml`); it doesn't deploy. `.github/workflows/` is intentionally empty. Run `pre-commit run --all-files` before committing; never `--no-verify`. A validation regression usually means a downstream sibling deploy breaks on its next ship.

## Safety

Confirm before kubectl writes and any cloud write that can clobber state (SSM `put-parameter --overwrite`, `delete-parameter`, S3 writes, IAM mutations). `coily ops aws ssm put-parameter` without `--overwrite` is pre-authorized - it fails with `ParameterAlreadyExists` rather than clobbering. Never print decrypted SSM values; pipe them straight into `gh secret set` or equivalent. Prefer `coily` over raw `aws` / `kubectl`.

## Cross-repo contracts

**Before touching any k3s / Tailscale / cert-manager thing, read [`docs/k3s-deploy-notes.md`](docs/k3s-deploy-notes.md).** It covers kai-server topology, the SSM parameter inventory, the six GitHub repo secrets every deployable repo needs, the canonical GHA workflow / k8s manifest / Makefile shapes, every trap hit across four repos with one-line fixes, a new-repo setup checklist, and a deploy-failure triage tree. When you resolve a new pitfall, add it to §7 and §9 there.

## Release

A commit to `main` is not a deploy. `origin` is `forgejo.coilysiren.me/coilyco-flight-deck/infrastructure` and fans out push to both Forgejo and GitHub. Changes reach kai-server only when a coily verb applies the manifest or a systemd unit restarts. After pushing to `main`, schedule a wake-up ~300s later to verify CI passed via the Forgejo Actions API (`/forgejo/api-token` SSM secret); re-check once at +180s if still running. On failure, surface the run URL and stop - infra CI failures are usually real. Skip for docs-only pushes.

## Agent rules

Commit directly to `main`, push after each commit, no per-push confirm (subject to the Safety exceptions above). Close issues with a `closes #<N>` trailer. Voice rules apply (no em-dashes, no semicolons in prose, she/her).

## See also

- [README.md](README.md) - human-facing intro.
- [docs/FEATURES.md](docs/FEATURES.md) - inventory of what ships today.
- [.coily/coily.yaml](.coily/coily.yaml) - allowlisted commands. Agents route through coily, not bare `make` / `uv` / `python`.

Cross-reference convention from [coilysiren/agentic-os-kai#313](https://github.com/coilysiren/agentic-os-kai/issues/313).
