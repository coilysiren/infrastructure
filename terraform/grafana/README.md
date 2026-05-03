# terraform/grafana

Manages Grafana dashboards on `https://grafana.coilysiren.me` via the
[grafana/grafana](https://registry.terraform.io/providers/grafana/grafana)
provider.

## Why this exists

The grafana helm chart's `dashboards:` block in
`deploy/observability/grafana-values.yml` worked, but it forced JSON to live
as YAML strings, which made any non-trivial dashboard painful to edit. This
TF root pulls each managed dashboard out into a real `.json` file and
provisions it via the Grafana API.

`node-exporter-full` (gnetId 1860) stays in helm-values land. It's pulled
from grafana.com at chart install time, so there's nothing for us to edit.

## Layout

- `main.tf` - terraform + provider config, S3 backend.
- `dashboards.tf` - one `grafana_dashboard` resource per file.
- `dashboards/*.yaml` - dashboard definitions. YAML for editor-readability; the resource pipes them through `yamldecode` + `jsonencode` for the grafana API.

## State

Backend: `s3://coilysiren-assets/terraform-state/infrastructure/grafana.tfstate`,
us-east-1, native S3 locking (`use_lockfile = true`, no DynamoDB).

State is intentionally small and rebuildable from the JSON files in
`dashboards/`. The bucket isn't versioned. If state corrupts, drop it and
`terraform import grafana_dashboard.<name> <uid>` from a fresh init.

## Apply

```sh
# auth - admin password lives in SSM /grafana/admin-password
export GRAFANA_URL=https://grafana.coilysiren.me
export GRAFANA_AUTH="admin:$(aws ssm get-parameter \
  --name /grafana/admin-password \
  --with-decryption \
  --query Parameter.Value --output text)"

terraform -chdir=terraform/grafana init
terraform -chdir=terraform/grafana plan
terraform -chdir=terraform/grafana apply
```

Or via invoke from the repo root: `inv k8s.terraform-grafana`.

## Adding a dashboard

1. Drop the YAML in `dashboards/<name>.yaml`. Use a stable `uid` field.
2. Add a `grafana_dashboard` resource in `dashboards.tf`.
3. `terraform plan && terraform apply`.

If the dashboard previously lived in `grafana-values.yml`'s `dashboards:`
block, **remove it from that file in the same commit**. Both sources
managing the same dashboard means the helm-rendered ConfigMap stomps
the API-provisioned copy on every grafana pod restart.
