terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State is a pure projection of live AWS reads - no managed resources,
  # nothing to corrupt. Native S3 locking, same bucket as the sibling
  # modules.
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

# Read-only inventory of Kai's AWS footprint: SSM parameters, S3 buckets,
# Route53 zones + records. Everything here is a data source, not a
# resource - the module observes, it does not own. `terraform output`
# is the inventory surface.
#
# SSM parameters are read with with_decryption = false. For a
# SecureString that returns the KMS ciphertext, never the plaintext, so
# no secret value lands in tfstate. The module only ever reads names,
# types, and ARNs anyway - the `values` attribute is untouched.

data "aws_ssm_parameters_by_path" "all" {
  path            = "/"
  recursive       = true
  with_decryption = false
}

# S3 has no "list every bucket" data source. Buckets are few and
# strictly non-overlapping, so they are enumerated by name here. A new
# bucket gets one line added to this list.
locals {
  s3_bucket_names = [
    "coilysiren-assets",
    "kai-game-backups",
  ]
}

data "aws_s3_bucket" "bucket" {
  for_each = toset(local.s3_bucket_names)
  bucket   = each.value
}

# Route53 is fully auto-discovered: every hosted zone in the account,
# then every record set in each zone.
data "aws_route53_zones" "all" {}

data "aws_route53_zone" "zone" {
  for_each = toset(data.aws_route53_zones.all.ids)
  zone_id  = each.value
}

data "aws_route53_records" "records" {
  for_each = toset(data.aws_route53_zones.all.ids)
  zone_id  = each.value
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

  s3_buckets = [
    for name in sort(local.s3_bucket_names) : {
      name   = name
      region = data.aws_s3_bucket.bucket[name].region
    }
  ]

  route53 = [
    for zone_id, zone in data.aws_route53_zone.zone : {
      zone    = zone.name
      private = zone.private_zone
      records = sort([
        for rr in data.aws_route53_records.records[zone_id].resource_record_sets :
        "${rr.name} ${rr.type}"
      ])
    }
  ]
}

output "inventory" {
  description = "Full AWS resource inventory: SSM parameter names/types, S3 buckets, Route53 zones + records. No secret values."
  value = {
    ssm_parameters = local.ssm_parameters
    s3_buckets     = local.s3_buckets
    route53        = local.route53
  }
}

output "counts" {
  description = "Per-type resource counts, for a quick at-a-glance read."
  value = {
    ssm_parameters = length(local.ssm_parameters)
    s3_buckets     = length(local.s3_buckets)
    route53_zones  = length(local.route53)
  }
}
