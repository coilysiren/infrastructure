terraform {
  required_version = ">= 1.10.0"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.24"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
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
#   GITHUB_TOKEN
# Export before running `terraform apply` directly. The OAuth client must
# have `all:write` scope - the runtime CI client at /tailscale/oauth-* is
# not sufficient.
provider "tailscale" {
  scopes  = ["all:write"]
  tailnet = "-"
}

provider "github" {
  owner = "coilysiren"
}

locals {
  # Flat list of "coilysiren/<name>" strings from repos.yaml. Strip the owner
  # prefix for the GitHub provider (which already has owner="coilysiren") and
  # for the OIDC subject (which adds its own "repo:coilysiren/" prefix).
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

resource "github_actions_secret" "ts_client_id" {
  for_each = tailscale_federated_identity.ci

  repository      = each.key
  secret_name     = "TS_CLIENT_ID"
  # Tailscale's federated_identity exposes the client id as the resource
  # `id` attribute (it's also called the "key id" in their schema). There
  # is no separate `client_id` field.
  plaintext_value = each.value.id
}

resource "github_actions_secret" "ts_audience" {
  for_each = tailscale_federated_identity.ci

  repository      = each.key
  secret_name     = "TS_AUDIENCE"
  plaintext_value = each.value.audience
}
