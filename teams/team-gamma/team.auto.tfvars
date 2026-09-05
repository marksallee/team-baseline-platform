# Owned by team-gamma. Fill this in, then open a PR.
# CI will plan/apply only this directory.

buckets = {
  reports       = { visibility = "private" }
  public-assets = { visibility = "public" }
}

trusted_principal_arns = [
  "arn:aws:iam::603685288055:root"
]

cost_center = "eng-gamma"
owner_email = "team-gamma@company.com"
