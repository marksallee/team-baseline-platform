# One-time, platform-owned infra (same rationale as main.tf): the GitHub
# Actions OIDC trust and the role team-pipeline.yml assumes via
# secrets.PLATFORM_CI_ROLE_ARN. Without this, the workflow's "Configure AWS
# credentials (OIDC)" step has no role to assume and every plan/apply job
# fails before it reaches Terraform.
#
# One role is shared by both the PR "plan" job and the main-push "apply"
# job, matching the single PLATFORM_CI_ROLE_ARN secret the workflow already
# reads in both places. Its policy is scoped to only the resource shapes
# this platform's own modules create (buckets/roles under the enforced
# naming convention, plus the shared state bucket/lock table) - not
# AdministratorAccess - so a compromised workflow run can't reach outside
# what team-baseline.tf and bootstrap/main.tf are meant to manage.

variable "github_repo" {
  description = "GitHub org/repo allowed to assume the CI role, as \"owner/repo\"."
  type        = string
  default     = "marksallee/team-baseline-platform"
}

data "aws_caller_identity" "current" {}

# GitHub's OIDC token issuer. AWS validates the token against its own
# trusted CA bundle for this well-known issuer rather than the thumbprint
# content, but the resource still requires the argument - this is GitHub's
# current intermediate CA fingerprint (post their 2023 cert rotation).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "github_actions_assume" {
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

    # Scoped to this one repo, any branch/PR/tag within it - not "any
    # GitHub repo with this provider ARN in its account". Matches both the
    # classic "repo:owner/repo:*" subject format and GitHub's newer
    # immutable-ID form "repo:owner@ownerid/repo@repoid:*" (confirmed via a
    # debug workflow step that decoded a real token - this account's tokens
    # use the ID-qualified form), so the trust relationship keeps working
    # regardless of which one GitHub issues.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:*",
        "repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "platform-github-actions-ci"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

data "aws_iam_policy_document" "github_actions_ci_permissions" {
  # Every team.tf backend.tf points at these two - CI needs to read/write
  # its own team's state and take/release the matching lock.
  statement {
    sid    = "TerraformStateBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*",
    ]
  }

  statement {
    sid       = "TerraformLockTableAccess"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.lock_table_name}"]
  }

  # Team buckets always follow "${company_prefix}-${team_name}-${key}" -
  # scoped to that naming convention, not every bucket in the account.
  # Action scope is deliberately s3:* rather than an explicit list: the
  # AWS provider's own read/write surface for a single aws_s3_bucket
  # resource (versioning, encryption, accelerate, public-access-block,
  # policy, etc.) doesn't follow one consistent IAM action-name prefix
  # (e.g. s3:PutEncryptionConfiguration vs s3:PutBucketVersioning), so an
  # explicit allow-list turns into an ongoing whack-a-mole against every
  # provider version. The blast-radius control here is the *resource* ARN
  # pattern, not the action list - this role still can't touch any bucket
  # outside the naming convention, which is the property that actually
  # matters for isolation.
  statement {
    sid     = "ManageTeamBuckets"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::sallee-${data.aws_caller_identity.current.account_id}-*",
      "arn:aws:s3:::sallee-${data.aws_caller_identity.current.account_id}-*/*",
    ]
  }

  # Team roles are always named "${team_name}-role" with an inline
  # "${team_name}-bucket-access" policy - scoped to that shape, not every
  # role in the account. Same s3:* rationale applies to iam:* here - the
  # resource ARN pattern (role/*-role) is the actual isolation boundary.
  statement {
    sid       = "ManageTeamRoles"
    effect    = "Allow"
    actions   = ["iam:*"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-role"]
  }

  # aws_caller_identity is used inside the module itself and has no
  # resource-level permissions to scope.
  statement {
    sid       = "AllowCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_ci" {
  name   = "platform-team-baseline-management"
  role   = aws_iam_role.github_actions_ci.id
  policy = data.aws_iam_policy_document.github_actions_ci_permissions.json
}

output "github_actions_ci_role_arn" {
  description = "Set this as the GitHub repo secret PLATFORM_CI_ROLE_ARN."
  value       = aws_iam_role.github_actions_ci.arn
}
