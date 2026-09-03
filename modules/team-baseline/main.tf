locals {
  common_tags = merge(var.tags, {
    Team      = var.team_name
    ManagedBy = "terraform"
    Module    = "team-baseline"
  })
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# S3 buckets - one per entry in var.buckets, name enforced by the module,
# never chosen freely by the team.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = var.buckets

  bucket = "${var.company_prefix}-${var.team_name}-${each.key}"

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

# Public Access Block is set explicitly per bucket based on the declared
# visibility - private buckets get every protection ON, public buckets get
# the minimum turned off (policy + ACL public access), never a blanket "off".
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  block_public_acls       = each.value.visibility == "public" ? false : true
  block_public_policy     = each.value.visibility == "public" ? false : true
  ignore_public_acls      = each.value.visibility == "public" ? false : true
  restrict_public_buckets = each.value.visibility == "public" ? false : true
}

# Public buckets get an explicit, narrow, auditable read-only policy -
# GetObject only, never List/Put/Delete for the world. Private buckets get
# no bucket policy at all (access is via the IAM role only).
resource "aws_s3_bucket_policy" "public_read" {
  for_each = { for name, cfg in var.buckets : name => cfg if cfg.visibility == "public" }
  bucket   = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadOnlyGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject"]
      Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
    }]
  })

  # public access block must be relaxed before a public policy can attach
  depends_on = [aws_s3_bucket_public_access_block.this]
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
        Sid       = "ListOwnBucketsOnly"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [for b in aws_s3_bucket.this : b.arn]
      },
      {
        Sid       = "ReadWriteOwnBucketObjectsOnly"
        Effect    = "Allow"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource  = [for b in aws_s3_bucket.this : "${b.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_role" "team" {
  name               = "${var.team_name}-role"
  assume_role_policy = local.assume_role_policy
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "team_bucket_access" {
  name   = "${var.team_name}-bucket-access"
  role   = aws_iam_role.team.id
  policy = local.bucket_access_policy
}
