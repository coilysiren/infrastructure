DEFAULT_GOAL := help

.PHONY: help \
	k3s-list-dns \
	setup-git-lfs \
	cert-manager \
	aws-secrets \
	observability \
	observability-admin-password \
	signoz \
	terraform-grafana \
	terraform-admin-kms \
	terraform-tailscale \
	terraform-tailscale-merge \
	dump-tailscale-acl \
	list-tailscale-devices \
	sync-tailscale-oidc-secrets \
	llama-deploy \
	llama-deploy-secrets \
	lunch-money \
	terraform-aws-inventory \
	host-watch \
	ansible-sync \
	ansible-mac-seed \
	agents-pointer-migrate

help: ## Print this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "%-32s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

k3s-list-dns: ## Spin up a diagnostic ubuntu pod and dump every Service DNS record.
	bash scripts/k3s-list-dns.sh

setup-git-lfs: ## Wire Git LFS for the current user and re-smudge degraded LFS checkouts.
	bash scripts/setup-git-lfs.sh

cert-manager: ## Install or refresh cert-manager + ClusterIssuers (deploy/cert_manager.yml).
	@uv run python scripts/k8s/cert_manager.py

aws-secrets: ## Bootstrap external-secrets + aws-credentials. Args - aws_access_key_id=ID aws_secret_access_key=SECRET.
	@test -n "$(aws_access_key_id)" || { echo "aws_access_key_id=<ID> is required" >&2; exit 2; }
	@test -n "$(aws_secret_access_key)" || { echo "aws_secret_access_key=<SECRET> is required" >&2; exit 2; }
	@uv run python scripts/k8s/aws_secrets.py $(aws_access_key_id) $(aws_secret_access_key)

observability: ## Install or upgrade the VictoriaMetrics + Grafana stack.
	@uv run python scripts/k8s/observability.py

observability-admin-password: ## Print the auto-generated Grafana admin password.
	@uv run python scripts/k8s/observability_admin_password.py

signoz: ## Install or upgrade the SigNoz traces stack (private, tailnet-only).
	@uv run python scripts/k8s/signoz.py

terraform-grafana: ## Run terraform against terraform/grafana/ (GRAFANA_AUTH wired from SSM). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_grafana.py $(or $(action),plan)

terraform-admin-kms: ## Run terraform against terraform/admin-kms/ (admin-only KMS key for SSM-wrapping). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_admin_kms.py $(or $(action),plan)

terraform-tailscale-merge: ## One-shot merge of tailscale-{policy,oidc,devices} into terraform/tailscale/. Args - action=prepare|push|orphan.
	@uv run python scripts/k8s/terraform_tailscale_merge.py $(or $(action),prepare)

terraform-tailscale: ## Run terraform against terraform/tailscale/ (merged tailnet stack). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_tailscale.py $(or $(action),plan)

dump-tailscale-acl: ## Dump current tailnet policy via admin OAuth (round-trip target for terraform/tailscale/).
	@uv run python scripts/k8s/dump_tailscale_acl.py

list-tailscale-devices: ## List every tailnet device with hostname, user, tags, addresses.
	@uv run python scripts/k8s/list_tailscale_devices.py

sync-tailscale-oidc-secrets: ## Push TS_CLIENT_ID + TS_AUDIENCE to each repo in terraform/tailscale/repos.yaml via gh CLI live auth.
	@uv run python scripts/k8s/sync_tailscale_oidc_secrets.py

llama-deploy: ## Apply llama/deploy.yml into the llama namespace.
	@uv run python scripts/llama/deploy.py

llama-deploy-secrets: ## Bootstrap the llama ghcr.io docker-registry secret from SSM /github/pat.
	@uv run python scripts/llama/deploy_secrets_docker_repo.py

lunch-money: ## Deploy or upgrade the lunch-money-k8s MCP server (deploy/lunch-money/).
	@uv run python scripts/k8s/lunch_money.py

terraform-aws-inventory: ## Run terraform against terraform/aws-inventory/ (managed S3 + Route53, SSM data-source). Args - action=plan|apply|init|destroy|output|import.
	@uv run python scripts/k8s/terraform_aws_inventory.py $(or $(action),plan)

caddy-shortcuts: ## Regenerate caddy/sites/*.caddy from sibling repos' coily.yaml on Forgejo. Args - dry_run=1 to preview without writing.
	@FORGEJO_TOKEN=$$(aws ssm get-parameter --name /forgejo/api-token --with-decryption --query Parameter.Value --output text) \
	  uv run python scripts/generate-caddy-shortcuts.py $(if $(dry_run),--dry-run)

host-watch: ## Watch a tailnet host's SSH and capture a host-diag.sh snapshot on each dead->alive recovery. Args - host=<alias>.
	@test -n "$(host)" || { echo "host=<alias> is required" >&2; exit 2; }
	bash scripts/host-watch.sh $(host)

claude-remote-control-install: ## (Re)install the kai-server remote-control daemon, node-tooling-ensure units, and self-heal settings. Idempotent; recovers a latched daemon. Run on kai-server.
	bash scripts/claude-remote-control-install.sh

ansible-sync: ## Freshen this host (homebrew + agent-compose + repos + git sweep) via ansible/playbooks/sync.yml. Args - action=check|apply (default check), tags=<csv> to scope.
	@uv run python scripts/ansible/sync.py $(or $(action),check) $(if $(tags),tags=$(tags),)

ansible-mac-seed: ## Seed ansible/group_vars/mac.yml from this machine's live brew leaves/casks/taps.
	@uv run python scripts/ansible/seed_mac_brew.py

agents-pointer-migrate: ## One-time: render the managed AGENTS.md pointer block into every managed repo's canonical Forgejo main. Dry run by default; args - execute=1 to act, repo=<name> for one, limit=<n>.
	@uv run python scripts/agents-pointer-migrate.py $(if $(execute),--execute,) $(if $(repo),--repo $(repo),) $(if $(limit),--limit $(limit),)
