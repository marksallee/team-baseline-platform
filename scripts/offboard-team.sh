#!/usr/bin/env bash
# Offboard a team: destroy their AWS resources, then remove their directory.
# Deliberately NOT automatic on file-deletion in CI - destroy is irreversible
# (S3 buckets included, unless someone left objects that block a clean
# delete), so this is a manual, explicit action a human runs, ideally as
# its own PR/approval step rather than folded into the normal apply pipeline.
#
#   ./scripts/offboard-team.sh team-gamma

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <team-name>" >&2
  exit 1
fi

TEAM_NAME="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_DIR="${REPO_ROOT}/teams/${TEAM_NAME}"

if [[ ! -d "$TEAM_DIR" ]]; then
  echo "error: ${TEAM_DIR} does not exist" >&2
  exit 1
fi

echo "About to destroy all AWS resources for ${TEAM_NAME}."
read -r -p "Type the team name to confirm: " CONFIRM
if [[ "$CONFIRM" != "$TEAM_NAME" ]]; then
  echo "Confirmation did not match, aborting." >&2
  exit 1
fi

pushd "$TEAM_DIR" > /dev/null
terraform init
terraform destroy
popd > /dev/null

echo "Resources destroyed. Removing ${TEAM_DIR} and its state key..."
rm -rf "$TEAM_DIR"

echo "Done. Remember to also delete the now-empty state object at"
echo "  s3://acme-fintech-tfstate/teams/${TEAM_NAME#team-}/terraform.tfstate"
echo "(terraform destroy empties it but doesn't remove the object itself)."
