# One-time, platform-owned infra (same rationale as main.tf): the GitHub
# Actions OIDC trust and the role team-pipeline.yml assumes via
# secrets.PLATFORM_CI_ROLE_ARN. Without this, the workflow's "Configure AWS
# credentials (OIDC)" step has no role to assume and every plan/apply job
# fails before it reaches Terraform.
#
# Two roles, because the two jobs have very different trust levels:
#   - plan  (PR jobs):   READ-ONLY. A PR can edit the workflow and the
#                        Terraform it runs, so anything a PR job assumes must
#                        be harmless. Trust: sub = ...:pull_request
#   - apply (main jobs): read/write, but only reachable from the GitHub
#                        "production" environment. Trust: sub = ...:environment:production
#                        (only meaningful if that environment restricts
#                        branches to main and requires reviewers - see
#                        docs/SECURITY.md).
# Neither is AdministratorAccess, and neither has wildcard actions.

variable "github_repo" {
  description = "GitHub org/repo allowed to assume the CI role, as \"owner/repo\"."
  type        = string
  default     = "marksallee/team-baseline-platform"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repo_owner = split("/", var.github_repo)[0]
  repo_name  = split("/", var.github_repo)[1]
  bucket_arns = [
    "arn:aws:s3:::sallee-${local.account_id}-*",
    "arn:aws:s3:::sallee-${local.account_id}-*/*",
  ]
  # Only roles created by modules/team-baseline live under this path.
  team_role_arn_pattern = "arn:aws:iam::${local.account_id}:role/team-baseline/*"
  boundary_policy_name  = "team-baseline-boundary"
  boundary_policy_arn   = "arn:aws:iam::${local.account_id}:policy/${local.boundary_policy_name}"
  lock_table_arn        = "arn:aws:dynamodb:${var.region}:${local.account_id}:table/${var.lock_table_name}"
  state_bucket_arn      = "arn:aws:s3:::${var.state_bucket_name}"
}

# GitHub's OIDC token issuer. AWS validates the token against its own
# trusted CA bundle for this well-known issuer rather than the thumbprint
# content, but the resource still requires the argument - this is GitHub's
# current intermediate CA fingerprint (post their 2023 cert rotation).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# Matches both the classic "repo:owner/repo:<suffix>" subject format and
# GitHub's immutable-ID form "repo:owner@ownerid/repo@repoid:<suffix>" (this
# account's tokens use the ID-qualified form).
data "aws_iam_policy_document" "assume" {
  for_each = {
    plan  = "pull_request"
    apply = "environment:production"
  }

  statement {
    sid     = "AllowGithubActionsOidc"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:${each.value}",
        "repo:${local.repo_owner}@*/${local.repo_name}@*:${each.value}",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_plan" {
  name                 = "platform-github-actions-plan"
  assume_role_policy   = data.aws_iam_policy_document.assume["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role" "github_actions_apply" {
  name                 = "platform-github-actions-apply"
  assume_role_policy   = data.aws_iam_policy_document.assume["apply"].json
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------
# Permissions boundary for every team role. Even if a team role were ever
# given a broader policy, it still could not do more than this: S3 object
# access on buckets in this platform's naming convention. No IAM, no STS,
# no other services.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "team_boundary" {
  statement {
    sid       = "TeamBucketsOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.bucket_arns
  }
}

resource "aws_iam_policy" "team_boundary" {
  name   = local.boundary_policy_name
  policy = data.aws_iam_policy_document.team_boundary.json
}

# ---------------------------------------------------------------------------
# Shared read-only statements (used by BOTH roles: apply needs to refresh
# state just like plan does).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "read" {
  statement {
    sid       = "ReadTeamBucketConfig"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetAccelerateConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration"]
    resources = ["arn:aws:s3:::sallee-${local.account_id}-*"] # bucket-level only: no object reads
  }

  statement {
    sid       = "ReadTeamRoles"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"]
    resources = [local.team_role_arn_pattern]
  }

  statement {
    sid       = "ReadBoundaryPolicy"
    effect    = "Allow"
    actions   = ["iam:GetPolicy"]
    resources = [local.boundary_policy_arn]
  }

  statement {
    sid       = "AllowCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"] # no resource-level permissions exist for this action
  }
}

# --- plan: read-only everywhere, state is read not written, lock is not taken
# (the workflow runs `plan -lock=false`).
data "aws_iam_policy_document" "plan" {
  source_policy_documents = [data.aws_iam_policy_document.read.json]

  statement {
    sid       = "ReadStateOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
  }

  statement {
    sid       = "ReadLockTable"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [local.lock_table_arn]
  }
}

# --- apply: read + the specific writes the module's resources need.
data "aws_iam_policy_document" "apply" {
  source_policy_documents = [data.aws_iam_policy_document.read.json]

  statement {
    sid       = "TerraformStateBucketAccess"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
  }

  statement {
    sid       = "TerraformLockTableAccess"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [local.lock_table_arn]
  }

  # Bucket-level configuration only. Deliberately NOT included: s3:GetObject /
  # PutObject / DeleteObject on team buckets, so CI cannot read or tamper
  # with team data (and cannot empty a bucket, which is why destroying a
  # non-empty bucket fails - see docs/SECURITY.md).
  statement {
    sid    = "ManageTeamBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucket*",
      "s3:DeleteBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutAccelerateConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutReplicationConfiguration",
    ]
    resources = ["arn:aws:s3:::sallee-${local.account_id}-*"]
  }

  # Only roles under /team-baseline/, only the actions aws_iam_role and
  # aws_iam_role_policy use. No AttachRolePolicy (so no AdministratorAccess
  # attachment), no iam:*, no PassRole.
  statement {
    sid    = "ManageTeamRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.team_role_arn_pattern]
  }

  # Guard rails on the above: a role can only be created / re-bounded WITH
  # the team boundary, and the boundary can never be removed.
  statement {
    sid       = "TeamRolesMustCarryBoundary"
    effect    = "Deny"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = [local.team_role_arn_pattern]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_policy_arn]
    }
  }

  statement {
    sid       = "BoundaryCannotBeRemoved"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = [local.team_role_arn_pattern]
  }
}

resource "aws_iam_role_policy" "github_actions_plan" {
  name   = "platform-team-baseline-plan"
  role   = aws_iam_role.github_actions_plan.id
  policy = data.aws_iam_policy_document.plan.json
}

resource "aws_iam_role_policy" "github_actions_apply" {
  name   = "platform-team-baseline-apply"
  role   = aws_iam_role.github_actions_apply.id
  policy = data.aws_iam_policy_document.apply.json
}

output "github_actions_plan_role_arn" {
  description = "Set this as the GitHub repo secret PLATFORM_PLAN_ROLE_ARN."
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_actions_apply_role_arn" {
  description = "Set this as the GitHub repo secret PLATFORM_APPLY_ROLE_ARN (or, better, as a secret on the production environment)."
  value       = aws_iam_role.github_actions_apply.arn
}
