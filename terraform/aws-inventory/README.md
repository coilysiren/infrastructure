# terraform/aws-inventory

Read-only inventory of Kai's AWS footprint. Every block is a data source - the module observes live AWS state and never owns a resource. `terraform output` is the inventory surface.

## Shape

- `aws_ssm_parameters_by_path.all` - every SSM parameter, read recursively from `/` with `with_decryption = false`. For a SecureString that returns KMS ciphertext, never plaintext, so no secret value reaches tfstate. The module reads names, types, and ARNs only.
- `aws_s3_bucket.bucket` - one data lookup per bucket name in the `s3_bucket_names` local. S3 has no list-all-buckets data source, so a new bucket gets one line added there.
- `aws_route53_zones` + `aws_route53_zone` + `aws_route53_records` - fully auto-discovered. Every hosted zone, then every record set in each zone.

Two outputs: `inventory` (the full listing) and `counts` (per-type totals).

## Run

```
coily exec terraform-aws-inventory action=init
coily exec terraform-aws-inventory action=plan
coily exec terraform-aws-inventory action=apply
coily exec terraform-aws-inventory action=output
```

`apply` creates no resources. It records the data source reads in state so `terraform output` can serve the inventory. `action=output` prints the `inventory` output as YAML.

Re-run `apply` whenever the inventory should be refreshed against current AWS state.

## Why data sources, not managed resources

The goal is an inventory, not a migration. Importing 129 SSM parameters as `aws_ssm_parameter` resources would pull every decrypted SecureString value into tfstate - a real secret surface. Data sources with `with_decryption = false` give the same enumeration with zero plaintext. S3 buckets and Route53 records have no such hazard, but keeping the whole module read-only makes it safe to `apply` on a schedule without ever risking live infrastructure.
