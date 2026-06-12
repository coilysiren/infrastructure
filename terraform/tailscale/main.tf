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
    key          = "terraform-state/infrastructure/tailscale.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Admin OAuth pair (all:write). Needed for tailscale_acl, tailscale_device_tags,
# tailscale_tailnet_key, and tailscale_federated_identity. The runtime CI client
# at /tailscale/oauth-* is not sufficient. Credentials wired via
# scripts/k8s/terraform_tailscale.py from /tailscale/admin/oauth-client-{id,secret}.
provider "tailscale" {
  scopes  = ["all:write"]
  tailnet = "-"
}

provider "aws" {
  region = "us-east-1"
}

locals {
  devices  = yamldecode(file("${path.module}/devices.yaml")).devices
  services = yamldecode(file("${path.module}/services.yaml")).services

  # Strip the owner prefix; OIDC subject adds its own "repo:coilysiren/".
  repos = [
    for slug in yamldecode(file("${path.module}/repos.yaml")).repos :
    trimprefix(slug, "coilysiren/")
  ]

  # Per-service tagOwners. Empty list -> only admin OAuth can assign,
  # which matches the terraform-managed-auth-key flow.
  #
  # `svc-` prefix because Tailscale rejects tag names that start with
  # a digit after `tag:` (e.g. tag:2fauth fails 400). Also gives a
  # clear namespace alongside tag:host-<host>.
  service_tag_owners = {
    for s in local.services : "tag:svc-${s}" => []
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
      # The Mac SOCKS5 proxy container (tooling-tailscale) is scoped to
      # SSH-out to kai-server only - TCP :22 against tag:server, nothing
      # else on the tailnet.
      { action = "accept", src = ["tag:proxy"], dst = ["tag:server:22"] },
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
      # Kai's user-owned devices (phone, mac, etc.) need to reach her
      # tagged client physicals. autogroup:self only covers user-owned
      # devices owned by the same user; tagged devices have no user
      # owner so they fall out, requiring this explicit permit.
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["tag:physical"]
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
      # Companion rule so tagged client physicals can SSH into each
      # other (Mac -> WSL, tower -> Mac, etc.). Without this, the only
      # ssh destination available to a tagged Mac/laptop is tag:server.
      # Tailscale rejects autogroup:member as an ssh dst, so the rule
      # has to be expressed in terms of tags. Anything Kai wants
      # ssh-reachable from another physical needs an entry in
      # devices.yaml that carries tag:physical.
      {
        action = "accept"
        src    = ["tag:physical"]
        dst    = ["tag:physical"]
        users  = ["autogroup:nonroot", "root"]
      },
      {
        action = "accept"
        src    = ["tag:ci"]
        dst    = ["tag:server"]
        users  = ["autogroup:nonroot", "root"]
      },
      # Mac SOCKS5 proxy container (tooling-tailscale) SSH to kai-server.
      # Tag src needs a tag dst (autogroup:self is only legal with a
      # user-owned src), same shape as the tag:ci rule above.
      {
        action = "accept"
        src    = ["tag:proxy"]
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
        "tag:proxy"              = []
        "tag:kai-server"             = []
        "tag:kai-desktop-tower"      = []
        "tag:kai-desktop-tower-wsl"  = []
        "tag:kai-tower-3026"         = []
        "tag:kai-tower-3026-wsl"     = []
        "tag:kai-windows-laptop"     = []
        "tag:kais-macbook-pro"       = []
        "tag:ser8"                   = []
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

# One federated identity per deployable repo. The OIDC-array shape: every
# repo gets its own client_id / audience pair, scoped to a single subject
# (branch ref). Tighten to job_workflow_ref once the agent-driven trigger
# replaces the main-push trigger.
resource "tailscale_federated_identity" "ci" {
  for_each = toset(local.repos)

  # Tailscale caps description at 50 chars and rejects punctuation like
  # ":" (400 keys: description had invalid characters). Stick to letters,
  # digits, hyphens, spaces.
  description = "CI deploy ${each.key}"
  issuer      = "https://token.actions.githubusercontent.com"
  subject     = "repo:coilysiren/${each.key}:ref:refs/heads/main"
  scopes      = ["auth_keys"]
  tags        = ["tag:ci"]
}

# One auth key per service. preauthorized = the device enrolls without
# needing manual admin approval in the console. reusable + ephemeral =
# false because each sidecar consumes the key once at first boot, then
# the kubelet-managed state Secret stores the persisted node identity;
# subsequent pod restarts re-use it.
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
    "tag:svc-${each.key}",
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

# Auth key for the local Mac SOCKS5 proxy container (tooling-tailscale
# skill). Unlike the k8s sidecar keys above, this one is reusable +
# ephemeral: the Docker container holds no persisted ts-state volume, so
# it must re-auth on every recreate, and ephemeral keeps dead containers
# from littering the device list. Tagged tag:proxy (least privilege):
# the policy above scopes tag:proxy to TCP :22 plus SSH against
# tag:server only, so a leaked key reaches kai-server's SSH and nothing
# else on the tailnet.
resource "tailscale_tailnet_key" "mac_proxy" {
  reusable      = true
  ephemeral     = true
  preauthorized = true
  expiry        = 7776000 # 90 days in seconds, the tailscale max
  tags          = ["tag:proxy"]
  description   = "mac docker socks5 proxy"

  # tag:proxy is registered in tagOwners by tailscale_acl.policy; that
  # ACL update must land before this key is minted or the API rejects
  # the tag with "requested tags are invalid or not permitted (400)".
  # Same first-apply race the device-tags resource guards against.
  depends_on = [tailscale_acl.policy]
}

resource "aws_ssm_parameter" "mac_proxy_authkey" {
  name        = "/coilysiren/mac-proxy/ts-authkey"
  type        = "SecureString"
  value       = tailscale_tailnet_key.mac_proxy.key
  description = "tailscale auth key for the mac docker socks5 proxy (terraform-managed, reusable+ephemeral, tag:proxy)"
}

output "tagged_devices" {
  description = "map of device short name -> tag list applied"
  value       = local.devices
}

output "client_ids" {
  description = "map of repo name -> TS_CLIENT_ID (the federated identity id, marked sensitive)"
  value       = { for k, v in tailscale_federated_identity.ci : k => v.id }
  sensitive   = true
}

output "audiences" {
  description = "map of repo name -> TS_AUDIENCE (the OIDC aud claim, marked sensitive)"
  value       = { for k, v in tailscale_federated_identity.ci : k => v.audience }
  sensitive   = true
}

output "ssm_paths" {
  description = "map of service -> SSM path holding its auth key (consume via ExternalSecret)"
  value       = { for k, v in aws_ssm_parameter.ts_authkey : k => v.name }
}

output "device_count" {
  description = "number of tailnet devices managed by this module"
  value       = length(local.services)
}
