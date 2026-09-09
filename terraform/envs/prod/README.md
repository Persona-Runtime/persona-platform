# AWS GPU 랩 기반 — 생성 전 준비

2026-09-09: Terraform 작성 단계. AWS 리소스 생성·실제 plan·K8s 조인 완료가 아니다.
기존 `envs/prod` 경로를 사용하지만 상용 HA 환경이 아닌 단일 GPU 실험 환경이다.

## 만드는 범위

- 서울 전용 VPC, 퍼블릭 서브넷 하나(/16 VPC의 첫 /24), Internet Gateway, 기본 경로.
- On-Demand `g6.xlarge` 한 대(L4 24GB), 암호화 gp3 루트 디스크 100 GiB.
- EC2에만 자동 할당 퍼블릭 IPv4. NAT Gateway, EIP, Load Balancer는 만들지 않는다.
- IMDSv2 필수, hop limit 1. AWS API가 필요 없는 호스트이므로 instance IAM role/profile은 만들지 않는다.
- 초기 SSH용 공개 키만 등록. 개인 키·AWS 키·Tailscale 인증 키·kubeadm 토큰은 코드/state/user-data에 넣지 않는다.
- SSH는 기본 닫힘. 최초 접속용 관리자 공인 IPv4 `/32`를 명시하면 TCP 22만 임시 허용한다.
- UDP 41641은 선택한 Tailscale 피어의 **공인 IPv4 `/32`**에만 선택적으로 허용한다. 기본 목록은 비어 있다.
- vLLM 8000, Kubernetes API 6443, kubelet 10250, VXLAN 8472, NodePort 등은 공개 인바운드에 추가하지 않는다.
- 아웃바운드는 IPv4 전체 허용이다. 다운로드·Tailscale 연결을 단순하게 하는 대신 외부 송신 통제는 하지 않는 초기 정책이다.

GPU 드라이버, containerd, Tailscale, kubelet, Cilium 설치 및 노드 조인, vLLM 배포는 **다음 단계**다.
기본 Ubuntu AMI만으로 GPU 워커가 완성되는 것은 아니다. SSM 접속 역시 이번 구성에 포함되지 않는다.
`bootstrap_ssh_cidr=null`이면 새 서버에 SSH 접속할 수 없다. 처음 생성할 때는 본인의 `/32`를 설정한다.
Tailscale 설치·ACL·호스트 방화벽·실제 관리 접속을 확인한 뒤 null로 되돌려 공개 SSH만 제거한다.
Tailscale 앱 접근 통제는 SG가 아닌 tailnet 정책·호스트/CNI 정책도 필요하다.

## 생성 전에 반드시 확인

1. 현재 AWS 신원·서울 리전을 직접 확인하고 `expected_account_id`를 설정한다. 자격증명은 외부 AWS profile/SSO로 제공한다.
2. 서울 `Running On-Demand G and VT instances` 적용값 4 이상 및 여유 4 vCPU 확인. 현재 사용자가 요청한 증가는 **대기 중**이다.
3. 선택 AZ의 g6.xlarge offering 확인. 할당량·offering 확인은 실제 GPU 재고나 재시작 성공 보장이 아니다.
4. Canonical Ubuntu 24.04 amd64 일반 서버 AMI ID를 확인해 고정한다. data source는 ID·Canonical 소유자·이미지 이름·아키텍처·상태를 함께 검사한다. 자동 latest 선택은 하지 않는다.
5. AWS VPC CIDR을 홈 LAN·Pod CIDR·Service CIDR·기존 VPN/VPC 경로와 비교한다. 예시 `10.80.0.0/16`은 확정값이 아니다. 코드의 RFC1918 검사는 실제 경로 중복을 판별하지 않는다.
6. 초기 접속용 공개 키와 관리자 공인 `/32`를 준비한다. 예시 IP·키로 접속할 수 없다.
7. EC2·EBS·public IPv4·전송 비용을 공식 콘솔에서 재확인하고 월 10~20만원 예산 안에서 실험 시간을 정한다. 예산 알림 설정, 종료 방법과 확인 책임도 생성 전에 정한다.
8. 이 검토와 생성 허가 후에만 `launch_review_confirmed=true`로 실제 plan을 실행한다. 이는 **수동 확인 표시**이며 할당량·가격 자동 검사가 아니다.

## 로컬 검증 — 계정 접근/과금 없음

이 디렉터리에서:

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
```

`terraform test`는 AWS mock provider와 `command=plan`만 사용한다. 실제 계정에 접속하거나 리소스를 만들지 않는다.
실제 `terraform plan`은 AWS 계정 조회를 하므로 위 모의 테스트와 구분한다.
`terraform.tfvars.example`을 참고해 로컬 입력을 작성하되 예시는 그대로 배포하지 않는다.
실제 AMI/AZ/계정/경로와 SSH 접속은 mock 테스트로 검증되지 않는다.

2026-09-09 검증: Terraform 1.14.5 / AWS provider 6.63.0, fmt·validate 통과, mock plan 6건 통과.
로컬 샌드박스의 provider 프로세스 통신 제한으로 첫 validate/test가 실패했고, 제한 밖에서 동일한 비변경 검사를 재실행해 통과했다.
실제 AWS plan/apply·할당량 API 조회·접속·부팅·GPU 테스트는 실행하지 않았다.

## 상태·버전·비용 안전

- `.terraform.lock.hcl`은 provider 버전·체크섬 재현을 위해 Git 추적 대상으로 둔다. `init -upgrade`는 검토된 업그레이드에서만 사용한다.
- state, 실제 tfvars, 저장한 plan은 Git에서 제외한다. local state는 민감한 운영 파일이며 접근을 제한한다. 원격 state 저장소는 이번 범위에 추가하지 않는다.
- 실제 apply는 별도 승인 후 검토한 saved plan으로만 수행한다. 이 README나 로컬 검사 통과는 실행 허가가 아니다.
- `launch_review_confirmed=false`는 종료 스위치가 아니다. false로 되돌려도 EC2는 계속 실행된다.
- `prevent_destroy=true`는 Terraform의 EC2 삭제·교체를 차단한다. 요금 차단이나 콘솔/CLI 삭제 방지가 아니며, 리소스 선언을 제거해도 보호가 유지되는 것은 아니다.
- 일상 종료는 **EC2 Stop**이다. Pod 삭제·kubelet 중지·Terraform 코드 삭제로는 컴퓨팅 과금이 멈추지 않는다. AWS 상태가 `stopped`인지 확인한다. 이 코드에는 자동 종료 타이머·하드 예산 제한이 없다.
- EBS는 중지 중에도 과금된다. 인스턴스의 자동 할당 public IPv4는 stop/start 시 바뀔 수 있다. Kubernetes 식별값에 이 주소를 쓰지 않는다.
- `delete_on_termination=true`: 실제 EC2 종료(terminate) 시 루트 디스크와 모델 캐시도 삭제된다. Terraform 보호를 해제하거나 콘솔에서 종료하기 전 정확한 대상·데이터 폐기 승인이 필요하다. 이 노드에는 유일한 원본·DB를 두지 않는다.
- AMI·네트워크·키 변경은 재생성을 유발할 수 있다. plan에서 replacement가 보이면 멈추고 검토한다.

## 다음 단계의 네트워크 게이트

Tailscale UDP 인바운드를 열지 않아도 연결될 수 있지만 direct는 보장되지 않는다. 필요 시 허용 peer 공인 IP를 넣고 direct/DERP를 실측한다. 가정용 공인 IP가 바뀌면 `/32`도 갱신해야 한다.
현재 홈 Node InternalIP는 LAN 주소로 보고됐으므로 **Tailscale 설치만으로 AWS→홈 Pod 경로가 완성됐다고 보지 않는다**.
API 주소·인증서 SAN·노드/터널 주소·반환 경로·MTU를 확인한 뒤 조인한다. 홈 노드 재조인·IP 변경은 별도 계획/승인 대상이다.

서빙 기준 모델은 `Qwen/Qwen3-4B-Instruct-2507`, BF16, 입력+출력 최대 4096 토큰, 단일 GPU/vLLM이다.
모델 commit과 vLLM 이미지 digest는 실제 배포 전에 고정한다. 한국어 품질·처리량·VRAM은 미측정이다.

## 근거

- [AWS Internet Gateway와 public IPv4](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)
- [EC2 할당량](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html)
- [Canonical AMI 확인](https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/)
- [Tailscale 방화벽 포트](https://tailscale.com/docs/reference/faq/firewall-ports)
- [EC2 stop/terminate 수명주기](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html)
- [Qwen 공식 모델](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
