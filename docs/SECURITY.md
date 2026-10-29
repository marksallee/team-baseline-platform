# Security walkthrough

What was wrong, what changed, and why. Read top to bottom to rebuild the mental model.

## The threat model in one paragraph

The most powerful thing in this platform is the **CI role** GitHub Actions assumes: it can create IAM roles and S3 buckets. If an attacker (or a buggy PR) controls what that role does, they can escalate to full account access. So the design question is: *what is the worst thing the CI role can do, and what can a PR author make it do?*

## Findings and fixes

### 1. `iam:*` on `role/*-role` (privilege escalation)
**Before:** CI had every IAM action on any role whose name ends in `-role`. That includes `iam:AttachRolePolicy` (attach `AdministratorAccess`), `iam:UpdateAssumeRolePolicy` (add itself to the trust policy) and `iam:PassRole`. Any existing role named `something-role` in the account (not just team roles) was one API call from admin. The doc said "resource pattern is the isolation boundary", but `*-role` is a *name suffix anyone can match*, not a boundary.

**After:**
- Team roles are created under the IAM **path** `/team-baseline/`; CI is scoped to `role/team-baseline/*`. Only roles this module made are reachable.
- CI gets a curated list: CreateRole, DeleteRole, UpdateRole, UpdateAssumeRolePolicy, Tag/UntagRole, Put/DeleteRolePolicy, PutRolePermissionsBoundary. No `AttachRolePolicy`, no `PassRole`, no `iam:*`.
- A **permissions boundary** (`team-baseline-boundary`) caps every team role to S3 on the platform's buckets. Explicit **Deny** statements force `CreateRole`/`PutRolePermissionsBoundary` to carry that exact boundary, and forbid removing it. So even a malicious `team.tf` can't mint an admin role.

### 2. "Anyone impersonating `*-role`?" (trust policy)
Two separate questions:
- **Who can assume a team role** is `trusted_principal_arns`. It had no validation, so `"*"` (any AWS account) was accepted. Now the variable requires specific IAM ARNs. **Still open:** alpha/gamma trust `...:root`, which means *any principal in the account that has `sts:AssumeRole`* can use the role. beta's `123456789012` is a placeholder account. Replace these with real role ARNs (the role must exist before the trust policy can reference it).
- **Who can assume the CI role** is the GitHub OIDC `sub` claim. It was `repo:owner/repo:*`: any branch, PR or tag. A PR can edit the workflow or Terraform and then run code holding *write* credentials. Now there are two roles:

| Role | Trust (`sub`) | Can do |
|---|---|---|
| `platform-github-actions-plan` | `...:pull_request` | read-only (state read, bucket/role config reads), no lock writes |
| `platform-github-actions-apply` | `...:environment:production` | the write actions listed above |

The plan job runs `plan -lock=false` so it needs no DynamoDB writes.

### 3. `s3:*` on team buckets
`s3:*` includes `GetObject`/`PutObject`: CI could read every team's data. Replaced with bucket-*configuration* actions (`PutBucket*`, `DeleteBucket*`, `CreateBucket`, encryption/lifecycle/etc.). No object access.
**Caveat:** this list is verified only by `terraform validate`, not against real AWS. If an apply hits `AccessDenied`, the error names the missing action; add it. This is the whack-a-mole the old comment wanted to avoid, but it is a one-time cost and the alternative is data access for CI.

### 4. What happens on `terraform destroy`?
Team buckets: `force_destroy` is now explicitly `false` (it was already the provider default). Behavior:
- **Empty bucket:** deleted.
- **Bucket with any object, old version or delete marker (versioning is on, so these count):** the delete fails with `BucketNotEmpty`. Terraform has already destroyed other resources in the plan, so you get a **partial destroy** (e.g. the role is gone, the bucket remains). Re-run after emptying it.
- There is deliberately no `prevent_destroy` on team buckets, or offboarding would be impossible. The state bucket in `bootstrap/` does have it.
- CI can't empty buckets (no object permissions), so offboarding stays a human action with `scripts/offboard-team.sh`.
- Don't set `force_destroy = true` as a shortcut; that is how a stray `destroy` deletes a team's data.

To empty a versioned bucket you need to delete all versions *and* delete markers (the console's "Empty bucket" does this).

### 5. Defense in depth added to the module
- Bucket policy on **every** bucket denies non-TLS requests (`aws:SecureTransport`). One policy per bucket, so `public_read` became `this` (a `moved` block keeps state).
- `BucketOwnerEnforced` ownership controls disable ACLs. Public buckets now only relax `block_public_policy`/`restrict_public_buckets`; the two ACL protections are always on.
- Role `max_session_duration` is 1 hour.

### 6. GitHub settings (not in code, and found OFF)
Checked with `gh api`:
- `production` environment: **`protection_rules: []`**, no reviewers and no deployment-branch policy. The workflow comment says "gate with required reviewers", but nothing is gating. Every push to `main` auto-applies.
- `main`: **not protected**.
- Because no branch policy exists, *any* branch can declare `environment: production` and obtain the apply role. The new apply trust (`environment:production`) is only as strong as that environment's rules. **Turn these on:** Settings → Environments → production → Required reviewers, and Deployment branches → "Selected branches" → `main`. Then protect `main` (require PR + `module-tests`/plan checks).

## Rollout order (important)
1. `cd bootstrap && terraform plan`, review, then `terraform apply` as an **admin** user (creates the boundary policy and both roles).
2. Set repo secrets `PLATFORM_PLAN_ROLE_ARN` and `PLATFORM_APPLY_ROLE_ARN` (from the outputs); delete `PLATFORM_CI_ROLE_ARN`.
3. Existing teams' roles change **path**, which forces replacement (destroy `alpha-role`, create `/team-baseline/alpha-role`). The new CI role can't delete the old path-less role, so run the first apply for each existing team locally as admin: `cd teams/team-alpha && terraform plan` then `terraform apply`. Anything assuming the old role ARN breaks; update it. Bucket policies are moved, not recreated.
4. Enable the GitHub settings in §6.

## Known residual risks
- CI can read/write *all* teams' state (one shared role). Per-team roles would fix it at the cost of 300 roles.
- `:root` trust on alpha/gamma (see §2).
- Plan jobs execute PR-supplied Terraform (providers, `external` data sources). Now harmless because the plan role is read-only, but it can still read state.
- The OIDC `sub` wildcards `@*` for the ID-qualified form; pin the actual owner/repo IDs once known.
