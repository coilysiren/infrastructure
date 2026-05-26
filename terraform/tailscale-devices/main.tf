terraform {
  required_version = ">= 1.10.0"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.24"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "coilysiren-assets"
    key          = "terraform-state/infrastructure/tailscale-devices.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Credentials wired via scripts/k8s/terraform_tailscale_devices.py from
# /tailscale/admin/oauth-client-{id,secret}. Same admin client as the
# tailscale-oidc module; both need all:write to mint tagged auth keys
# and read the tailnet name. The runtime CI client at /tailscale/oauth-*
# is not sufficient.
provider "tailscale" {
  scopes  = ["all:write"]
  tailnet = "-"
}

provider "aws" {
  region = "us-east-1"
}

locals {
  services = yamldecode(file("${path.module}/services.yaml")).services
}

# One auth key per service. preauthorized = the device enrolls without
# needing manual admin approval in the console. reusable + ephemeral =
# false because each sidecar consumes the key once at first boot, then
# the operator-managed (sorry, kubelet-managed) state Secret stores the
# persisted node identity; subsequent pod restarts re-use it.
#
# expiry = 90 days is the tailscale max for an auth key. A sidecar that
# loses its state Secret after the key expires needs a fresh terraform
# apply to mint a new one. ts-state Secrets shouldn't churn under
# normal operation, but document the failure mode in
# docs/tailscale-static-devices.md.
resource "tailscale_tailnet_key" "service" {
  for_each = toset(local.services)

  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000 # 90 days in seconds
  tags = [
    "tag:k8s",
    "tag:${each.key}",
    "tag:host-kai-server",
  ]
  description = "k8s sidecar ${each.key}"
}

# SSM SecureString per service. Consumed by an ExternalSecret in the
# service's namespace that materializes a k8s Secret the tailscale
# sidecar mounts as TS_AUTHKEY_FILE.
#
# lifecycle.ignore_changes on value would be wrong here - the whole
# point of terraform owning the key is that `terraform apply` rotates
# it. If a key needs rotating before its 90-day expiry, taint the
# resource and apply.
resource "aws_ssm_parameter" "ts_authkey" {
  for_each = toset(local.services)

  name        = "/coilysiren/${each.key}/ts-authkey"
  type        = "SecureString"
  value       = tailscale_tailnet_key.service[each.key].key
  description = "tailscale auth key for ${each.key} sidecar (terraform-managed; min(state Secret loss, 90 days) before re-apply needed)"
}

output "ssm_paths" {
  description = "map of service -> SSM path holding its auth key (consume via ExternalSecret)"
  value       = { for k, v in aws_ssm_parameter.ts_authkey : k => v.name }
}

output "device_count" {
  description = "number of tailnet devices managed by this module"
  value       = length(local.services)
}
