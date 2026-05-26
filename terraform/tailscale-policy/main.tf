terraform {
  required_version = ">= 1.10.0"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.24"
    }
  }

  backend "s3" {
    bucket       = "coilysiren-assets"
    key          = "terraform-state/infrastructure/tailscale-policy.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Same admin OAuth pair as terraform/tailscale-{devices,oidc}/. all:write
# is needed for tailscale_acl (writes the tailnet policy) and for
# tailscale_device_tags (mutates per-device tag lists).
provider "tailscale" {
  scopes  = ["all:write"]
  tailnet = "-"
}

locals {
  devices = yamldecode(file("${path.module}/devices.yaml")).devices
}

# Owns the full tailnet policy file. First apply has to be a no-op:
# `terraform import tailscale_acl.policy <tailnet>` adopts the current
# policy into state, then this body is iterated until plan is empty.
# Only after that do additive edits (new tagOwners) land.
#
# acl content is jsonencode'd to keep one obvious source of truth.
# Tailscale accepts strict JSON on the API even though the web console
# default is HuJSON; the server normalizes either way.
resource "tailscale_acl" "policy" {
  acl = jsonencode({
    acls = [
      { action = "accept", src = ["autogroup:member"], dst = ["*:*"] },
      { action = "accept", src = ["tag:ci"], dst = ["tag:server:*"] },
    ]

    groups = {
      "group:ci" = []
    }

    nodeAttrs = [
      { target = ["autogroup:member"], attr = ["funnel"] },
    ]

    ssh = [
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["autogroup:self", "tag:server"]
        users  = ["autogroup:nonroot", "root"]
      },
      {
        action = "accept"
        src    = ["tag:ci"]
        dst    = ["tag:server"]
        users  = ["autogroup:nonroot", "root"]
      },
    ]

    tagOwners = {
      "tag:ci"               = ["group:ci"]
      "tag:k8s"              = []
      "tag:server"           = []
      "tag:physical"         = []
      "tag:kai-server"       = []
      "tag:kai-desktop-tower" = []
      "tag:kai-windows-laptop" = []
      "tag:kais-macbook-pro" = []
      "tag:host-kai-server"  = []
    }
  })
}

# Look each physical device up by MagicDNS short name. tailscale_device
# resolves on `name` (full FQDN) or `hostname`; the data source matches
# on either, so the short name from devices.yaml works.
data "tailscale_device" "physical" {
  for_each = local.devices

  name = each.key
}

# Overwrites the full tag list on each device, so devices.yaml is the
# single source of truth per host. Reassigning tags via terraform
# requires the device to currently be authed by a user (not a tagged
# auth key); the four physicals all qualify.
resource "tailscale_device_tags" "physical" {
  for_each = local.devices

  device_id = data.tailscale_device.physical[each.key].id
  tags      = each.value
}

output "tagged_devices" {
  description = "map of device short name -> tag list applied"
  value       = local.devices
}
