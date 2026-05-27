# terraform/admin-kms

Single admin-only KMS key (`alias/admin-only`) used to wrap SSM SecureString parameters whose blast radius should be tighter than the default `alias/aws/ssm`. SSM has no resource policy; the KMS key policy is the only resource-layer gate available.

## Shape

- `aws_kms_key.admin` - 30-day deletion window, rotation enabled.
- `aws_kms_alias.admin` - `alias/admin-only`.
- Key policy delegates to IAM (account-root statement only).
- `aws_iam_group_policy.admin_kms_use` attached to the existing `admins` group (overridable via `var.admin_group_name`) grants Encrypt/Decrypt/ReEncrypt/GenerateDataKey/DescribeKey on this one key's ARN.

Access path: member of `admins` group -> IAM allows kms ops on the key ARN -> key policy delegates to IAM -> ops succeed. Non-members get nothing (no other IAM policy in the account names this key).

Groups as principals: KMS resource policies can't reference IAM groups directly - groups aren't identities. The IAM-group-policy + key-policy-delegation pattern above is the standard workaround.

## Run

```
coily exec terraform-admin-kms action=init
coily exec terraform-admin-kms action=plan
coily exec terraform-admin-kms action=apply
```

Default `admin_group_name = "admins"`. Override in `terraform.tfvars` if needed.

## Consumers

- `terraform/tailscale/` - admin Tailscale OAuth pair at `/tailscale/admin/oauth-client-*` is wrapped under this key.

When stashing a new admin param:

```
coily ops aws ssm put-parameter \
  --name /<namespace>/admin/<key> \
  --type SecureString --key-id alias/admin-only \
  --value FILL_ME_IN
```

## Recovery

If you lose `admins` group membership or the group is deleted, the account-root statement is the escape hatch - sign in with root creds, fix group membership or reapply terraform with a corrected `admin_group_name`.
