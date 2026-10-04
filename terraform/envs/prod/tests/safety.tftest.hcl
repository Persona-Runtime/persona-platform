mock_provider "aws" {}

variables {
  expected_account_id     = "000000000000"
  ami_id                  = "ami-00000000000000000"
  availability_zone       = "ap-northeast-2a"
  vpc_cidr                = "10.80.0.0/16"
  ssh_public_key          = "ssh-ed25519 AAAATESTONLY synthetic"
  launch_review_confirmed = true
}

run "closed_ingress_baseline" {
  command = plan
  # 개발자의 실제 terraform.tfvars에 초기 SSH /32가 있어도, 이 사례는 명시적으로
  # peer 접근을 주지 않은 기본 구성을 검증한다.
  variables {
    bootstrap_ssh_cidr = null
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.bootstrap_ssh) == 0 && length(aws_vpc_security_group_ingress_rule.tailscale) == 0
    error_message = "No inbound access is permitted without explicit peer configuration."
  }
  assert {
    condition     = aws_instance.gpu.instance_type == "g6.xlarge" && aws_instance.gpu.tags["Name"] == "persona-gpu-01" && aws_instance.gpu.associate_public_ip_address
    error_message = "Use the reviewed persona-gpu-01 g6.xlarge baseline with public IPv4."
  }
  # EIP가 management 목적지의 주소 안정성만 해결하게 한다. 이 단정은 보안 그룹을
  # 완화하지 않으며, SSH /32 제한은 closed_ingress_baseline의 별도 규칙으로 유지된다.
  assert {
    # association의 instance ID는 plan 단계에서 아직 확정되지 않는다. EIP를 VPC에
    # 만들겠다는 선언 자체는 이 단계에서 검증하고, 실제 대상은 apply 전 plan에서
    # aws_eip_association.gpu.instance_id로 별도 검토한다.
    condition     = aws_eip.gpu.domain == "vpc"
    error_message = "Keep one VPC EIP associated with the GPU instance for stable management access."
  }
  assert {
    condition     = aws_instance.gpu.root_block_device[0].volume_type == "gp3" && aws_instance.gpu.root_block_device[0].volume_size == 100 && aws_instance.gpu.root_block_device[0].iops == 3000 && aws_instance.gpu.root_block_device[0].throughput == 125 && aws_instance.gpu.root_block_device[0].encrypted && aws_instance.gpu.metadata_options[0].http_tokens == "required"
    error_message = "Encrypted gp3 100 GiB/3000 IOPS/125 MiBps and IMDSv2 are required."
  }
  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0" && aws_subnet.gpu.cidr_block == "10.80.0.0/24"
    error_message = "Public subnet and default route must be configured."
  }
  assert {
    condition     = aws_instance.gpu.user_data == null
    error_message = "Do not place bootstrap tokens in user data."
  }
  # A guest-side shutdown must stop, not terminate: the root volume carries the model
  # cache and delete_on_termination is true, so a terminate would silently discard it.
  assert {
    condition     = aws_instance.gpu.instance_initiated_shutdown_behavior == "stop"
    error_message = "A guest shutdown must stop the instance, not terminate it and destroy the model cache."
  }
  # Pins the current choice rather than endorsing it: the root volume is deleted on
  # terminate, which is why the shutdown behaviour above and prevent_destroy both matter.
  assert {
    condition     = aws_instance.gpu.root_block_device[0].delete_on_termination
    error_message = "Root volume deletion on terminate is the reviewed baseline; changing it needs a separate cost and recovery decision."
  }
  # IMDSv2 alone is not enough. A hop limit above 1 lets a container reach the instance
  # metadata service, and metadata tags would expose instance tags to anything on the host.
  assert {
    condition     = aws_instance.gpu.metadata_options[0].http_put_response_hop_limit == 1 && aws_instance.gpu.metadata_options[0].instance_metadata_tags == "disabled"
    error_message = "Keep the metadata hop limit at 1 and instance metadata tags disabled."
  }
  # Counts the egress rules declared through local.gpu_egress_rules. Adding an entry there
  # fails this assertion, which is the point: egress is deliberately open (README) and that
  # choice should not grow quietly.
  #
  # Limit worth stating: this counts the collection, not the security group. A separate
  # `aws_vpc_security_group_egress_rule` resource declared under another name is invisible
  # here, because a test cannot enumerate resources it was not given. Declaring egress only
  # through the collection is a convention; this assertion checks the convention holds.
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.outbound) == 1
    error_message = "Egress must stay a single declared rule; add one only with a separate decision."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.outbound["all_outbound"].ip_protocol == "-1" && aws_vpc_security_group_egress_rule.outbound["all_outbound"].cidr_ipv4 == "0.0.0.0/0"
    error_message = "The baseline outbound rule stays all-protocol to 0.0.0.0/0; narrowing it is a separate decision."
  }
}

run "explicit_peer_access" {
  command = plan
  variables {
    bootstrap_ssh_cidr   = "192.0.2.1/32"
    tailscale_peer_cidrs = ["198.51.100.1/32"]
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.bootstrap_ssh[0].from_port == 22 && aws_vpc_security_group_ingress_rule.bootstrap_ssh[0].cidr_ipv4 == "192.0.2.1/32"
    error_message = "SSH must use only the explicitly configured peer."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.tailscale["198.51.100.1/32"].ip_protocol == "udp" && aws_vpc_security_group_ingress_rule.tailscale["198.51.100.1/32"].to_port == 41641
    error_message = "Tailscale ingress must be transport only."
  }
}

run "unreviewed_launch_rejected" {
  command = plan
  variables { launch_review_confirmed = false }
  expect_failures = [aws_instance.gpu]
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

run "router_disabled_when_flag_false" {
  command = plan
  # 현재 환경의 tfvars는 운영 중인 라우터를 보존하려고 true다. 이 사례에서는
  # 새 환경의 비활성 경로를 명시적으로 검증한다.
  variables {
    router_enabled            = false
    router_bootstrap_ssh_cidr = null
  }
  assert {
    condition     = length(aws_subnet.router) == 0 && length(aws_instance.router) == 0 && length(aws_route.router_internet) == 0
    error_message = "The router must not be created when router_enabled is false."
  }
}

run "router_uses_separate_subnet_without_gpu_route_change" {
  command = plan
  variables {
    router_enabled              = true
    router_bootstrap_ssh_cidr   = "192.0.2.1/32"
    router_tailscale_peer_cidrs = ["198.51.100.1/32"]
  }
  assert {
    condition     = aws_subnet.router[0].cidr_block == "10.80.1.0/24" && aws_subnet.router[0].availability_zone == "ap-northeast-2a"
    error_message = "Place the router in the next /24 of the same VPC and AZ, separate from the GPU."
  }
  assert {
    condition     = aws_instance.router[0].source_dest_check == false && aws_instance.router[0].associate_public_ip_address
    error_message = "The router must be able to forward traffic and reach Tailscale for bootstrap."
  }
  assert {
    condition     = aws_route.router_internet[0].destination_cidr_block == "0.0.0.0/0" && aws_route.internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "Keep independent router and GPU default routes."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.router_ssh[0].cidr_ipv4 == "192.0.2.1/32" && aws_vpc_security_group_ingress_rule.router_tailscale["198.51.100.1/32"].to_port == 41641
    error_message = "Router ingress must stay limited to reviewed peers."
  }
  assert {
    condition     = aws_instance.router[0].user_data == null && aws_instance.router[0].metadata_options[0].http_tokens == "required"
    error_message = "Do not put Tailscale credentials in user data; require IMDSv2."
  }
}

run "router_worldwide_ssh_rejected" {
  command = plan
  variables { router_bootstrap_ssh_cidr = "0.0.0.0/0" }
  expect_failures = [var.router_bootstrap_ssh_cidr]
}

run "site_probe_disabled_without_opt_in" {
  command = plan
  variables {
    router_enabled     = true
    site_probe_enabled = false
  }
  assert {
    condition     = length(aws_instance.site_probe) == 0 && length(aws_security_group.site_probe) == 0 && length(aws_route.site_probe_home) == 0 && length(aws_vpc_security_group_ingress_rule.router_site_probe_icmp) == 0 && length(aws_vpc_security_group_egress_rule.site_probe_home_http) == 0 && length(aws_vpc_security_group_ingress_rule.router_site_probe_http) == 0 && length(aws_vpc_security_group_ingress_rule.router_gpu_probe_http) == 0
    error_message = "The private probe must not be created without explicit opt-in."
  }
}

run "site_probe_requires_router" {
  command = plan
  variables {
    router_enabled            = false
    router_bootstrap_ssh_cidr = null
    site_probe_enabled        = true
  }
  assert {
    condition     = length(aws_instance.site_probe) == 0 && length(aws_route.site_probe_home) == 0
    error_message = "Do not create the probe or its route without the dedicated router."
  }
}

run "site_probe_private_and_router_only_ssh" {
  command = plan
  variables {
    router_enabled     = true
    site_probe_enabled = true
  }
  assert {
    condition     = length(aws_instance.site_probe) == 1 && !aws_instance.site_probe[0].associate_public_ip_address && aws_instance.site_probe[0].instance_type == "t3.micro"
    error_message = "Create one private t3.micro probe without a public IPv4 address."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.site_probe_ssh[0].ip_protocol == "tcp" && aws_vpc_security_group_ingress_rule.site_probe_ssh[0].from_port == 22 && aws_vpc_security_group_ingress_rule.site_probe_ssh[0].to_port == 22 && aws_vpc_security_group_ingress_rule.site_probe_ssh[0].cidr_ipv4 == null
    error_message = "Probe SSH must be limited to the router security group, not a CIDR."
  }
  assert {
    condition     = aws_instance.site_probe[0].user_data == null && aws_instance.site_probe[0].metadata_options[0].http_tokens == "required"
    error_message = "Do not place credentials in user data; require IMDSv2."
  }
  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0" && aws_route.router_internet[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "The probe stage must preserve both existing route tables."
  }
  assert {
    # mock provider의 plan에서는 route table ID가 아직 확정되지 않는다.
    # 이 테스트는 목적지 범위를 고정하고, 실제 ENI 연결은 계정 plan에서 확인한다.
    condition     = aws_route.site_probe_home[0].destination_cidr_block == "172.29.250.2/32"
    error_message = "Route only the isolated home probe through the existing GPU subnet route table."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.site_probe_home_icmp[0].cidr_ipv4 == "172.29.250.2/32" && aws_vpc_security_group_ingress_rule.site_probe_home_icmp[0].cidr_ipv4 == "172.29.250.2/32"
    error_message = "Probe ICMP rules must be limited to the isolated home address."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.router_site_probe_icmp[0].ip_protocol == "icmp" && aws_vpc_security_group_ingress_rule.router_site_probe_icmp[0].from_port == -1 && aws_vpc_security_group_ingress_rule.router_site_probe_icmp[0].to_port == -1
    error_message = "The router may receive forwarded ICMP from the probe only."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.site_probe_home_http[0].cidr_ipv4 == "172.29.250.2/32" && aws_vpc_security_group_egress_rule.site_probe_home_http[0].ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.site_probe_home_http[0].from_port == 8080 && aws_vpc_security_group_egress_rule.site_probe_home_http[0].to_port == 8080
    error_message = "Probe HTTP egress must target only the isolated home address on TCP 8080."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.router_site_probe_http[0].ip_protocol == "tcp" && aws_vpc_security_group_ingress_rule.router_site_probe_http[0].from_port == 8080 && aws_vpc_security_group_ingress_rule.router_site_probe_http[0].to_port == 8080
    error_message = "The router may receive forwarded HTTP from the probe only on TCP 8080."
  }
  assert {
    # mock provider의 plan에서는 GPU 사설 IP가 확정되지 않는다. CIDR의 실제 값은
    # AWS refresh plan에서 확인하고, 여기서는 추가 규칙의 개수와 포트만 고정한다.
    condition     = length(aws_vpc_security_group_ingress_rule.router_gpu_probe_http) == 1 && aws_vpc_security_group_ingress_rule.router_gpu_probe_http[0].ip_protocol == "tcp" && aws_vpc_security_group_ingress_rule.router_gpu_probe_http[0].from_port == 8080 && aws_vpc_security_group_ingress_rule.router_gpu_probe_http[0].to_port == 8080
    error_message = "GPU A/B HTTP ingress must remain one TCP 8080 rule."
  }
}
