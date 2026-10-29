locals {
  common_tags = merge(var.tags, {
    Team      = var.team_name
    ManagedBy = "terraform"
    Module    = "team-baseline"
  })
}

data "aws_caller_identity" "current" {}

locals {
  # Created once in bootstrap/oidc.tf. Every team role must carry it - the CI
  # role is denied iam:CreateRole unless this exact boundary is attached.
  permissions_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.permissions_boundary_name}"
}

# ---------------------------------------------------------------------------
# S3 buckets - one per entry in var.buckets, name enforced by the module,
# never chosen freely by the team.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = var.buckets

  bucket = "${var.company_prefix}-${var.team_name}-${each.key}"

  # Explicit rather than relying on the provider default (also false): a
  # `terraform destroy` fails on a non-empty bucket instead of silently
  # deleting a team's data. Versioned buckets count delete markers and old
  # versions as "non-empty". Do not flip this to true in the module.
  force_destroy = false

  tags = merge(local.common_tags, {
    Visibility = each.value.visibility
  })
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ACLs are disabled outright (bucket owner owns every object). That removes
# the ACL route to public exposure for every bucket, public ones included, so
# the only way a bucket can become public is the one reviewed bucket policy.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Public Access Block is set explicitly per bucket based on the declared
# visibility. The two ACL protections are always ON; a public bucket only
# relaxes the two policy-related ones, never a blanket "off".
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = each.value.visibility == "public" ? false : true
  restrict_public_buckets = each.value.visibility == "public" ? false : true
}

# Every bucket gets a policy denying plain-HTTP access. Public buckets
# additionally get an explicit, narrow, auditable read-only statement -
# GetObject only, never List/Put/Delete for the world. It is one policy per
# bucket because S3 allows only one.
resource "aws_s3_bucket_policy" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }],
      each.value.visibility == "public" ? [{
        Sid       = "PublicReadOnlyGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
      }] : []
    )
  })

  # public access block must be relaxed before a public policy can attach
  depends_on = [aws_s3_bucket_public_access_block.this]
}

moved {
  from = aws_s3_bucket_policy.public_read
  to   = aws_s3_bucket_policy.this
}

# ---------------------------------------------------------------------------
# IAM role - one per team, trust policy scoped to explicitly supplied
# principals only, permissions built FROM the buckets this module just
# created (never a wildcard, never a naming-convention guess).
#
# Built via jsonencode() locals rather than the aws_iam_policy_document
# data source on purpose: that data source is provider-backed, so under
# terraform test's mock_provider it gets blanked out along with real AWS
# resources, breaking assertions on the actual policy content. jsonencode()
# is a core Terraform language function - it always computes for real,
# mocked provider or not - which keeps this module testable without AWS.
# ---------------------------------------------------------------------------

locals {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowTrustedPrincipalsToAssume"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.trusted_principal_arns }
    }]
  })

  bucket_access_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListOwnBucketsOnly"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [for b in aws_s3_bucket.this : b.arn]
      },
      {
        Sid      = "ReadWriteOwnBucketObjectsOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for b in aws_s3_bucket.this : "${b.arn}/*"]
      }
    ]
  })
}

# The /team-baseline/ path is what the CI role's IAM permissions are scoped
# to (role/team-baseline/*). The permissions boundary caps what this role can
# ever be granted, even if someone later adds a broader inline policy.
resource "aws_iam_role" "team" {
  name                 = "${var.team_name}-role"
  path                 = "/team-baseline/"
  assume_role_policy   = local.assume_role_policy
  permissions_boundary = local.permissions_boundary_arn
  max_session_duration = 3600
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "team_bucket_access" {
  name   = "${var.team_name}-bucket-access"
  role   = aws_iam_role.team.id
  policy = local.bucket_access_policy
}
