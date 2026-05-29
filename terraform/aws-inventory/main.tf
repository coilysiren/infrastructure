terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "coilysiren-assets"
    key          = "terraform-state/infrastructure/aws-inventory.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# Kai's AWS footprint: SSM parameters, S3 buckets, Route53 zone + records.
#
# S3 and Route53 are managed resources - Terraform owns them and detects
# drift. They were `terraform import`ed from pre-existing state, no new
# infrastructure was created. SSM stays a data source: managing an
# aws_ssm_parameter would pull every decrypted SecureString value into
# tfstate, a real secret surface, so the module only ever observes SSM.

# ---------------------------------------------------------------------------
# SSM - data source only (see note above).
# ---------------------------------------------------------------------------

# Read with with_decryption = false. For a SecureString that returns the
# KMS ciphertext, never the plaintext, so no secret value lands in
# tfstate. The module only reads names and types anyway.
data "aws_ssm_parameters_by_path" "all" {
  path            = "/"
  recursive       = true
  with_decryption = false
}

locals {
  # names and types come back as parallel lists - pair them through a
  # name -> type map so the sorted output stays consistent.
  ssm_type_by_name = zipmap(
    data.aws_ssm_parameters_by_path.all.names,
    data.aws_ssm_parameters_by_path.all.types,
  )

  ssm_parameters = [
    for name in sort(data.aws_ssm_parameters_by_path.all.names) : {
      name = name
      type = local.ssm_type_by_name[name]
    }
  ]
}

# ---------------------------------------------------------------------------
# S3 - managed resources, minimal import.
# ---------------------------------------------------------------------------

# Just `bucket =`. Sub-resources (versioning, encryption, public-access
# block, lifecycle) are deliberately left unmanaged so the post-import
# plan is clean - see README. A new bucket gets one line added here.
locals {
  s3_bucket_names = [
    "coilysiren-assets",
    "kai-game-backups",
  ]
}

resource "aws_s3_bucket" "bucket" {
  for_each = toset(local.s3_bucket_names)
  bucket   = each.value
}

# ---------------------------------------------------------------------------
# Route53 - managed zone + records, imported from existing state.
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "coilysiren_me" {
  name = "coilysiren.me"
  # The zone was created by the Route53 registrar. Keep its original
  # comment so the import plan stays clean (the resource default is
  # "Managed by Terraform").
  comment = "HostedZone created by Route53 Registrar"
}

locals {
  zone_id = aws_route53_zone.coilysiren_me.zone_id
}

# Home public IP, pulled from SSM. AGENTS.md: the home IP is an opaque
# identity-linked id and must not land in checked-in HCL. Sourcing it
# from the parameter keeps the literal out of the .tf and out of plan
# output (the provider marks aws_ssm_parameter.value sensitive).
data "aws_ssm_parameter" "home_ip" {
  name = "/coilysiren/home/public-ip"
}

# A records that resolve to the home cluster. Same IP, different TTLs.
resource "aws_route53_record" "home_a" {
  for_each = {
    "eco"              = 60
    "eco-jobs-tracker" = 300
    "eco-mcp"          = 300
    "factorio"         = 300
    "galaxy-gen"       = 300
    "grafana"          = 300
  }

  zone_id = local.zone_id
  name    = "${each.key}.coilysiren.me"
  type    = "A"
  ttl     = each.value
  records = [data.aws_ssm_parameter.home_ip.value]
}

# Apex A - Netlify's anycast load balancer, not the home cluster.
resource "aws_route53_record" "apex_a" {
  zone_id = local.zone_id
  name    = "coilysiren.me"
  type    = "A"
  ttl     = 60
  records = ["75.2.60.5"]
}

# www - the Netlify-hosted marketing site.
resource "aws_route53_record" "www" {
  zone_id = local.zone_id
  name    = "www.coilysiren.me"
  type    = "CNAME"
  ttl     = 60
  records = ["coilysiren-dot-me.netlify.app."]
}

# Coily Co fleet subdomains - Netlify-hosted sites, same pattern as www.
# Each points at its Netlify site's anycast subdomain; Netlify serves the
# custom domain + provisions TLS once the domain is added to the site.
resource "aws_route53_record" "flightdeck" {
  zone_id = local.zone_id
  name    = "flightdeck.coilysiren.me"
  type    = "CNAME"
  ttl     = 60
  records = ["coilyco-flight-deck.netlify.app."]
}

resource "aws_route53_record" "bridge" {
  zone_id = local.zone_id
  name    = "bridge.coilysiren.me"
  type    = "CNAME"
  ttl     = 60
  records = ["coilyco-bridge.netlify.app."]
}

# TXT verification records. All three are world-readable DNS by design
# (Google site verification, atproto handle DID, Discord domain hash).
resource "aws_route53_record" "txt" {
  for_each = {
    "@"        = "google-site-verification=cx2k2l_2F2Pqb_5HrLe03mMu5x_EHU8znVXkfmPmGV8"
    "_atproto" = "did=did:plc:xvgmere7jp42xfc5xn47lvyi"
    "_discord" = "dh=caaf268c3e61b84d806cf8c4e3d502be5f7be768"
  }

  zone_id = local.zone_id
  name    = each.key == "@" ? "coilysiren.me" : "${each.key}.coilysiren.me"
  type    = "TXT"
  ttl     = 300
  records = [each.value]
}

# Apex NS and SOA. AWS pre-creates both with the zone. The NS values are
# the zone's assigned name servers - hardcoded with trailing dots to
# match what Route53 stores (the zone's name_servers attribute drops
# them, which would show as a spurious diff).
resource "aws_route53_record" "ns" {
  zone_id = local.zone_id
  name    = "coilysiren.me"
  type    = "NS"
  ttl     = 172800
  records = [
    "ns-1394.awsdns-46.org.",
    "ns-617.awsdns-13.net.",
    "ns-323.awsdns-40.com.",
    "ns-1779.awsdns-30.co.uk.",
  ]
}

resource "aws_route53_record" "soa" {
  zone_id = local.zone_id
  name    = "coilysiren.me"
  type    = "SOA"
  ttl     = 900
  records = ["ns-1394.awsdns-46.org. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400"]
}

# ---------------------------------------------------------------------------
# Inventory outputs.
# ---------------------------------------------------------------------------

locals {
  route53_records = sort(concat(
    [for r in aws_route53_record.home_a : "${r.name} ${r.type}"],
    [for r in aws_route53_record.txt : "${r.name} ${r.type}"],
    [
      "${aws_route53_record.apex_a.name} ${aws_route53_record.apex_a.type}",
      "${aws_route53_record.www.name} ${aws_route53_record.www.type}",
      "${aws_route53_record.flightdeck.name} ${aws_route53_record.flightdeck.type}",
      "${aws_route53_record.bridge.name} ${aws_route53_record.bridge.type}",
      "${aws_route53_record.ns.name} ${aws_route53_record.ns.type}",
      "${aws_route53_record.soa.name} ${aws_route53_record.soa.type}",
    ],
  ))
}

output "inventory" {
  description = "AWS resource inventory: SSM parameter names/types, S3 buckets, Route53 zone + record names. No secret values."
  value = {
    ssm_parameters  = local.ssm_parameters
    s3_buckets      = sort(local.s3_bucket_names)
    route53_zone    = aws_route53_zone.coilysiren_me.name
    route53_records = local.route53_records
  }
}

output "counts" {
  description = "Per-type resource counts, for a quick at-a-glance read."
  value = {
    ssm_parameters  = length(local.ssm_parameters)
    s3_buckets      = length(local.s3_bucket_names)
    route53_records = length(local.route53_records)
  }
}
