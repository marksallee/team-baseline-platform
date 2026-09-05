#!/usr/bin/env bash
# Full account teardown: destroy every team's AWS resources, clean up the one
# known drifted resource, and (only if asked) tear down the shared bootstrap
# infra too. This does NOT delete any team directories - use
# scripts/offboard-team.sh for that. Use this when you just want the AWS
# bill back to zero without giving up the repo state.
#
#   ./scripts/destroy-all.sh              # destroy all team-* stacks only
#   ./scripts/destroy-all.sh --bootstrap  # ALSO destroy the shared state
#                                          # bucket, lock table, OIDC
#                                          # provider and CI roles - only do
#                                          # this when you are completely
#                                          # done with the exercise, since
#                                          # every team's backend.tf depends
#                                          # on this infra existing.
#
# Why resources can seem "pinned" even after this runs clean:
#   1. bootstrap/ is a separate Terraform config with its own (local) state.
#      Destroying inside teams/team-*/ can never touch it - that's
#      intentional, so a team can't accidentally nuke the shared platform.
#   2. bootstrap/main.tf sets `lifecycle { prevent_destroy = true }` on the
#      state bucket on purpose (see the comment above that resource). Even
#      `terraform destroy` run inside bootstrap/ will refuse to remove it
#      until you delete that lifecycle block yourself - this script will not
#      do that for you.
#   3. One IAM role, github-actions-team-baseline-ci, exists in the account
#      but matches no resource in the current .tf (oidc.tf now creates
#      platform-github-actions-ci instead) - it's drift from an earlier
#      rename, so Terraform has no way to know about it or destroy it.
#      This script deletes it directly via the AWS CLI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORPHAN_ROLE="github-actions-team-baseline-ci"
ORPHAN_POLICY="team-baseline-ci-permissions"

echo "This will destroy real AWS resources for every team directory under teams/."
read -r -p "Type 'destroy' to confirm: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Confirmation did not match, aborting." >&2
  exit 1
fi

for team_dir in "$REPO_ROOT"/teams/*/; do
  team_name="$(basename "$team_dir")"
  echo
  echo "== Destroying ${team_name} =="
  (cd "$team_dir" && terraform init -input=false && terraform destroy)
done

echo
echo "== Removing drifted IAM role: ${ORPHAN_ROLE} =="
if aws iam get-role --role-name "$ORPHAN_ROLE" >/dev/null 2>&1; then
  aws iam delete-role-policy --role-name "$ORPHAN_ROLE" --policy-name "$ORPHAN_POLICY" || true
  aws iam delete-role --role-name "$ORPHAN_ROLE"
  echo "Deleted ${ORPHAN_ROLE}."
else
  echo "${ORPHAN_ROLE} not present, skipping."
fi

if [[ "${1:-}" == "--bootstrap" ]]; then
  echo
  echo "== Bootstrap teardown =="
  echo "bootstrap/main.tf currently has:"
  echo
  echo '  resource "aws_s3_bucket" "tf_state" {'
  echo '    bucket = var.state_bucket_name'
  echo
  echo '    lifecycle {'
  echo '      prevent_destroy = true'
  echo '    }'
  echo '  }'
  echo
  echo "Before this will succeed you need to, in bootstrap/main.tf:"
  echo "  1. Delete (or comment out) that lifecycle block."
  echo "  2. Add 'force_destroy = true' to the same resource - the bucket"
  echo "     holds versioned terraform.tfstate objects, and without"
  echo "     force_destroy, S3 refuses to delete a non-empty bucket."
  echo
  read -r -p "Have you made both edits? [y/N] " EDITED
  if [[ "$EDITED" != "y" ]]; then
    echo "Aborting bootstrap teardown - no changes made." >&2
    exit 1
  fi
  (cd "$REPO_ROOT/bootstrap" && terraform init -input=false && terraform destroy)
fi

echo
echo "Done."
