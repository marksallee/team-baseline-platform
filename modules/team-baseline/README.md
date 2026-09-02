# module: team-baseline

Provisions one team's AWS baseline: N S3 buckets (each explicitly public or
private) and one IAM role scoped only to that team's own buckets.

This module is never edited to add a new team. Every team gets their own
call to this module from their own root config in `teams/<name>/`.

## Naming convention (enforced, not a suggestion)

Buckets are always named `${company_prefix}-${team_name}-${bucket_key}`, e.g.
`acme-fintech-alpha-uploads`. The team supplies `team_name` and the map keys
under `buckets`; they never choose the full bucket name, so there's no way
to collide with the convention or another team's namespace.

## Example

```hcl
module "baseline" {
  source    = "../../modules/team-baseline"
  team_name = "alpha"

  buckets = {
    uploads = { visibility = "private" }
    assets  = { visibility = "public" }
  }

  trusted_principal_arns = [
    "arn:aws:iam::123456789012:role/team-alpha-ci"
  ]

  tags = {
    CostCenter = "eng-alpha"
    Owner      = "alpha-team@company.com"
  }
}
```

## Inputs

| Name | Type | Required | Notes |
|---|---|---|---|
| `team_name` | string | yes | lowercase, 2-20 chars, `[a-z0-9-]` |
| `buckets` | map(object({visibility=string})) | yes | at least 1 entry; visibility must be `"public"` or `"private"` explicitly - no default |
| `trusted_principal_arns` | list(string) | yes | who can assume the team's role; no default on purpose |
| `company_prefix` | string | no (default `acme-fintech`) | global bucket-name prefix |
| `tags` | map(string) | no | merged with module's own `Team`/`ManagedBy`/`Module` tags |

## Outputs

`role_arn`, `bucket_names`, `bucket_arns`, `public_bucket_names`

## Security notes

- Public Access Block settings are derived per-bucket from `visibility` -
  private buckets always get full protection; public buckets get only the
  minimum relaxed (policy + ACL), never a blanket account-level opt-out.
- Public buckets get one narrow, explicit `s3:GetObject`-only policy - never
  list/write/delete for anonymous principals.
- The IAM role's bucket-access policy is built from `aws_s3_bucket.this` (the
  buckets this exact module invocation created), not from a wildcard pattern
  match on the naming convention - so it is structurally impossible for one
  team's role to reference another team's bucket ARNs.
- `trusted_principal_arns` has no default. A module that silently defaults
  trust to account root or `*` is a foot-gun; forcing the caller to state it
  makes the trust boundary visible in every team's own tfvars/PR diff.
