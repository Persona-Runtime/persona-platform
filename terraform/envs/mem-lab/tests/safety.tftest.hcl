mock_provider "aws" {}

variables {
  expected_account_id = "000000000000"
  ami_id              = "ami-00000000000000000"
  availability_zone   = "ap-northeast-2a"
  vpc_cidr            = "10.90.0.0/16"
  # 합성값이지만 실제와 같은 종류의 네 범위를 둔다. 게이트가 "빈 목록이라 통과"하는 상태로
  # 테스트되지 않게 하려는 것이다.
  reserved_cidrs = [
    "192.168.50.0/24",
    "10.244.0.0/16",
    "10.96.0.0/12",
    "10.80.0.0/16",
  ]
  ssh_public_key          = "ssh-ed25519 AAAATESTONLY synthetic"
  launch_review_confirmed = true
}

run "closed_ingress_baseline" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.bootstrap_ssh) == 0 && length(aws_vpc_security_group_ingress_rule.tailscale) == 0
    error_message = "No inbound access is permitted without explicit peer configuration."
  }

  # 4 GiB가 실험 설계의 일부다. 더 큰 타입으로 바꾸면 lab consumer가 상한까지 올라가도
  # MemoryPressure에 도달하지 못하고, 실험이 "축출 없음"이 아니라 압박 주입 실패가 된다.
  assert {
    condition     = aws_instance.mem.instance_type == "t3a.medium" && aws_instance.mem.tags["Name"] == "persona-mem-01"
    error_message = "Keep the reviewed persona-mem-01 t3a.medium (4 GiB) baseline; a larger node cannot reach MemoryPressure with the declared lab consumers."
  }

  assert {
    condition     = aws_instance.mem.root_block_device[0].volume_type == "gp3" && aws_instance.mem.root_block_device[0].volume_size == 30 && aws_instance.mem.root_block_device[0].encrypted
    error_message = "Encrypted gp3 30 GiB is required."
  }

  # burstable 인스턴스에서 unlimited는 credit 소진 시 초과 요금을 자동으로 발생시킨다.
  assert {
    condition     = aws_instance.mem.credit_specification[0].cpu_credits == "standard"
    error_message = "CPU credits must stay standard; unlimited turns a credit shortfall into an unbounded bill."
  }

  assert {
    condition     = aws_instance.mem.metadata_options[0].http_tokens == "required" && aws_instance.mem.metadata_options[0].http_put_response_hop_limit == 1 && aws_instance.mem.metadata_options[0].instance_metadata_tags == "disabled"
    error_message = "IMDSv2 required, hop limit 1 and metadata tags disabled are all required."
  }

  assert {
    condition     = aws_instance.mem.user_data == null
    error_message = "Do not place tailnet auth keys or join tokens in user data; it is readable from IMDS and stored in state."
  }

  # `instance profile 없음`과 `user_data_base64 없음`은 여기서 단정하지 않는다. mock provider의
  # plan에서 두 속성은 apply 뒤에야 정해지는 unknown이라, 조건에 넣으면 값이 틀렸을 때가 아니라
  # **항상** "Unknown condition value"로 실패한다(직접 확인했다). 두 항목은
  # scripts/test-mem-lab-negative.sh가 선언 파일에서 `iam_instance_profile`·`user_data`
  # 키워드 자체를 찾는 방식으로 검사한다 — 그 검사는 새로 추가된 자원에도 걸리므로
  # 이 경우에는 오히려 더 강하다.

  assert {
    condition     = aws_instance.mem.instance_initiated_shutdown_behavior == "stop"
    error_message = "A guest shutdown must stop the instance, not terminate it and discard the kubelet logs of that run."
  }

  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0" && aws_subnet.mem.cidr_block == "10.90.0.0/24"
    error_message = "Public subnet and default route must be configured."
  }

  # envs/prod와 같은 한계: 이 단정은 collection의 크기를 세며, 다른 이름으로 선언된
  # egress 자원은 보이지 않는다. 규약이 지켜지는지를 확인하는 검사다.
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.outbound) == 1
    error_message = "Egress must stay a single declared rule; add one only with a separate decision."
  }
}

# Kubernetes 포트가 공인 경계에 열리지 않는지 본다. ingress가 실제로 존재하는 상태에서
# 검사해야 의미가 있으므로 두 종류를 모두 켜고 확인한다.
#
# 한계: 이 단정은 선언된 두 ingress 자원의 포트 범위를 본다. 다른 이름의 ingress 자원을
# 새로 추가하면 여기서는 보이지 않는다. 그 경로는 scripts/test-mem-lab-negative.sh의
# 정적 검사(파일에서 금지 포트 숫자를 찾는다)가 막는다. 두 검사를 함께 둔 이유가 그것이다.
run "no_public_kubernetes_ports" {
  command = plan
  variables {
    bootstrap_ssh_cidr   = "192.0.2.1/32"
    tailscale_peer_cidrs = ["198.51.100.1/32"]
  }

  assert {
    condition = alltrue([
      for rule in concat(
        aws_vpc_security_group_ingress_rule.bootstrap_ssh[*],
        values(aws_vpc_security_group_ingress_rule.tailscale),
      ) :
      !anytrue([
        for port in [4240, 6443, 8472, 10250] :
        rule.from_port <= port && port <= rule.to_port
      ])
    ])
    error_message = "A public ingress rule covers a Kubernetes port (API 6443, kubelet 10250, Cilium VXLAN 8472 or health 4240). That traffic belongs inside the tailnet."
  }

  # NodePort는 대역이라 대표값 두 개만 보면 30500-30600 같은 부분 구간을 놓친다.
  # 구간이 [30000, 32767]과 조금이라도 겹치면 실패한다.
  assert {
    condition = alltrue([
      for rule in concat(
        aws_vpc_security_group_ingress_rule.bootstrap_ssh[*],
        values(aws_vpc_security_group_ingress_rule.tailscale),
      ) :
      rule.from_port > 32767 || rule.to_port < 30000
    ])
    error_message = "A public ingress rule overlaps the NodePort range 30000-32767; lab Services must not be reachable from the internet."
  }
}

run "explicit_peer_access" {
  command = plan
  variables {
    bootstrap_ssh_cidr   = "192.0.2.1/32"
    tailscale_peer_cidrs = ["198.51.100.1/32"]
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.bootstrap_ssh[0].ip_protocol == "tcp" && aws_vpc_security_group_ingress_rule.bootstrap_ssh[0].from_port == 22 && aws_vpc_security_group_ingress_rule.bootstrap_ssh[0].to_port == 22 && aws_vpc_security_group_ingress_rule.bootstrap_ssh[0].cidr_ipv4 == "192.0.2.1/32"
    error_message = "SSH must be TCP 22 from only the explicitly configured peer."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.tailscale["198.51.100.1/32"].ip_protocol == "udp" && aws_vpc_security_group_ingress_rule.tailscale["198.51.100.1/32"].from_port == 41641 && aws_vpc_security_group_ingress_rule.tailscale["198.51.100.1/32"].to_port == 41641
    error_message = "Tailscale ingress must be UDP 41641 transport only."
  }
}

run "unreviewed_launch_rejected" {
  command = plan
  variables { launch_review_confirmed = false }
  expect_failures = [aws_instance.mem]
}

# ── 겹침 게이트 ──────────────────────────────────────────────────────────────
#
# 네 방향을 따로 본다. 하나의 사례만 두면 계산이 한쪽으로만 맞아도 통과한다.

# 후보가 예약 범위를 포함하는 경우(192.168.0.0/16 ⊃ 192.168.50.0/24).
run "vpc_containing_home_lan_rejected" {
  command = plan
  variables { vpc_cidr = "192.168.0.0/16" }
  expect_failures = [aws_vpc.lab]
}

# 후보와 예약 범위가 정확히 같은 경우(Pod CIDR).
run "vpc_equal_to_pod_cidr_rejected" {
  command = plan
  variables { vpc_cidr = "10.244.0.0/16" }
  expect_failures = [aws_vpc.lab]
}

# 후보가 예약 범위 안에 들어가는 경우(10.96.0.0/12 ⊃ 10.100.0.0/16).
run "vpc_inside_service_cidr_rejected" {
  command = plan
  variables { vpc_cidr = "10.100.0.0/16" }
  expect_failures = [aws_vpc.lab]
}

run "vpc_equal_to_gpu_candidate_rejected" {
  command = plan
  variables { vpc_cidr = "10.80.0.0/16" }
  expect_failures = [aws_vpc.lab]
}

# 경계 사례: 바로 붙어 있지만 겹치지 않는다(10.245.0.0/16은 10.244.0.0/16 다음 블록이다).
# 비교가 `<`가 아니라 `<=`로 쓰였다면 여기서 거짓 양성이 나고 이 run이 실패한다.
run "adjacent_vpc_accepted" {
  command = plan
  variables { vpc_cidr = "10.245.0.0/16" }

  assert {
    condition     = length(local.overlapping_reserved) == 0
    error_message = "An adjacent, non-overlapping block must pass; a false positive here means the interval comparison is inclusive on the wrong side."
  }
}

# 호스트 비트가 남은 표기를 넣어도 블록의 첫 주소로 정규화되는지 본다. 정규화가 없으면
# 10.244.0.0/16과의 겹침을 놓친다. shape validation이 /16 canonical만 받으므로 후보가
# 아니라 reserved 쪽에 넣어 확인한다.
run "unnormalised_reserved_entry_still_detected" {
  command = plan
  variables {
    vpc_cidr       = "10.244.0.0/16"
    reserved_cidrs = ["10.244.5.0/24"]
  }
  expect_failures = [aws_vpc.lab]
}

run "empty_reserved_cidrs_rejected" {
  command = plan
  variables { reserved_cidrs = [] }
  expect_failures = [var.reserved_cidrs]
}

run "malformed_reserved_cidr_rejected" {
  command = plan
  variables { reserved_cidrs = ["192.168.50.0"] }
  expect_failures = [var.reserved_cidrs]
}

run "worldwide_ssh_rejected" {
  command = plan
  variables { bootstrap_ssh_cidr = "0.0.0.0/0" }
  expect_failures = [var.bootstrap_ssh_cidr]
}

run "worldwide_tailscale_rejected" {
  command = plan
  variables { tailscale_peer_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.tailscale_peer_cidrs]
}

run "non_private_vpc_rejected" {
  command = plan
  variables { vpc_cidr = "100.64.0.0/16" }
  expect_failures = [var.vpc_cidr]
}
