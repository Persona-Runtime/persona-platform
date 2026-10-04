# GPU 노드와 별도 서브넷에 라우터를 둔다. 현재 GPU의 경로를 바꾸지 않고
# Tailscale site-to-site 경로를 병렬로 검증하기 위한 첫 단계다.
# 새 환경의 기본값은 false다. 이미 생성한 환경은 tfvars에서 true를 유지해야
# 다음 plan에서 라우터 삭제가 계획되지 않는다.
locals {
  router_instance_type = "t3.small"
  router_root_gib      = 16
}

resource "aws_subnet" "router" {
  count                   = var.router_enabled ? 1 : 0
  vpc_id                  = aws_vpc.lab.id
  availability_zone       = var.availability_zone
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  map_public_ip_on_launch = false
  tags                    = { Name = "persona-tailnet-router-public" }
}

# GPU 서브넷의 라우트 테이블과 분리한다. 이후 홈 LAN 경로를 GPU 쪽에 추가할 때
# 라우터 자신의 기본 경로가 함께 바뀌거나 자기 ENI로 되돌아가지 않게 하기 위해서다.
resource "aws_route_table" "router_public" {
  count  = var.router_enabled ? 1 : 0
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "persona-tailnet-router-public" }
}

resource "aws_route" "router_internet" {
  count                  = var.router_enabled ? 1 : 0
  route_table_id         = aws_route_table.router_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "router" {
  count          = var.router_enabled ? 1 : 0
  subnet_id      = aws_subnet.router[0].id
  route_table_id = aws_route_table.router_public[0].id
}

resource "aws_security_group" "router" {
  count       = var.router_enabled ? 1 : 0
  name_prefix = "persona-tailnet-router-"
  description = "Bootstrap SSH and optional Tailscale transport; no Kubernetes ingress"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "persona-tailnet-router" }
}

resource "aws_vpc_security_group_egress_rule" "router_outbound" {
  count             = var.router_enabled ? 1 : 0
  security_group_id = aws_security_group.router[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Router bootstrap and encrypted Tailscale transport"
}

resource "aws_vpc_security_group_ingress_rule" "router_ssh" {
  count             = var.router_enabled && var.router_bootstrap_ssh_cidr != null ? 1 : 0
  security_group_id = aws_security_group.router[0].id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.router_bootstrap_ssh_cidr
  description       = "Temporary administrator SSH from one reviewed public IPv4"
}

resource "aws_vpc_security_group_ingress_rule" "router_tailscale" {
  for_each          = var.router_enabled ? var.router_tailscale_peer_cidrs : toset([])
  security_group_id = aws_security_group.router[0].id
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  cidr_ipv4         = each.value
  description       = "Optional encrypted Tailscale transport from reviewed public peer"
}

resource "aws_instance" "router" {
  count                                = var.router_enabled ? 1 : 0
  ami                                  = data.aws_ami.ubuntu.id
  instance_type                        = local.router_instance_type
  subnet_id                            = aws_subnet.router[0].id
  associate_public_ip_address          = true
  source_dest_check                    = false
  vpc_security_group_ids               = [aws_security_group.router[0].id]
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
    volume_size           = local.router_root_gib
    encrypted             = true
    delete_on_termination = true
  }

  # 라우터는 경로가 붙으면 홈↔AWS 통신의 중간 지점이 된다. 교체·삭제는
  # 별도 전환 절차 없이는 허용하지 않는다. 중지는 과금만 줄이며 경로를 복구하지 않는다.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_route.router_internet, aws_route_table_association.router]
  tags       = { Name = "persona-tailnet-router-01" }
}
