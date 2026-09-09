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
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.bootstrap_ssh) == 0 && length(aws_vpc_security_group_ingress_rule.tailscale) == 0
    error_message = "No inbound access is permitted without explicit peer configuration."
  }
  assert {
    condition     = aws_instance.gpu.instance_type == "g6.xlarge" && aws_instance.gpu.associate_public_ip_address
    error_message = "Use one g6.xlarge with public IPv4."
  }
  assert {
    condition     = aws_instance.gpu.root_block_device[0].encrypted && aws_instance.gpu.root_block_device[0].volume_size == 100 && aws_instance.gpu.metadata_options[0].http_tokens == "required"
    error_message = "Encrypted 100 GiB disk and IMDSv2 are required."
  }
  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0" && aws_subnet.gpu.cidr_block == "10.80.0.0/24"
    error_message = "Public subnet and default route must be configured."
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
