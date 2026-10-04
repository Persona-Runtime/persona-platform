# 시험 EC2는 GPU와 같은 서브넷에 두되 공인 IP와 Tailscale은 사용하지 않는다.
# 기본값은 비활성이다. GPU 서브넷의 라우트 테이블에는 홈 시험 주소 /32만 추가한다.
locals {
  site_probe_count     = var.router_enabled && var.site_probe_enabled ? 1 : 0
  home_probe_ipv4_cidr = "172.29.250.2/32"
  site_probe_http_port = 8080
}

resource "aws_security_group" "site_probe" {
  count       = local.site_probe_count
  name_prefix = "persona-site-probe-"
  description = "Private site-to-site routing test host"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "persona-site-probe-01" }
}

# 공인 SSH를 열지 않는다. 라우터를 경유한 사설 SSH만 허용한다.
resource "aws_vpc_security_group_ingress_rule" "site_probe_ssh" {
  count                        = local.site_probe_count
  security_group_id            = aws_security_group.site_probe[0].id
  referenced_security_group_id = aws_security_group.router[0].id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "SSH from the dedicated AWS router only"
}

resource "aws_instance" "site_probe" {
  count                                = local.site_probe_count
  ami                                  = data.aws_ami.ubuntu.id
  instance_type                        = "t3.micro"
  subnet_id                            = aws_subnet.gpu.id
  associate_public_ip_address          = false
  vpc_security_group_ids               = [aws_security_group.site_probe[0].id]
  key_name                             = aws_key_pair.bootstrap.key_name
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "persona-site-probe-01" }
}

# 시험 EC2에서 홈 시험 주소로 나가는 ICMP와 반대 방향의 요청만 연다.
# SSH 이외의 기존 서비스 주소나 전체 홈 LAN으로 범위를 넓히지 않는다.
resource "aws_vpc_security_group_egress_rule" "site_probe_home_icmp" {
  count             = local.site_probe_count
  security_group_id = aws_security_group.site_probe[0].id
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = local.home_probe_ipv4_cidr
  description       = "ICMP to the isolated home probe only"
}

resource "aws_vpc_security_group_ingress_rule" "site_probe_home_icmp" {
  count             = local.site_probe_count
  security_group_id = aws_security_group.site_probe[0].id
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = local.home_probe_ipv4_cidr
  description       = "ICMP from the isolated home probe only"
}

# AWS 라우터 ENI는 시험 EC2에서 홈으로 전달되는 패킷을 받는다.
# 중간 라우터를 지나는 트래픽은 보안 그룹 참조만으로 허용되지 않으므로
# 실제 시험 EC2의 사설 IP 한 개로 출발지를 제한한다.
resource "aws_vpc_security_group_ingress_rule" "router_site_probe_icmp" {
  count             = local.site_probe_count
  security_group_id = aws_security_group.router[0].id
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = "${aws_instance.site_probe[0].private_ip}/32"
  description       = "Forward ICMP from the isolated AWS probe only"
}

# HTTP는 AWS 시험 EC2가 요청을 시작하는 한 방향만 연다. 응답은 보안 그룹의
# 연결 추적을 통해 돌아오므로 시험 EC2의 TCP 인바운드는 추가하지 않는다.
resource "aws_vpc_security_group_egress_rule" "site_probe_home_http" {
  count             = local.site_probe_count
  security_group_id = aws_security_group.site_probe[0].id
  ip_protocol       = "tcp"
  from_port         = local.site_probe_http_port
  to_port           = local.site_probe_http_port
  cidr_ipv4         = local.home_probe_ipv4_cidr
  description       = "HTTP to the isolated home probe only"
}

# 라우터 ENI가 전달된 패킷을 받도록 시험 EC2의 사설 IP 한 개만 허용한다.
# 중간 라우터를 거치는 트래픽이므로 보안 그룹 참조 대신 실제 출발지 IP를 쓴다.
resource "aws_vpc_security_group_ingress_rule" "router_site_probe_http" {
  count             = local.site_probe_count
  security_group_id = aws_security_group.router[0].id
  ip_protocol       = "tcp"
  from_port         = local.site_probe_http_port
  to_port           = local.site_probe_http_port
  cidr_ipv4         = "${aws_instance.site_probe[0].private_ip}/32"
  description       = "Forward HTTP from the isolated AWS probe only"
}

# 동일 GPU에서 직접 경로와 전용 라우터 경로를 비교할 때 필요한 인바운드다.
# GPU의 사설 IP 한 개와 시험 HTTP 포트로 제한하며 이 규칙 자체는 경로를 바꾸지 않는다.
resource "aws_vpc_security_group_ingress_rule" "router_gpu_probe_http" {
  count             = local.site_probe_count
  security_group_id = aws_security_group.router[0].id
  ip_protocol       = "tcp"
  from_port         = local.site_probe_http_port
  to_port           = local.site_probe_http_port
  cidr_ipv4         = "${aws_instance.gpu.private_ip}/32"
  description       = "Forward GPU HTTP to the isolated home probe only"
}

# GPU와 같은 서브넷의 라우트 테이블을 사용하지만 목적지는 시험 주소 /32뿐이다.
# 라우터가 꺼지면 이 경로는 실패하므로 실제 홈 LAN이나 Kubernetes 경로는 넣지 않는다.
resource "aws_route" "site_probe_home" {
  count                  = local.site_probe_count
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = local.home_probe_ipv4_cidr
  network_interface_id   = aws_instance.router[0].primary_network_interface_id
}
