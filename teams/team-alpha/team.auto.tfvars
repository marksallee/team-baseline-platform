# This file is owned by team-alpha. Edit it, open a PR against this repo.
# CI will plan (and, on merge, apply) only this directory - other teams'
# state is never touched by this change.

buckets = {
  uploads = { visibility = "private" }
  assets  = { visibility = "public" }
}

# Who's allowed to assume team-alpha's IAM role. Replace with your real
# account ID / CI role ARN before applying against a live AWS account.
trusted_principal_arns = [
  "arn:aws:iam::603685288055:root"
]

cost_center = "eng-alpha"
owner_email = "alpha-team@company.com"
