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

resource "aws_vpc_security_group_egress_rule" "outbound" {
  security_group_id = aws_security_group.gpu.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Initial downloads, updates and Tailscale connectivity; egress is not filtered in v1"
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
  instance_type                        = "g6.xlarge"
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
    volume_size           = 100
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
  tags       = { Name = "persona-gpu-01" }
}
