# AWS site-to-site 라우터 — 생성 기록과 격리 경로 검증

2026-10-01 저장한 Terraform plan을 적용해 AWS 라우터 EC2와 전용 네트워크 자원
8개를 생성했다. 기존 GPU·VPC·EIP는 변경하지 않았다. 홈 Proxmox VM 105도
별도로 생성하고 Ubuntu·Tailscale을 설치했다. 이후 두 라우터 뒤의 격리된
시험 주소 간 양방향 통신과 AWS 서브넷의 비공개 시험 EC2 경로를 확인했다.
**Kubernetes Node InternalIP와 실제 GPU·Pod 경로는 이전하지 않았다.**

## 현재 확인된 경계

- 이 worktree의 로컬 Terraform state가 GPU VPC·인스턴스·EIP와 새 라우터를
  관리한다. 생성 전 실제 AWS refresh plan은 기존 자원 변경 없음으로 확인했다.
  VPC는 `10.80.0.0/16`, GPU 서브넷은 `10.80.0.0/24`, AZ는
  `ap-northeast-2a`다. 생성 후 EC2 `running`, VPC 내부 주소, 공개 주소,
  `SourceDestCheck=false`와 관리자 SSH 접속을 확인했다. 시험 주소에 한정한 패킷
  전달은 검증했지만 실제 GPU·Kubernetes 트래픽은 검증하지 않았다.
- 코드의 `router_enabled=false`는 새 환경의 기본값이다. **이미 라우터를 만든 현재
  환경에서는 비공개 `terraform.tfvars`의 `router_enabled=true`를 유지한다.**
  false로 바꾸면 라우터 삭제 계획이 나오고 `prevent_destroy`로 막힌다.
- 라우터는 같은 VPC·AZ의 별도 `10.80.1.0/24` 서브넷과 **별도 라우트 테이블**에
  둔다. 라우터 테이블에는 인터넷 기본 경로만 있다. 기존 GPU 서브넷의 라우트
  테이블에는 실제 홈 LAN 경로를 아직 추가하지 않았다. 시험용
  `172.29.250.2/32` 경로만 라우터 ENI로 향한다.
- 생성한 인스턴스는 `t3.small`, 암호화 gp3 16 GiB, 공개 IPv4 한 개다. 이는
  경로 검증용 크기이며 VXLAN 처리량을 보장하지 않는다. EC2·EBS·공개 IPv4·전송
  비용이 발생한다.
- 라우터의 `source_dest_check=false`는 양방향 패킷 전달에 필요하다.
  현재는 시험 EC2 `10.80.0.58`과 홈 시험 주소 `172.29.250.2` 사이의
  `/32` 경로만 전달한다. 실서비스의 라우터로 전환한 것은 아니다.

## 생성 시 확인한 중단 조건과 남은 조치

1. 생성 전 `terraform.tfstate`와 백업을 worktree 밖에 보존했고, 생성 후 state도
   별도로 백업해 원본과 일치함을 확인했다. state와 plan에는 민감한 값이 들어갈 수
   있으므로 Git·채팅에 올리지 않는다.
2. AWS 계정·리전을 확인하고 `terraform plan`에서 기존 VPC·GPU·EIP 변경이 없음을
   확인했다. 새 라우터의 실행 상태와 관리자 SSH 접속을 확인했다.
3. 새 `10.80.1.0/24` 서브넷을 `ap-northeast-2a`에 생성했다. 인스턴스 중지 시
   컴퓨팅 과금은 멈추지만 EBS와 공인 IPv4 관련 비용·주소 변경을 확인한다.
4. Tailscale 인증 키를 `tfvars`, `user_data`, state나 plan에 넣지 않는다.
   현재 관리자 공인 IPv4 `/32`만 SSH로 임시 허용했다. 공인 주소가 바뀌면 SSH가
   막히므로 새 주소로 계획을 갱신한다. Tailnet SSH 검증 전에는 이 규칙을 제거하지 않는다.

## 검증과 이후 단계

- 먼저 `terraform fmt -check -recursive`, `terraform validate`, mock provider의
  `terraform test`를 실행한다. 이것은 실제 AWS 검증이 아니다.
- 실제 AWS plan에서 라우터 관련 8개 생성과 기존 자원 변경 없음 확인 후,
  사용자의 승인으로 저장된 plan을 적용했다.
- AWS 라우터에 Tailscale 1.102.4를 설치하고 Tailnet 가입을 확인했다.
  처음에는 경로를 광고하지 않았고, 현재는 시험 주소
  `172.29.251.2/32`, `10.80.0.58/32`만 광고한다. GPU의 VPC 사설 주소는
  계속 `ens5`·VPC 게이트웨이로 향한다. 실제 GPU·Pod 경로와 UDP 8472 검증은 남는다.
- 홈 Proxmox에 Kubernetes 밖의 VM 105(`persona-home-router-01`)를 2 vCPU,
  2 GiB RAM, 16 GiB `local-lvm` 디스크, `vmbr0` NIC로 생성하고 Ubuntu Server와
  Tailscale을 설치했다. LAN 주소는 `192.168.50.203`이다.
- 홈 `k8s-worker1`에서 AWS 라우터 Tailnet 주소로 `tailscale ping`을 실행했고,
  초기 DERP(tok) 응답 후 공인 UDP endpoint를 통한 direct 응답을 확인했다.
  이는 연결 발견 결과이며 장시간 무손실이나 실제 서브넷 전달의 증거는 아니다.
- 격리 시험망은 홈↔AWS 방향별 ICMP 100/100 응답을 확인했다. 추가로 시험 EC2에서
  홈 시험 주소로 100/100(평균 4.225ms), 홈 시험 주소에서 시험 EC2로
  100/100(평균 4.708ms) 응답했다. AWS 라우터의 Tailscale 상태에서는 홈 라우터와
  `direct`를 관측했다. 적용 후 Terraform refresh plan도 변경 없음이다.
  시험 EC2에서 1200바이트 ICMP payload·DF 조건도 100/100 응답, 평균 4.617ms였다.
  이 크기의 패킷 통과만 확인한 것이며 실제 GPU·Pod의 VXLAN/HTTP 통신 안정성이나
  기존 경로 대비 개선을 입증하지 않는다.
- 시험 EC2에서 홈 시험 namespace의 임시 HTTP 서버에 GET 100회를 보냈고
  `200` 응답 100회, 실패 0회, 평균 0.0090초·최대 0.0242초였다. 작은 정적 응답의
  TCP 연결 시험이며 LLM 서비스 지연이나 장기 안정성 측정은 아니다.
- GPU 노드의 직접 Tailscale 경로에서 같은 홈 시험 주소로 HTTP GET 100회를 보내
  `200` 응답 100회, 실패 0회, 평균 0.0082초·최대 0.0140초를 기록했다. 앞선
  0.0090초는 **다른 시험 EC2**에서 측정했으므로 A/B 지연 차이로 계산하지 않는다.
  동일 GPU의 라우터 경로를 측정하려면 GPU `/32`의 라우터 보안 그룹 허용,
  홈에서 GPU 사설 주소로 돌아오는 경로, GPU의 시험 목적지 `/32`에 한정한 임시
  정책 라우팅을 모두 확인해야 한다. Kubernetes Pod 경로 전환은 수행하지 않았다.
- GPU `10.80.0.96/32`에서 라우터로 전달되는 TCP 8080만 허용하는 보안 그룹
  규칙 1개를 Terraform 저장 plan으로 적용했다. 적용 결과는 추가 1·변경 0·삭제 0이다.
  적용 후 `site_probe_enabled=true`를 명시한 AWS refresh plan은 변경 없음이었다.
  이 규칙만으로 GPU의 현재 직접 Tailscale 경로나 홈 반환 경로가 바뀌지는 않는다.
  `site_probe_enabled`의 기본값은 false이므로 **이 환경에서 후속 plan·apply에는
  반드시 true를 명시**한다. 생략한 plan은 기존 시험 EC2와 경로 등 9개 삭제를
  제안하므로 적용하지 않는다.
- 홈 라우터의 `10.80.0.96` 반환 경로가 `tailscale0`임을 확인한 뒤, GPU의 시험
  목적지 `172.29.250.2/32`에만 우선순위 2500 정책 규칙을 적용해 AWS 라우터
  경로를 측정했다. GPU의 VPC NIC `enp39s0`, 출발지 `10.80.0.96`에서 HTTP
  GET 100/100 성공, 평균 0.0097초·최대 0.0545초였다. 규칙 제거 후 목적지가
  `tailscale0`, 출발지 `100.72.2.126`으로 돌아온 것을 확인하고 직접 경로를
  다시 측정해 100/100 성공, 평균 0.0666초·최대 1.1074초를 기록했다.
  직접 경로는 앞선 0.0082초 결과와 큰 차이가 있으므로, 한 번의 A/B 결과만으로
  전용 라우터의 지속적인 성능 우위를 주장하지 않는다. TCP 연결 지연과 서버
  응답 지연을 나누고 경로 변동 여부를 확인한 뒤 재현성을 판단한다.
- 직접 경로를 추가로 100회 재측정했을 때는 100/100 성공, 평균 0.0081초,
  100ms 이상 지연 0회였다. 직전의 평균 0.0666초 급증은 즉시 재현되지 않았다.
  이어서 같은 GPU에서 라우터 경로를 다시 측정해 100/100 성공, 평균 0.0089초·
  최대 0.0131초·100ms 이상 0회를 기록했다. 측정 시 목적지 경로는 `enp39s0`,
  임시 규칙 제거 후에는 `tailscale0`로 복구된 것을 확인했다. 인접한 두 100회
  측정에서는 라우터 경로의 평균이 직접 경로보다 0.8ms 높았지만, 이를 고정
  오버헤드나 장기 안정성 차이로 해석하지 않는다. 이 시험은 두 Tailscale 경로를
  비교했으며 Cilium VXLAN 이중 캡슐화 비용을 분리해 측정하지 않았다.
- 실서비스 경로 검증 전에는 Kubernetes Node InternalIP, control-plane API 주소,
  기존 `tailscale serve`를 변경하지 않는다.
- 향후 GPU 서브넷의 홈 LAN 경로를 라우터 ENI로 보내는 작업은 별도 변경이다.
  그때 GPU→홈 패킷을 허용하는 라우터 보안 그룹 규칙과 홈→AWS 반환 경로를 함께
  검토한다. 한쪽 경로만 추가하면 통신 성공으로 보지 않는다.
