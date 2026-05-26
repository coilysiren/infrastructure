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

  # Cross-module read of the sibling tailscale-devices module's service
  # list. tailscale-devices is the single source of truth for which k8s
  # sidecars exist; this file just registers their tagOwners so the
  # auth keys minted there can carry tag:<service> alongside tag:k8s.
  k8s_services = yamldecode(file("${path.module}/../tailscale-devices/services.yaml")).services

  # Per-service tagOwners. Empty list -> only admin OAuth can assign,
  # which matches the terraform-managed-auth-key flow.
  #
  # `svc-` prefix because Tailscale rejects tag names that start with
  # a digit after `tag:` (e.g. tag:2fauth fails 400). Also gives a
  # clear namespace alongside tag:host-<host>.
  service_tag_owners = {
    for s in local.k8s_services : "tag:svc-${s}" => []
  }
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
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["autogroup:self", "tag:server"]
        users  = ["autogroup:nonroot", "root"]
      },
      # Tagged client physicals need their own SSH-out permit since
      # they no longer match autogroup:member after tagging. Split
      # from the autogroup:member rule because autogroup:self is only
      # legal with user-owned src - tagged devices have no user
      # (owned by the tagged-devices meta-user), so the API rejects
      # autogroup:self in dst when src is a tag.
      {
        action = "accept"
        src    = ["tag:physical"]
        dst    = ["tag:server"]
        users  = ["autogroup:nonroot", "root"]
      },
      {
        action = "accept"
        src    = ["tag:ci"]
        dst    = ["tag:server"]
        users  = ["autogroup:nonroot", "root"]
      },
    ]

    tagOwners = merge(
      {
        "tag:ci"                 = ["group:ci"]
        "tag:k8s"                = []
        "tag:server"             = []
        "tag:physical"           = []
        "tag:kai-server"         = []
        "tag:kai-desktop-tower"  = []
        "tag:kai-windows-laptop" = []
        "tag:kais-macbook-pro"   = []
        "tag:host-kai-server"    = []
      },
      local.service_tag_owners,
    )
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
#
# depends_on ensures the ACL update lands first, registering any new
# tagOwners, before the device-tag API tries to assign them. Without
# this, a first-time bootstrap (or any run that adds a new tag to
# both the policy and a device in the same apply) races and fails
# with "requested tags are invalid or not permitted (400)".
resource "tailscale_device_tags" "physical" {
  for_each = local.devices

  device_id  = local.device_id_by_short_name[each.key]
  tags       = each.value
  depends_on = [tailscale_acl.policy]
}

output "tagged_devices" {
  description = "map of device short name -> tag list applied"
  value       = local.devices
}
