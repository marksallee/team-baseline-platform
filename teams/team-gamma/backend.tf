terraform {
  backend "s3" {
    bucket         = "sallee-tfstate-603685288055"
    key            = "teams/gamma/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sallee-tf-locks-603685288055"
    encrypt        = true
  }
}
