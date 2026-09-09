terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project   = "persona-runtime"
      Purpose   = "gpu-serving-baseline"
      ManagedBy = "terraform"
    }
  }
}
