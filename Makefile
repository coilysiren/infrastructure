DEFAULT_GOAL := help

.PHONY: help \
	k3s-list-dns \
	cert-manager \
	aws-secrets \
	observability \
	observability-admin-password \
	terraform-grafana \
	terraform-admin-kms \
	terraform-tailscale-oidc \
	terraform-tailscale-devices \
	sync-tailscale-oidc-secrets \
	llama-deploy \
	llama-deploy-secrets

help: ## Print this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "%-32s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

k3s-list-dns: ## Spin up a diagnostic ubuntu pod and dump every Service DNS record.
	bash scripts/k3s-list-dns.sh

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

terraform-grafana: ## Run terraform against terraform/grafana/ (GRAFANA_AUTH wired from SSM). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_grafana.py $(or $(action),plan)

terraform-admin-kms: ## Run terraform against terraform/admin-kms/ (admin-only KMS key for SSM-wrapping). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_admin_kms.py $(or $(action),plan)

terraform-tailscale-oidc: ## Run terraform against terraform/tailscale-oidc/ (TS admin OAuth wired from SSM). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_tailscale_oidc.py $(or $(action),plan)

terraform-tailscale-devices: ## Run terraform against terraform/tailscale-devices/ (one tailscale_tailnet_key per k8s sidecar service; replaces tailscale-operator). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s/terraform_tailscale_devices.py $(or $(action),plan)

sync-tailscale-oidc-secrets: ## Push TS_CLIENT_ID + TS_AUDIENCE to each repo in tailscale-oidc/repos.yaml via gh CLI live auth.
	@uv run python scripts/k8s/sync_tailscale_oidc_secrets.py

llama-deploy: ## Apply llama/deploy.yml into the llama namespace.
	@uv run python scripts/llama/deploy.py

llama-deploy-secrets: ## Bootstrap the llama ghcr.io docker-registry secret from SSM /github/pat.
	@uv run python scripts/llama/deploy_secrets_docker_repo.py
