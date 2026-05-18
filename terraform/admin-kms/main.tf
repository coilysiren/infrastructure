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
    key          = "terraform-state/infrastructure/admin-kms.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

data "aws_iam_group" "admins" {
  group_name = var.admin_group_name
}

# Admin-only KMS key. Wraps SSM SecureString parameters that should not be
# readable by the broader IAM surface even if a principal accidentally
# gains ssm:GetParameter on the namespace. SSM has no resource policy of
# its own; the KMS key policy is the resource-layer gate.
resource "aws_kms_key" "admin" {
  description             = "Admin-only KMS key. Wraps SSM params under /<*>/admin/* paths."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  # Key policy delegates to IAM via the account-root statement. The
  # actual encrypt/decrypt grant lives on an IAM group policy attached
  # to var.admin_group_name below - groups can't be principals in a
  # resource policy directly, so this is the standard delegation
  # pattern. Everything not granted in IAM is implicitly denied.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountRootFullControlDelegatesToIAM"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "admin" {
  name          = "alias/admin-only"
  target_key_id = aws_kms_key.admin.id
}

# Group policy: members of `admins` get encrypt/decrypt on this one key
# (scoped by Resource ARN). Non-members get nothing because the key
# policy only delegates to IAM and no other IAM policy in the account
# names this key.
resource "aws_iam_group_policy" "admin_kms_use" {
  name  = "admin-kms-use"
  group = data.aws_iam_group.admins.group_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.admin.arn
      },
    ]
  })
}

output "key_arn" {
  value = aws_kms_key.admin.arn
}

output "alias" {
  value = aws_kms_alias.admin.name
}
