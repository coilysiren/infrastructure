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
      # Tagged devices fall out of autogroup:member. The physicals
      # enumerated in devices.yaml are also tailnet clients (the Mac
      # SSHes into kai-server, the laptops reach k3s NodePorts, etc.),
      # so they need the same universal outbound permit member devices
      # already have.
      { action = "accept", src = ["tag:physical"], dst = ["*:*"] },
      { action = "accept", src = ["tag:ci"], dst = ["tag:server:*"] },
    ]

    groups = {
      "group:ci" = []
    }

    nodeAttrs = [
      { target = ["autogroup:member"], attr = ["funnel"] },
    ]

    ssh = [
      # Same logic as the tag:physical accept rule above - tagged
      # client physicals need their own SSH-out permit since they no
      # longer match autogroup:member after tagging.
      {
        action = "accept"
        src    = ["autogroup:member", "tag:physical"]
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

# tailscale_device (singular) matches on `name` (FQDN) or `hostname`
# (the raw OS-reported hostname). Neither is stable across the fleet:
# Windows machines report "KAI-DESKTOP-TOWER" / "LAPTOP-5RANHQD2", and
# the Mac reports "Kai's MacBook Pro". The FQDN is the only stable
# identifier the short names in devices.yaml map to predictably, so
# pull the full device list once and filter by FQDN prefix.
data "tailscale_devices" "all" {}

locals {
  device_id_by_short_name = {
    for short, _ in local.devices :
    short => one([
      for d in data.tailscale_devices.all.devices :
      d.id if startswith(d.name, "${short}.")
    ])
  }
}

# Overwrites the full tag list on each device, so devices.yaml is the
# single source of truth per host. Reassigning tags via terraform
# requires the device to currently be authed by a user (not a tagged
# auth key); the four physicals all qualify.
resource "tailscale_device_tags" "physical" {
  for_each = local.devices

  device_id = local.device_id_by_short_name[each.key]
  tags      = each.value
}

output "tagged_devices" {
  description = "map of device short name -> tag list applied"
  value       = local.devices
}
