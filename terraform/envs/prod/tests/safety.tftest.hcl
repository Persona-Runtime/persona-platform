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
    condition     = aws_instance.gpu.instance_type == "g6.xlarge" && aws_instance.gpu.tags["Name"] == "persona-gpu-01" && aws_instance.gpu.associate_public_ip_address
    error_message = "Use the reviewed persona-gpu-01 g6.xlarge baseline with public IPv4."
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
