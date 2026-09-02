#!/usr/bin/env bash
# Scaffold a new team directory. Run from repo root:
#   ./scripts/new-team.sh team-gamma
#
# Creates teams/<name>/ with team.tf, variables.tf, backend.tf (unique state
# key) and a team.auto.tfvars stub for the team to fill in and open a PR
# with. Does NOT touch modules/team-baseline - onboarding a team never
# requires a platform code change.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <team-name>" >&2
  echo "  team-name: lowercase letters/digits/hyphens, e.g. team-gamma" >&2
  exit 1
fi

TEAM_NAME="$1"

if [[ ! "$TEAM_NAME" =~ ^[a-z0-9-]{2,20}$ ]]; then
  echo "error: team-name must be 2-20 chars, lowercase letters/digits/hyphens only" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_DIR="${REPO_ROOT}/teams/${TEAM_NAME}"
SHORT_NAME="${TEAM_NAME#team-}" # module's team_name convention drops the "team-" prefix, e.g. team-gamma -> gamma

if [[ -d "$TEAM_DIR" ]]; then
  echo "error: ${TEAM_DIR} already exists" >&2
  exit 1
fi

mkdir -p "$TEAM_DIR"

cat > "${TEAM_DIR}/team.tf" <<EOF
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
  region = "us-east-1"
}

module "baseline" {
  source = "../../modules/team-baseline"

  team_name = "${SHORT_NAME}"
  buckets   = var.buckets

  trusted_principal_arns = var.trusted_principal_arns

  tags = {
    CostCenter = var.cost_center
    Owner      = var.owner_email
  }
}

output "role_arn" {
  value = module.baseline.role_arn
}

output "bucket_names" {
  value = module.baseline.bucket_names
}
EOF

cat > "${TEAM_DIR}/variables.tf" <<'EOF'
variable "buckets" {
  type = map(object({
    visibility = string
  }))
}

variable "trusted_principal_arns" {
  type = list(string)
}

variable "cost_center" {
  type = string
}

variable "owner_email" {
  type = string
}
EOF

cat > "${TEAM_DIR}/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket         = "sallee-tfstate-603685288055"
    key            = "teams/${SHORT_NAME}/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sallee-tf-locks-603685288055"
    encrypt        = true
  }
}
EOF

cat > "${TEAM_DIR}/team.auto.tfvars" <<EOF
# Owned by ${TEAM_NAME}. Fill this in, then open a PR.
# CI will plan/apply only this directory.

buckets = {
  # example: uploads = { visibility = "private" }
}

trusted_principal_arns = [
  # e.g. "arn:aws:iam::<account-id>:role/${TEAM_NAME}-ci"
]

cost_center = "eng-${SHORT_NAME}"
owner_email = "${TEAM_NAME}@company.com"
EOF

echo "Created ${TEAM_DIR}"
echo "Next steps:"
echo "  1. Edit ${TEAM_DIR}/team.auto.tfvars"
echo "  2. cd ${TEAM_DIR} && terraform init && terraform plan"
echo "  3. Open a PR - CI will plan just this directory"
