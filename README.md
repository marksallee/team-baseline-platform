# team-baseline-platform

Self-service AWS infrastructure baseline for product teams: a shared Terraform
module that provisions one IAM role + N S3 buckets per team, consumed by
one thin, isolated root config per team with its own state.

Built as a take-home/interview design exercise. See `docs/DESIGN.md` for the
write-up of the design decisions (state isolation, IAM scoping, CI/CD
triggering, testing strategy, offboarding, tagging).

## Requirements coverage

| Requirement | Status | Where |
|---|---|---|
| ≥1 S3 bucket + 1 IAM role per team | ✅ | `modules/team-baseline/main.tf` |
| Team declares bucket count + public/private per bucket | ✅ | `buckets` variable, no default on `visibility` |
| Scales 1 → 300+ teams, zero platform code changes | ✅ | module invoked once per team; CI diffs `teams/**` |
| Team owns its own declaration file | ✅ | `teams/<name>/team.auto.tfvars` |
| Isolated Terraform state per team | ✅ | unique S3 backend `key` per team, shared bucket + lock table |
| CI/CD triggers on a team's file changing | ✅ | `.github/workflows/team-pipeline.yml` |
| Onboarding a team requires zero module changes | ✅ | `scripts/new-team.sh` only writes `teams/<name>/` |
| Bucket visibility has no default | ✅ | validation rejects anything but literal `"public"`/`"private"` |
| Role scoped to only that team's own buckets | ✅ | policy built from this invocation's `aws_s3_bucket.this`, not a wildcard |
| Enforced bucket naming convention | ✅ | `${company_prefix}-${team_name}-${key}` |
| Idempotent, safe to re-apply | ✅ | `docs/DESIGN.md` § Idempotency - no provisioners, deterministic names |
| Tested without deploying to real AWS | ✅ | `tests/team-baseline/`, native `terraform test` + `mock_provider` |
| Bonus: team offboarding | ✅ | `scripts/offboard-team.sh` |
| Bonus: tagging for cost allocation/ownership | ✅ | `docs/DESIGN.md` § Tagging strategy |

## Repo layout

```
modules/team-baseline/   # the ONE reusable module. Never touched to add a team.
teams/<team-name>/       # one dir per team: their declaration + a call to the module + their own backend/state key
tests/team-baseline/     # terraform native tests (mocked provider, no AWS needed)
bootstrap/               # one-time platform infra: the S3 bucket + DynamoDB table that hold all team state
scripts/new-team.sh      # scaffolds a new team directory
.github/workflows/       # CI: detects which team dir(s) changed, plans/applies only those
```

## Quick start (WSL / VS Code)

I've already grown familiar with Terraform installed under WSL from the Proxmox demo, so this
should be familiar — same binary, different provider.

```bash
# from WSL (Ubuntu) shell, inside VS Code's integrated terminal
git clone https://github.com/marksallee/team-baseline-platform.git
cd team-baseline-platform

# confirm terraform is the WSL one, not a Windows install leaking in via PATH
which terraform
terraform version

# AWS CLI + credentials (see below)
aws configure
```

VS Code extensions worth having (if not already, from the Proxmox repo):
`HashiCorp Terraform` (syntax + validate on save) and `AWS Toolkit` are both
fine to install in the WSL remote window (Extensions pane → search → "Install
in WSL: Ubuntu"), same as you'd have done for the Proxmox provider.

## AWS account setup

1. New AWS account, with programmatic access configured locally. A card is
   required at signup even though nothing should get charged at this scale.
2. **Set a budget alert immediately** — Billing console → Budgets → create a
   $5 and a $20 zero-based alert. This exercise costs pennies (a few S3
   buckets, some IAM, and Terraform state) as long as you remember to
   `terraform destroy` after any live demo.
3. Create an IAM user (not root) for yourself with programmatic access, or
   better, set up `aws configure sso` if you want to practice the way a real
   platform team would. For a quick demo, an IAM user with
   `AdministratorAccess` scoped to this throwaway account is fine — just
   don't reuse that user/account for anything real.
4. `aws configure` in WSL, or `aws configure sso` — either way, confirm with
   `aws sts get-caller-identity`.

## Bootstrap (one-time, platform-owned)

Before any team can run, the state backend itself needs to exist:

```bash
cd bootstrap
terraform init
terraform apply
```

This creates the S3 bucket + DynamoDB lock table that every team's
`backend.tf` points at. It's the one piece of infra that
*isn't* self-service — it's created once, by the platform team, and almost
never touched again.

## Running the tests (no AWS account needed)

```bash
cd tests/team-baseline
terraform test
```

This uses Terraform's native test framework with a **mocked provider** —
no real AWS calls, no cost, no credentials required. Good for CI on every PR
and good to run before you even have an AWS account set up.

## Onboarding a new team

```bash
./scripts/new-team.sh team-gamma
```

Scaffolds `teams/team-gamma/` from the template, wires up its own state key.
Edit `teams/team-gamma/team.auto.tfvars`, open a PR — CI plans just that
directory. See `docs/DESIGN.md` for the full flow.
