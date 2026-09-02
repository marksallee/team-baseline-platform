variable "team_name" {
  description = "Short team identifier, used as the isolation boundary for IAM and as part of the bucket naming convention. Lowercase, alphanumeric + hyphen only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.team_name))
    error_message = "team_name must be 2-20 chars, lowercase letters/digits/hyphens only (e.g. \"team-alpha\")."
  }
}

variable "buckets" {
  description = <<-EOT
    Map of bucket short-name => config. The bucket short-name becomes part of
    the enforced naming convention: "$${company_prefix}-$${team_name}-$${key}".
    visibility has NO default on purpose - every bucket must explicitly state
    "public" or "private" so a team can never accidentally get a public
    bucket by omission.
  EOT
  type = map(object({
    visibility = string
  }))

  validation {
    condition     = length(var.buckets) > 0
    error_message = "Each team must declare at least one bucket."
  }

  validation {
    condition = alltrue([
      for name, cfg in var.buckets : contains(["public", "private"], cfg.visibility)
    ])
    error_message = "Every bucket's visibility must be exactly \"public\" or \"private\" - no other values, no default."
  }

  validation {
    condition = alltrue([
      for name, cfg in var.buckets : can(regex("^[a-z0-9-]{2,30}$", name))
    ])
    error_message = "Bucket short-names must be 2-30 chars, lowercase letters/digits/hyphens only."
  }
}

variable "company_prefix" {
  description = "Global naming prefix enforced across every team's buckets, keeps bucket names globally unique and identifiable as belonging to this org."
  type        = string
  default     = "sallee-603685288055"
}

variable "trusted_principal_arns" {
  description = <<-EOT
    ARNs allowed to assume this team's role (e.g. the team's CI/CD OIDC role,
    or specific human/SSO roles). Deliberately has no default - a platform
    module should never ship a role nobody can assume, but it also should
    never silently default to something overly permissive like account root.
  EOT
  type = list(string)
}

variable "tags" {
  description = "Team-supplied tags (e.g. CostCenter, Owner) merged with the module's own baseline tags on every resource."
  type        = map(string)
  default     = {}
}
