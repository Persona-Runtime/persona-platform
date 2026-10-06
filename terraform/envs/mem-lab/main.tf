locals {
  # MEM-01 실험의 기준선 세 값. 인스턴스 타입이 바뀌면 압박 주입 값과 관측 결과가 함께
  # 무효가 되므로 변수로 두지 않는다.
  #
  # 왜 4 GiB(t3a.medium)인가: 이 노드의 목적은 kubelet이 MemoryPressure를 선언하고 축출
  # 순서를 드러내게 만드는 것이다. lab consumer가 64Mi 단위로 56단계까지(3584Mi, limit
  # 3712Mi) 올라가도록 이미 선언돼 있어, 8 GiB 노드에서는 상한까지 올라가도 압박이 생기지
  # 않고 "축출이 없었다"가 아니라 **압박 주입 실패**로 끝난다. 크기를 바꾸려면 consumer
  # 단계 수와 함께 바꾼다.
  mem_node_name       = "persona-mem-01"
  mem_instance_type   = "t3a.medium"
  mem_root_volume_gib = 30

  # 아웃바운드 규칙을 한 곳에 모은다. 새 규칙은 이 map에 항목을 더하는 방식이 되고,
  # tests/safety.tftest.hcl이 항목 수를 단정하므로 조용히 늘어나지 않는다.
  mem_egress_rules = {
    all_outbound = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
      description = "Package installs, Tailscale coordination and DERP; egress is not filtered in this lab"
    }
  }
}

# ── VPC CIDR 겹침 게이트 ──────────────────────────────────────────────────────
#
# Terraform 1.14에는 두 CIDR의 겹침을 판정하는 함수가 없다(`cidrcontains`는 존재하지 않고,
# `cidrsubnets`·`cidrhost`는 한 블록 안을 계산할 뿐이다). 그래서 각 블록을 [시작, 시작+크기)
# 정수 구간으로 바꿔 직접 비교한다. 두 구간은 `a_start < b_end && b_start < a_end`일 때,
# 그리고 그때만 겹친다.
#
# `cidrhost(c, 0)`을 쓰는 이유: prefix 뒤에 호스트 비트가 남은 표기(예: 10.244.5.0/16)를
# 블록의 첫 주소로 정규화한다. 입력을 그대로 쪼개면 그런 표기에서 시작 주소를 잘못 읽는다.
#
# **이 게이트가 증명하는 것과 증명하지 않는 것**
# - 증명한다: 선언된 `vpc_cidr`가 `reserved_cidrs`의 어떤 항목과도 주소 구간이 겹치지 않는다.
# - 증명하지 않는다: 실제 라우팅이 성립한다는 것. 이것은 **입력된 목록**과의 비교이며 tailnet
#   광고 경로나 홈 라우터의 실제 테이블을 읽지 않는다. 목록에서 빠진 경로와의 충돌은 잡지
#   못한다. 그래서 `reserved_cidrs`를 필수 변수로 두고 네 항목을 모두 받는다.
locals {
  # vpc_cidr와 reserved_cidrs를 한 번에 정수 변환한다. map이라 중복 항목은 자연히 합쳐진다.
  cidr_candidates = distinct(concat([var.vpc_cidr], var.reserved_cidrs))

  cidr_start = {
    for c in local.cidr_candidates :
    c => sum([for i, octet in split(".", cidrhost(c, 0)) : tonumber(octet) * pow(256, 3 - i)])
  }

  cidr_size = {
    for c in local.cidr_candidates :
    c => pow(2, 32 - tonumber(split("/", c)[1]))
  }

  overlapping_reserved = [
    for c in var.reserved_cidrs : c
    if local.cidr_start[var.vpc_cidr] < local.cidr_start[c] + local.cidr_size[c]
    && local.cidr_start[c] < local.cidr_start[var.vpc_cidr] + local.cidr_size[var.vpc_cidr]
  ]
}

data "aws_ami" "ubuntu" {
  owners = ["099720109477"] # Canonical, commercial AWS partition.

  # 이 data source는 "최신 AMI 찾기"가 아니다. 이미 고정한 var.ami_id가 정말로 Canonical의
  # Ubuntu 24.04 amd64 서버 이미지인지 확인한다. 다른 이미지를 넣으면 filter가 비어 계획이
  # 실패한다. amd64 강제는 lab Pod가 linux/amd64 전용이라는 전제와 직접 연결된다.
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
  tags                 = { Name = "persona-mem-lab" }

  # 겹침 판정을 VPC에 붙인다. CIDR을 선언하는 자원이 여기이고, 인스턴스보다 먼저 평가되어
  # 잘못된 주소 계획이 plan 단계에서 멈춘다.
  lifecycle {
    precondition {
      condition = length(local.overlapping_reserved) == 0
      error_message = format(
        "vpc_cidr %s overlaps reserved ranges: %s. Pick a block outside every listed range; do not narrow reserved_cidrs to pass this gate.",
        var.vpc_cidr,
        join(", ", local.overlapping_reserved),
      )
    }
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "persona-mem-lab" }
}

resource "aws_subnet" "mem" {
  vpc_id            = aws_vpc.lab.id
  availability_zone = var.availability_zone
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  # 인스턴스에서만 선택적으로 공인 IP를 붙인다. subnet 기본값으로 켜 두면 이 subnet에
  # 나중에 추가되는 자원까지 자동으로 공인 주소를 갖는다.
  map_public_ip_on_launch = false
  tags                    = { Name = "persona-mem-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "persona-mem-public" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "mem" {
  subnet_id      = aws_subnet.mem.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "mem" {
  name_prefix = "persona-mem-"
  description = "No public Kubernetes ingress; optional bootstrap SSH and Tailscale transport only"
  vpc_id      = aws_vpc.lab.id
  tags        = { Name = "persona-mem" }
}

# Egress rules are declared only through this collection, so a test can count them.
#
# Same limit as envs/prod: `terraform test` can assert the size of this map, but it cannot
# enumerate resources it was not told about, so a separately named egress rule stays invisible
# to it. The collection is a convention and the test checks the convention holds.
resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each = local.mem_egress_rules

  security_group_id = aws_security_group.mem.id
  ip_protocol       = each.value.ip_protocol
  cidr_ipv4         = each.value.cidr_ipv4
  description       = each.value.description
}

# ── Inbound ──────────────────────────────────────────────────────────────────
#
# 아래 두 규칙이 이 환경에 선언된 inbound의 **전부**다. 기본값으로는 둘 다 0개가 되어
# public inbound가 완전히 닫힌다.
#
# Kubernetes 포트(API 6443, kubelet 10250, Cilium VXLAN 8472·health 4240, NodePort
# 30000-32767)를 여는 규칙은 **선언하지 않으며, 변수로도 열 수 없다.** 그 트래픽은 tailnet
# 안에서만 흐른다 — 노드가 tailnet에 붙으면 WireGuard 터널 안에서 오가므로 VPC security
# group에 구멍을 낼 이유가 없다. 공인 경계에 6443을 열면 클러스터 API가 인터넷에 노출된다.
# scripts/test-mem-lab-negative.sh가 이 사실을 두 방향으로 검사한다.
resource "aws_vpc_security_group_ingress_rule" "bootstrap_ssh" {
  count             = var.bootstrap_ssh_cidr == null ? 0 : 1
  security_group_id = aws_security_group.mem.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.bootstrap_ssh_cidr
  description       = "Temporary administrator access; remove after verified tailnet access"
}

resource "aws_vpc_security_group_ingress_rule" "tailscale" {
  for_each          = var.tailscale_peer_cidrs
  security_group_id = aws_security_group.mem.id
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  cidr_ipv4         = each.value
  description       = "Encrypted Tailscale transport from a reviewed public peer address"
}

resource "aws_key_pair" "bootstrap" {
  key_name_prefix = "persona-mem-"
  public_key      = trimspace(var.ssh_public_key)
}

resource "aws_instance" "mem" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = local.mem_instance_type
  subnet_id     = aws_subnet.mem.id
  # 공인 IP는 **송신 경로**를 위한 것이다(NAT gateway를 두지 않는다 — 시간당 비용이 이 실험의
  # 인스턴스 비용을 넘는다). 위 security group이 inbound를 전부 막으므로 수신 경로가 아니다.
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.mem.id]
  key_name                    = aws_key_pair.bootstrap.key_name
  # 게스트에서 shutdown이 일어나도 종료하지 않는다. 실험 중 OOM·압박으로 노드가 내려갈 때
  # 인스턴스가 사라지면 kubelet 로그와 journal을 잃고 그 회차를 분석할 수 없다.
  instance_initiated_shutdown_behavior = "stop"

  # burstable 인스턴스의 CPU credit 정책. unlimited면 credit이 바닥날 때 초과 요금이 자동으로
  # 붙어 예상하지 못한 비용이 생긴다. standard는 credit이 없으면 성능이 떨어질 뿐이고, 이
  # 실험의 병목은 CPU가 아니라 메모리이므로 그 편이 맞다.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # hop limit 1: container가 instance metadata service에 도달하지 못하게 한다. lab Pod는
    # 일부러 메모리를 소진시키는 워크로드라, 그 Pod에서 metadata를 읽을 수 있게 둘 이유가 없다.
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = local.mem_root_volume_gib
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  # user_data를 두지 않는다. user_data는 IMDS로 평문 조회되고 Terraform state에도 남으므로
  # tailnet auth key나 kubeadm join token을 넣을 자리가 아니다. OS 준비는
  # ansible/mem-lab-worker가 SSH로 한다.

  lifecycle {
    # **prevent_destroy를 일부러 두지 않는다** (envs/prod의 GPU 인스턴스와 다른 점이다).
    # 이 노드는 실험이 끝나면 제거하는 것이 정상 수명주기이고, 그 마지막 단계가
    # `terraform destroy`다(README "종료 절차"). prevent_destroy는 바로 그 단계를 막아,
    # 절차를 따르는 사람이 코드를 고쳐야 destroy할 수 있는 상태를 만든다. 실수로 지우는 것을
    # 막는 장치는 여기가 아니라 종료 절차의 "lab Pod 없음 확인" 단계다.
    precondition {
      condition     = var.launch_review_confirmed
      error_message = "Launch review is incomplete. Confirm AZ offering for t3a.medium, hourly cost, reserved_cidrs read from the live cluster, bootstrap access and the teardown procedure before planning a launch."
    }
  }

  depends_on = [aws_route.internet, aws_route_table_association.mem]
  tags       = { Name = local.mem_node_name }
}
