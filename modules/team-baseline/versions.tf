terraform {
  required_version = ">= 1.6.0" # 1.6+ for the native `terraform test` framework used in tests/

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
