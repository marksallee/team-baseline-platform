# Owned by team-beta. Same module, different shape - proves the platform
# module needed zero changes to support a team with a different number of
# buckets and a different public/private mix than team-alpha.

buckets = {
  logs      = { visibility = "private" }
  reports   = { visibility = "private" }
  public-ui = { visibility = "public" }
}

trusted_principal_arns = [
  "arn:aws:iam::123456789012:root"
]

cost_center = "eng-beta"
owner_email = "beta-team@company.com"
