terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "baseline" {
  source = "../../modules/team-baseline"

  team_name = "beta"
  buckets   = var.buckets

  trusted_principal_arns = var.trusted_principal_arns

  tags = {
    CostCenter = var.cost_center
    Owner      = var.owner_email
  }
}

output "role_arn" {
  value = module.baseline.role_arn
}

output "bucket_names" {
  value = module.baseline.bucket_names
}
