# Native Terraform tests (Terraform >= 1.6) for modules/team-baseline.
# Run with:  terraform test   (from this directory)
#
# The AWS provider is entirely mocked - these tests never touch a real
# account, cost nothing, and can run in CI on every PR before anyone applies
# anything for real. This is the "how do you validate without deploying"
# answer for the module itself.

mock_provider "aws" {}

variables {
  team_name = "testteam"
  trusted_principal_arns = ["arn:aws:iam::123456789012:role/testteam-ci"]
}

run "private_bucket_gets_full_public_access_block" {
  command = plan

  variables {
    buckets = {
      data = { visibility = "private" }
    }
  }

  module {
    source = "../../modules/team-baseline"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this["data"].block_public_acls == true
    error_message = "Private bucket must have block_public_acls = true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this["data"].restrict_public_buckets == true
    error_message = "Private bucket must have restrict_public_buckets = true"
  }

  assert {
    condition     = length([for k, v in aws_s3_bucket_policy.public_read : k]) == 0
    error_message = "Private-only team should not create any public bucket policy"
  }
}

run "public_bucket_relaxes_block_and_gets_read_only_policy" {
  command = plan

  variables {
    buckets = {
      assets = { visibility = "public" }
    }
  }

  module {
    source = "../../modules/team-baseline"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this["assets"].block_public_policy == false
    error_message = "Public bucket must relax block_public_policy"
  }

  assert {
    condition     = can(aws_s3_bucket_policy.public_read["assets"])
    error_message = "Public bucket must get a bucket policy"
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.public_read["assets"].policy, "s3:GetObject")
    error_message = "Public bucket policy must grant GetObject"
  }

  assert {
    condition     = !strcontains(aws_s3_bucket_policy.public_read["assets"].policy, "s3:PutObject")
    error_message = "Public bucket policy must NOT grant PutObject to the world"
  }

  assert {
    condition     = !strcontains(aws_s3_bucket_policy.public_read["assets"].policy, "s3:DeleteObject")
    error_message = "Public bucket policy must NOT grant DeleteObject to the world"
  }
}

run "bucket_naming_convention_is_enforced" {
  command = plan

  variables {
    buckets = {
      uploads = { visibility = "private" }
    }
  }

  module {
    source = "../../modules/team-baseline"
  }

  assert {
    condition     = aws_s3_bucket.this["uploads"].bucket == "sallee-603685288055-testteam-uploads"
    error_message = "Bucket name must follow <prefix>-<team>-<key> convention"
  }
}

run "iam_role_policy_only_references_this_teams_buckets" {
  command = plan

  variables {
    buckets = {
      uploads = { visibility = "private" }
      exports = { visibility = "public" }
    }
  }

  module {
    source = "../../modules/team-baseline"
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.team_bucket_access.policy, "sallee-603685288055-testteam-uploads")
    error_message = "Team's IAM policy must reference its own uploads bucket"
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.team_bucket_access.policy, "sallee-603685288055-testteam-exports")
    error_message = "Team's IAM policy must reference its own exports bucket"
  }
}

run "at_least_one_bucket_is_required" {
  command = plan

  variables {
    buckets = {}
  }

  module {
    source = "../../modules/team-baseline"
  }

  expect_failures = [
    var.buckets,
  ]
}

run "missing_visibility_value_is_rejected" {
  command = plan

  variables {
    buckets = {
      broken = { visibility = "internal-only" } # not "public" or "private" - must fail, no silent default
    }
  }

  module {
    source = "../../modules/team-baseline"
  }

  expect_failures = [
    var.buckets,
  ]
}

run "invalid_team_name_is_rejected" {
  command = plan

  variables {
    team_name = "Team_Alpha!" # uppercase/underscore/bang not allowed
    buckets = {
      data = { visibility = "private" }
    }
  }

  module {
    source = "../../modules/team-baseline"
  }

  expect_failures = [
    var.team_name,
  ]
}
