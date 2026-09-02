# One-time, platform-owned infra: the S3 bucket + DynamoDB table that hold
# every team's Terraform state. This is the one piece of "chicken and egg"
# infra that can't be self-service - it has to exist before any team's
# backend.tf can init. Run this once per AWS account, by the platform team,
# then leave it alone.
#
# This config's OWN state can stay local for a lab/interview setup - in a
# real org you'd bootstrap this one via a separate, even-more-locked-down
# process (e.g. a manually-applied CloudFormation stack or a very small
# separate Terraform Cloud workspace), precisely because it can't depend on
# the backend it's creating.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  type    = string
  default = "acme-fintech-tfstate"
}

variable "lock_table_name" {
  type    = string
  default = "acme-fintech-tf-locks"
}

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name

  # protects the state store itself from an accidental `terraform destroy`
  # run in the wrong directory
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # no idle cost - fine for this scale, and cheap even at 300 teams
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_locks.name
}
