DEFAULT_GOAL := help

.PHONY: help \
	k3s-list-dns \
	cert-manager \
	aws-secrets \
	observability \
	observability-admin-password \
	terraform-grafana \
	llama-deploy \
	llama-deploy-secrets

help: ## Print this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "%-32s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

k3s-list-dns: ## Spin up a diagnostic ubuntu pod and dump every Service DNS record.
	bash scripts/k3s-list-dns.sh

cert-manager: ## Install or refresh cert-manager + ClusterIssuers (deploy/cert_manager.yml).
	@uv run python scripts/k8s.py cert-manager

aws-secrets: ## Bootstrap external-secrets + aws-credentials. Args - aws_access_key_id=ID aws_secret_access_key=SECRET.
	@test -n "$(aws_access_key_id)" || { echo "aws_access_key_id=<ID> is required" >&2; exit 2; }
	@test -n "$(aws_secret_access_key)" || { echo "aws_secret_access_key=<SECRET> is required" >&2; exit 2; }
	@uv run python scripts/k8s.py aws-secrets --aws-access-key-id=$(aws_access_key_id) --aws-secret-access-key=$(aws_secret_access_key)

observability: ## Install or upgrade the VictoriaMetrics + Grafana stack.
	@uv run python scripts/k8s.py observability

observability-admin-password: ## Print the auto-generated Grafana admin password.
	@uv run python scripts/k8s.py observability-admin-password

terraform-grafana: ## Run terraform against terraform/grafana/ (GRAFANA_AUTH wired from SSM). Args - action=plan|apply|init|destroy.
	@uv run python scripts/k8s.py terraform-grafana --action=$(or $(action),plan)

llama-deploy: ## Apply llama/deploy.yml into the llama namespace.
	@uv run python scripts/llama.py deploy

llama-deploy-secrets: ## Bootstrap the llama ghcr.io docker-registry secret from SSM /github/pat.
	@uv run python scripts/llama.py deploy-secrets-docker-repo
