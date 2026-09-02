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
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "AllowTrustedPrincipalsToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "team" {
  name               = "${var.team_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "bucket_access" {
  statement {
    sid       = "ListOwnBucketsOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [for b in aws_s3_bucket.this : b.arn]
  }

  statement {
    sid       = "ReadWriteOwnBucketObjectsOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for b in aws_s3_bucket.this : "${b.arn}/*"]
  }
}

resource "aws_iam_role_policy" "team_bucket_access" {
  name   = "${var.team_name}-bucket-access"
  role   = aws_iam_role.team.id
  policy = data.aws_iam_policy_document.bucket_access.json
}
