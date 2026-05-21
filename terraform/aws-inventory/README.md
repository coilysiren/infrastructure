# terraform/aws-inventory

Kai's AWS footprint as Terraform. S3 buckets and the `coilysiren.me`
Route53 zone + records are managed resources - Terraform owns them and
detects drift. SSM parameters stay a read-only data source.

## Shape

- `aws_ssm_parameters_by_path.all` - data source. Every SSM parameter,
  read recursively from `/` with `with_decryption = false`. For a
  SecureString that returns KMS ciphertext, never plaintext, so no
  secret value reaches tfstate. Names and types only.
- `aws_s3_bucket.bucket` - one managed bucket per name in the
  `s3_bucket_names` local. A new bucket gets one line added there.
- `aws_route53_zone.coilysiren_me` + `aws_route53_record.*` - the
  managed hosted zone and all 13 record sets.

Two outputs: `inventory` (the full listing) and `counts` (per-type totals).

## Why SSM stays a data source

Managing an `aws_ssm_parameter` resource pulls its decrypted value into
tfstate. Every SSM parameter here is a SecureString, so that would be a
real secret surface. The data source enumerates names and types with
zero plaintext, which is all the inventory needs.

## S3 - minimal import

The buckets are imported as bare `aws_s3_bucket` resources (`bucket =`
only). Their sub-resources - versioning, server-side encryption,
public-access block, lifecycle - are deliberately left unmanaged. A
bare `aws_s3_bucket` import produces a clean plan. Pulling in
`aws_s3_bucket_versioning` and friends can wait until there is a reason
to manage them.

## Route53 - the home IP

Six A records resolve to the home cluster. The home public IP is an
identity-linked opaque id and must not sit in checked-in HCL, so those
records source it from `data.aws_ssm_parameter("/coilysiren/home/public-ip")`.
The provider marks that value sensitive, so it stays out of plan output
too.

The apex `NS` and `SOA` records are managed with `allow_overwrite = true`
because AWS pre-creates both with the zone.

## Run

```
coily exec terraform-aws-inventory action=init
coily exec terraform-aws-inventory action=plan
coily exec terraform-aws-inventory action=apply
coily exec terraform-aws-inventory action=output
```

`apply` is not auto-approved. The module owns live DNS - a bad apply
breaks every `coilysiren.me` service - so review the `plan`, then run
`apply` interactively where terraform's approval prompt has a TTY.
`action=output` prints the `inventory` output as YAML.

## Importing (one-time bootstrap)

The resources were brought under management with `terraform import`, no
new infrastructure created. To re-bootstrap on a fresh state:

```
terraform -chdir=terraform/aws-inventory import 'aws_s3_bucket.bucket["coilysiren-assets"]' coilysiren-assets
terraform -chdir=terraform/aws-inventory import 'aws_s3_bucket.bucket["kai-game-backups"]'  kai-game-backups
terraform -chdir=terraform/aws-inventory import aws_route53_zone.coilysiren_me <ZONE_ID>
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.apex_a'              <ZONE_ID>_coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.www'                 <ZONE_ID>_www.coilysiren.me_CNAME
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.ns'                  <ZONE_ID>_coilysiren.me_NS
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.soa'                 <ZONE_ID>_coilysiren.me_SOA
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.home_a["eco"]'              <ZONE_ID>_eco.coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.home_a["eco-jobs-tracker"]' <ZONE_ID>_eco-jobs-tracker.coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.home_a["eco-mcp"]'          <ZONE_ID>_eco-mcp.coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.home_a["factorio"]'         <ZONE_ID>_factorio.coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.home_a["galaxy-gen"]'       <ZONE_ID>_galaxy-gen.coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.home_a["grafana"]'          <ZONE_ID>_grafana.coilysiren.me_A
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.txt["@"]'        <ZONE_ID>_coilysiren.me_TXT
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.txt["_atproto"]' <ZONE_ID>__atproto.coilysiren.me_TXT
terraform -chdir=terraform/aws-inventory import 'aws_route53_record.txt["_discord"]' <ZONE_ID>__discord.coilysiren.me_TXT
```
