terraform {
  required_version = ">= 1.10.0"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.35"
    }
  }

  # Native S3 locking (use_lockfile) replaces the old DynamoDB lock table.
  # State is small and rebuildable from the JSON files in dashboards/, so
  # we skip versioning on the bucket; if state corrupts, re-import.
  backend "s3" {
    bucket       = "coilysiren-assets"
    key          = "terraform-state/infrastructure/grafana.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Auth via env vars: GRAFANA_URL, GRAFANA_AUTH ("admin:<password>" or "<api-token>").
# See README.md for the unwrap-from-SSM one-liner.
provider "grafana" {}
