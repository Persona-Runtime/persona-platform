terraform {
  # envs/prod와 같은 하한을 쓴다. 1.7 미만에는 `terraform test`가 없어 tests/safety.tftest.hcl이
  # 실행되지 않고, 이 환경의 안전 단정이 조용히 사라진다.
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
      Project = "persona-runtime"
      # envs/prod와 Purpose를 다르게 둔다. 두 환경이 같은 계정에 있을 수 있어, 비용·자원
      # 조회에서 GPU 서빙 기준선과 메모리 압박 실험 자원을 구분해야 한다.
      Purpose   = "mem-eviction-lab"
      ManagedBy = "terraform"
    }
  }
}
