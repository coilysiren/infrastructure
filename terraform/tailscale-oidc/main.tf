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
    key          = "terraform-state/infrastructure/tailscale-oidc.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Credentials via provider-native env vars:
#   TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET (or TAILSCALE_API_KEY)
# Export before running `terraform apply` directly. The OAuth client must
# have `all:write` scope - the runtime CI client at /tailscale/oauth-* is
# not sufficient.
provider "tailscale" {
  scopes  = ["all:write"]
  tailnet = "-"
}

locals {
  # Flat list of "coilysiren/<name>" strings from repos.yaml. Strip the owner
  # prefix; the OIDC subject adds its own "repo:coilysiren/" prefix and the
  # outputs below carry the bare name as the map key for downstream sync.
  repos = [
    for slug in yamldecode(file("${path.module}/repos.yaml")).repos :
    trimprefix(slug, "coilysiren/")
  ]
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

# Full tailnet ACL. The `tailscale_acl` resource is a singleton - applying
# it replaces the entire policy document at
# https://login.tailscale.com/admin/acls. Hand-edits in the console will
# be overwritten on the next apply; manage all tailnet policy here.
resource "tailscale_acl" "main" {
  # First apply takes over a hand-edited tailnet policy. Subsequent applies
  # are still terraform -> tailscale only; the flag is a one-shot safety
  # bypass, not a "merge with console edits" mode.
  overwrite_existing_content = true

  acl = jsonencode({
    groups = {
      "group:ci" = []
    }

    tagOwners = {
      "tag:server"       = []
      "tag:ci"           = ["group:ci"]
      "tag:k8s-operator" = []
      "tag:k8s"          = ["tag:k8s-operator"]
    }

    acls = [
      # All human tailnet members get unrestricted access. autogroup:member
      # is every user account in the tailnet (excludes tagged devices like
      # tag:ci, which keeps the CI surface narrow below).
      { action = "accept", src = ["autogroup:member"], dst = ["*:*"] },
      { action = "accept", src = ["tag:ci"], dst = ["tag:server:*"] },
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

    nodeAttrs = [
      {
        # Funnel policy - lets tailnet members enable Tailscale Funnel
        # on their own devices. https://tailscale.com/kb/1223/
        target = ["autogroup:member"]
        attr   = ["funnel"]
      },
    ]
  })
}

# Outputs are consumed by scripts/k8s/sync_tailscale_oidc_secrets.py, which
# pushes TS_CLIENT_ID + TS_AUDIENCE to each repo via the gh CLI's live auth
# (no PAT in the module - the /github/pat path is retired). Run after every
# `terraform apply` that touches federated identities.
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
