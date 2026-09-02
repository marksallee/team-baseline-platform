variable "buckets" {
  type = map(object({
    visibility = string
  }))
}

variable "trusted_principal_arns" {
  type = list(string)
}

variable "cost_center" {
  type = string
}

variable "owner_email" {
  type = string
}
