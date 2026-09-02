# Design write-up

## Module design
One reusable module, `modules/team-baseline`, takes `team_name`, `buckets`
(map of short-name -> `{visibility}`), and `trusted_principal_arns`. It's
never edited to onboard a team - every team gets a thin root config under
`teams/<name>/` that calls it. This mirrors how the platform team should
actually operate: they own and evolve the module's *contract*, product
teams consume it through a declaration file, never through hand-written
resources of their own.

## Scalability (1 -> 300+ teams)
Two things make this scale-invariant:
- The module has no knowledge of "how many teams exist" - it's invoked once
  per team, independently. Team #300 costs the same module-authoring effort
  as team #1: zero.
- CI/CD fans out from a diff, not a hardcoded list (see below), so a repo
  with 300 team directories still only plans/applies the 1-3 that actually
  changed in a given PR.

## Security
- Visibility has **no default** - `buckets` validation rejects any value
  other than the literal strings `"public"`/`"private"`, so a typo or
  omission fails plan, it doesn't silently create a private-by-default (or
  worse, public-by-default) bucket.
- Public Access Block settings are derived per-bucket from `visibility`,
  not toggled at the account level - private buckets always get full
  protection.
- Public buckets get exactly one narrow policy: anonymous `s3:GetObject`
  only. No List, no Put, no Delete for the world, ever.
- The IAM role's bucket-access policy is built from the `aws_s3_bucket.this`
  resources this exact module invocation created - not from a wildcard
  match on the naming convention. It's structurally impossible for the
  policy to reference another team's bucket ARNs, because those resources
  don't exist in this invocation's state at all.
- `trusted_principal_arns` has no default, forcing every team to state
  explicitly who can assume their role - visible in the PR diff, not
  buried in a module default.

## State isolation
Each team directory has its own `backend.tf` with a unique S3 key
(`teams/<name>/terraform.tfstate`), sharing one bucket + DynamoDB lock
table (created once via `bootstrap/`). I deliberately did **not** use
`terraform workspace`, even though it's the more obvious first idea:
workspaces share a single backend config, and it's easy to apply against
the wrong team's state just by having the wrong workspace selected -
that's a human-error blast-radius problem at 300 teams. Separate state
*keys* mean a bad apply against team-alpha's directory literally cannot
touch team-beta's state, because they're different files with independent
locks - the isolation is structural, not procedural.

## Developer experience / onboarding
`./scripts/new-team.sh <name>` scaffolds a new team directory from a
template (own `backend.tf` with a unique key, a `team.auto.tfvars` stub).
The team fills in their buckets/tags, opens a PR. No platform code changes,
no ticket to the platform team required.

## CI/CD
`.github/workflows/team-pipeline.yml` diffs the PR/push against `teams/**`,
extracts the *unique team directories touched*, and matrices a plan (on PR)
or apply (on push to main) job per changed team. If `modules/**` itself
changed, every team is planned/applied, since a module change can affect
all of them. `max-parallel` caps concurrent applies to avoid hammering the
shared lock table at scale. Auth is via OIDC (`aws-actions/configure-aws-credentials`),
no long-lived AWS keys in GitHub secrets.

## Testing
`tests/team-baseline/team_baseline.tftest.hcl` uses Terraform's native test
framework (1.6+) with `mock_provider "aws" {}` - every assertion runs against
a mocked plan, no AWS account or credentials needed. Covers: private buckets
get full public-access-block, public buckets relax it and get a read-only
policy, the naming convention is enforced, the IAM policy only ever
references this team's own bucket ARNs, and that missing/invalid
`visibility` and `team_name` values fail plan rather than silently passing.
This is the answer to "how do you validate without deploying" - the whole
suite runs in CI on every PR, before any real `apply`.

## Offboarding
`./scripts/offboard-team.sh <name>` is a deliberately manual, confirmation-gated
script: `terraform destroy` against that team's directory, then remove the
directory. Not automatic on file-deletion in the normal pipeline, because
destroy is irreversible and a much higher-consequence action than apply -
it should be its own explicit, approved step.

## Tagging strategy
Every resource gets `Team`, `ManagedBy=terraform`, `Module=team-baseline`
from the module itself, plus team-supplied `CostCenter` and `Owner` merged
in from each team's tfvars. That's enough to build a per-team Cost Explorer
view or a chargeback report with zero team-specific code - the tags are a
module contract, not something each team has to remember to add themselves.
