locals {
  # 첫 GPU 실험은 장비 차이까지 변수로 만들지 않는다. 이 세 값이 바뀌면 기존
  # 성능 기준선과 비용 전제가 함께 달라지므로 별도 결정과 새 측정이 필요하다.
  gpu_node_name       = "persona-gpu-01"
  gpu_instance_type   = "g6.xlarge"
  gpu_root_volume_gib = 100

  # 아웃바운드 규칙을 한 곳에 모은다. 새 규칙은 이 map에 항목을 더하는 방식이 되고,
  # tests/safety.tftest.hcl이 항목 수를 단정하므로 조용히 늘어나지 않는다.
  # 지금은 전체 허용 하나다 — README의 "외부 송신 통제는 하지 않는 초기 정책"이 그것이다.
  gpu_egress_rules = {
    all_outbound = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
      description = "Initial downloads, updates and Tailscale connectivity; egress is not filtered in v1"
    }
  }
}

data "aws_ami" "ubuntu" {
  owners = ["099720109477"] # Canonical, commercial AWS partition.

  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "persona-gpu-lab" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "persona-gpu-lab" }
}

resource "aws_subnet" "gpu" {
  vpc_id                  = aws_vpc.lab.id
  availability_zone       = var.availability_zone
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  map_public_ip_on_launch = false # Opt in only on the GPU instance.
  tags                    = { Name = "persona-gpu-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "persona-gpu-public" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "gpu" {
  subnet_id      = aws_subnet.gpu.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "gpu" {
  name_prefix = "persona-gpu-"
  description = "No public application ingress; optional bootstrap SSH and Tailscale transport only"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "persona-gpu" }
}

# Egress rules are declared only through this collection, so a test can count them.
#
# What the count does and does not cover: `terraform test` can assert the size of this map,
# so a rule added here is caught. It cannot enumerate resources it was not told about, so a
# separate `aws_vpc_security_group_egress_rule` declared elsewhere stays invisible to it.
# The collection is therefore a convention and the test checks that the convention holds --
# it is not proof that the security group has exactly one egress rule.
resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each = local.gpu_egress_rules

  security_group_id = aws_security_group.gpu.id
  ip_protocol       = each.value.ip_protocol
  cidr_ipv4         = each.value.cidr_ipv4
  description       = each.value.description
}

resource "aws_vpc_security_group_ingress_rule" "bootstrap_ssh" {
  count             = var.bootstrap_ssh_cidr == null ? 0 : 1
  security_group_id = aws_security_group.gpu.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.bootstrap_ssh_cidr
  description       = "Temporary administrator access; remove after verified tailnet access"
}

resource "aws_vpc_security_group_ingress_rule" "tailscale" {
  for_each          = var.tailscale_peer_cidrs
  security_group_id = aws_security_group.gpu.id
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  cidr_ipv4         = each.value
  description       = "Encrypted Tailscale transport from a reviewed public peer address"
}

resource "aws_key_pair" "bootstrap" {
  key_name_prefix = "persona-gpu-"
  public_key      = trimspace(var.ssh_public_key)
}

resource "aws_instance" "gpu" {
  ami                                  = data.aws_ami.ubuntu.id
  instance_type                        = local.gpu_instance_type
  subnet_id                            = aws_subnet.gpu.id
  associate_public_ip_address          = true
  vpc_security_group_ids               = [aws_security_group.gpu.id]
  key_name                             = aws_key_pair.bootstrap.key_name
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = local.gpu_root_volume_gib
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.launch_review_confirmed
      error_message = "Launch review is incomplete. Confirm Seoul G/VT quota >=4, AMI/AZ, route overlap, bootstrap access and cost/stop procedures before planning a launch."
    }
  }

  depends_on = [aws_route.internet, aws_route_table_association.gpu]
  tags       = { Name = local.gpu_node_name }
}
