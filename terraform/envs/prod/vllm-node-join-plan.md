# vLLM GPU 노드 사양·Terraform·Join 계획

상태: **2026-09-19 실행 전 계획**. AWS 생성, Terraform `plan/apply`, Tailscale 등록,
Kubernetes Join, NVIDIA 설치, vLLM 배포를 실행하지 않았다.

이 문서는 홈 클러스터에 AWS GPU 워커 한 대를 추가하는 순서와 중단 조건을 정한다.
실행할 때는 한 단계를 검증한 뒤 다음 단계로 넘어간다. GPU 생성 승인과 Kubernetes Join
승인은 별개이며, 이 문서가 둘 중 어느 것도 자동 승인하지 않는다.

## 0. 가장 먼저 시작할 외부 선행 작업 — GPU quota

서울 리전의 `Running On-Demand G and VT instances` 적용값과 현재 사용량을 먼저 읽는다.
`g6.xlarge` 한 대에는 여유 4 vCPU가 필요하다. 적용값이나 남은 여유가 4보다 작으면 다른
준비와 병행해 증설을 신청하고, 승인 전에는 실제 `plan/apply`와 EC2 생성 단계로 넘어가지
않는다. quota 승인도 EC2 생성 승인은 아니다.

증설 요청은 AWS 계정 상태를 바꾸는 작업이므로 이 문서 작성 범위에서는 실행하지 않는다.
실행 승인을 받았을 때도 다음을 서로 다른 증거로 남긴다.

1. 요청 전 적용값·사용량과 대상 리전
2. 요청한 값과 request ID
3. 승인 후 실제 적용값
4. 선택 AZ의 `g6.xlarge` offering과 생성 시점 capacity

offering 조회와 quota 승인은 해당 시점의 실제 재고를 보장하지 않는다. 승인 대기 시간이
나머지 준비보다 길 수 있으므로 이 확인·신청을 전체 실행 순서의 첫 단계로 둔다.

## 1. 확정 사양

| 항목 | 기준 | 이유·경계 |
| --- | --- | --- |
| 노드 이름 | `persona-gpu-01` | EC2 `Name` 태그와 Kubernetes Node 이름을 맞춘다. public/private IP를 식별자로 쓰지 않는다. |
| 리전·형태 | 서울, On-Demand `g6.xlarge` 1대 | 4 vCPU·16 GiB RAM·NVIDIA L4 1장. 단일 GPU 기준선이며 HA가 아니다. |
| GPU 메모리 | EC2 사양표 기준 22 GiB | L4 하드웨어 표기 24 GB와 EC2가 표시하는 가용 22 GiB를 같은 단위처럼 섞지 않는다. 실제 `nvidia-smi` 값은 실행 기록에 남긴다. |
| OS | Canonical Ubuntu 24.04 amd64 AMI ID 고정 | 자동 `latest`를 쓰지 않는다. 현재 홈 클러스터와 같은 amd64 계열이다. |
| 디스크 | 암호화 gp3 100 GiB, 3000 IOPS, 125 MiB/s | 이미지·모델 cache·실험 로그용이다. DB나 유일한 원본을 두지 않는다. terminate 시 삭제된다. |
| Kubernetes | 현재 control plane과 같은 minor·patch 우선 | 실행 직전 실제 버전을 다시 읽는다. 현재 관측값 `v1.36.2`를 설치 명령에 영구 하드코딩하지 않는다. |
| CNI | 기존 Cilium VXLAN + kube-proxy | GPU Join 때문에 CNI 모드를 함께 바꾸지 않는다. underlay MTU 1280 기준도 유지한다. |
| 모델 | `Qwen/Qwen3-4B-Instruct-2507`, BF16 | revision은 §4에 commit으로 적었다. 실행 직전 다시 읽어 대조한다. |
| 실행 조합 | vLLM `v0.29.0-cu129-ubuntu2404`·CUDA 12.9.1·NVIDIA driver **570 LTS**·Container Toolkit 1.20.x | tag는 선택 기준이고 배포는 digest로 고정한다. driver를 580이 아니라 570으로 잡은 이유는 §4에 있다 — image 자신의 `NVIDIA_REQUIRE_CUDA`가 580을 허용하지 않는다. |
| 문맥 조건 | 4096 기준선, 8192 후속 비교 조건 | VRAM·TTFT·처리량을 각각 측정한다. 8192 성공을 사전 가정하지 않는다. |
| vLLM 노출 | ClusterIP 내부 전용 | public SG에 8000·6443·10250·8472·NodePort를 열지 않는다. |

AWS 공식 EC2 표는 `g6.xlarge`를 4 vCPU·16 GiB·L4 1장·GPU 메모리 22 GiB로
표시한다. 마케팅의 24 GB 표기와 차이가 있으므로 용량 계획은 작은 쪽을 기준으로 하고,
실제 장치 값으로 다시 확인한다.

## 2. Terraform이 소유하는 것과 소유하지 않는 것

`main.tf`가 만드는 범위:

- 전용 VPC와 첫 `/24` public subnet, Internet Gateway와 기본 경로
- public IPv4가 붙는 `g6.xlarge` 1대와 암호화 gp3 루트 볼륨
- 기본 닫힘 ingress, 선택한 관리자 `/32`의 임시 SSH, 선택한 peer `/32`의 Tailscale UDP 41641
- IMDSv2 필수, 불필요한 IAM instance profile 없음, 종료 동작 `stop`

Terraform이 만들지 않는 범위:

- GPU driver, containerd, NVIDIA Container Toolkit, kubelet·kubeadm, Tailscale
- tailnet ACL·route 승인, kubeadm token, Hugging Face token, 모델 cache
- Kubernetes Node·label·taint, Cilium·kube-proxy·NVIDIA device plugin, vLLM Pod

Join 자격증명을 `tfvars`, `user_data`, output, state에 넣지 않는다. `user_data`를 비워 둔
이유는 단기 token이 state와 콘솔 기록에 남는 일을 구조적으로 피하기 위해서다.
`tailscale_peer_cidrs`는 기본값 `[]`을 유지한다. AWS Node가 public IPv4로 outbound를
시작할 수 있으므로 먼저 `tailscale ping`으로 direct/DERP를 관측한다. 고정된 home peer
공인 `/32`가 실제로 필요하다고 확인했을 때만 추가하며, 가정용 유동 IP를 장기 규칙으로
간주하지 않는다.

생성 전 Terraform 검증은 계정에 접속하지 않는 아래 네 명령까지만 먼저 수행한다.

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
```

실제 `plan`은 AWS 조회이며, `apply`는 과금과 외부 상태 변경이다. 각각 별도 승인 뒤 실행한다.
`prevent_destroy`가 replacement를 막으면 우회하지 말고 AMI·subnet·key 변경 이유부터 검토한다.

## 3. Join 전에 닫아야 하는 네트워크 게이트

현재 홈 Kubernetes Node의 InternalIP는 LAN 주소이고, AWS Node의 InternalIP는 Tailscale
주소로 둘 계획이다. 따라서 Tailscale 설치만으로 Cilium VXLAN mesh가 완성되지 않는다.

Join 전 읽기 전용으로 다음 값을 기록한다.

1. control plane의 실제 Kubernetes·kubeadm·containerd 버전
2. API server endpoint와 인증서 SAN, Pod CIDR, Service CIDR
3. 세 홈 Node의 InternalIP와 Tailscale IP, `tailscale ping`의 direct/DERP 여부
4. VPC CIDR과 홈 LAN·Pod·Service·tailnet CIDR의 중복 여부
5. Cilium 실제 mode·VXLAN port·MTU와 각 Node의 `cilium_vxlan`/Pod route 값
6. tailnet ACL, subnet route 광고·승인·AWS Linux client의 route 수락 여부
7. 홈 Node의 LAN interface `rp_filter`와 Proxmox VM/게스트 방화벽의 UDP 41641·8472 처리

첫 K8S-01 기준선의 subnet route 설정은 다음 하나로 고정한다.

| 항목 | 첫 기준선 |
| --- | --- |
| subnet router | `k8s-cp` |
| 광고 route | 실행 시 다시 확인한 홈 LAN CIDR. 현재 관측 후보는 `192.168.50.0/24` |
| route SNAT | `--snat-subnet-routes=false` |
| AWS Linux client | 승인된 subnet route 수락 |
| AWS SG의 `tailscale_peer_cidrs` | 빈 목록 유지, direct/DERP만 관측 |

SNAT를 끄는 이유는 홈 worker가 VXLAN outer source를 CP의 LAN IP가 아니라 AWS Node의
Tailscale IP로 보게 하기 위해서다. 홈 세 Node가 모두 tailnet member인지 다시 확인하고,
worker는 100.x source의 응답을 자신의 `tailscale0`로 직접 돌려보낸다. 이 경로는 비대칭이므로
worker의 strict reverse-path filtering이 packet을 버리지 않는지도 실제 값과 capture로
검증한다. 검증 없이 `rp_filter`를 변경하지 않는다.

초기 subnet router를 CP로 두면 AWS→홈 worker의 VXLAN과 Pod traffic이 CP를 거친다. 단일
실험에는 수용하지만 CP가 새 병목·SPOF가 될 수 있다. K8S-01 기록에 CP CPU·network와
Tailscale direct/DERP를 함께 남기고, 포화가 확인돼도 같은 기준선 도중 router를 바꾸지 않는다.

고정한 후보 경로는 다음과 같다.

```text
AWS Node(InternalIP=Tailscale IP)
  ├─ API: Tailnet에서 홈 LAN route를 통해 CP LAN IP:6443
  └─ VXLAN: 홈 Node LAN InternalIP:8472/UDP ↔ AWS Tailscale InternalIP:8472/UDP
```

CP subnet router가 SNAT 없이 LAN route를 광고하고 AWS Linux client가 승인된 route를 수락해야 한다.
Cilium VXLAN은 모든 Node 사이의 UDP 8472 도달성을 요구한다. 이 포트는 **public SG에
개방하지 않고**, Tailscale로 복호화된 host 간 경로와 호스트 방화벽에서만 허용한다.
선택적으로 Cilium health용 ICMP와 TCP 4240도 tailnet Node 사이에서 확인한다.

Proxmox Gate 2-B가 적용된 홈 VM은 VM IN 기본 동작과 UDP 41641 수신을 다시 확인한다.
AWS SG에서 41641 ingress를 비워도 direct가 되는지 먼저 보고, DERP만 사용된다는 이유만으로
가정용 유동 `/32`를 즉시 추가하지 않는다.

다음 행렬이 양방향으로 성공하기 전에는 `kubeadm join`을 실행하지 않는다.

**행마다 "무엇을 증명하는가"를 적는다.** 아래 계층은 서로를 함축하지 않는다 — SSH가 되는
것과 Cilium Pod overlay가 도는 것은 **다른 성공**이다. 위 행이 통과했다고 아래 행을 건너뛰지
않으며, 아래 행이 실패하면 위 행의 통과를 근거로 Join을 성공 처리하지 않는다.

| 출발 → 도착 | 검사 | 증명하는 계층 | 실패 시 |
| --- | --- | --- | --- |
| AWS host ↔ 홈 host 3대 | `tailscale ping`(direct/DERP 구분), `tailscale status` | tailnet L3 도달성 **뿐**. route·Pod와 무관 | tailnet ACL·device 승인 확인. DERP만 되면 그 사실을 기록하고 진행(직접 연결 강제는 별건) |
| AWS host → CP LAN IP | TCP 6443 + API TLS SAN | subnet route 수락 + API TLS 신원 | Join 중단. `--discovery-token-unsafe-skip-ca-verification` 사용 금지 |
| CP → AWS Tailscale IP | kubelet 예정 경로 TCP 10250 | 역방향 host 도달성(kubelet·logs·exec 경로) | route·ACL·host firewall 수정 후 재검사 |
| AWS → 홈 worker1/2 | ICMP, **UDP 8472**, TCP 4240 + LAN capture의 source가 AWS 100.x인지 확인 | VXLAN underlay 편도 + SNAT-off가 실제로 걸렸는지 | SNAT·route·`rp_filter` 확인. public SG 개방으로 우회 금지 |
| 홈 worker1/2 → AWS | ICMP, **UDP 8472**, TCP 4240 + Tailscale 경로 확인 | VXLAN underlay 반대 편도(비대칭 경로의 반쪽) | home Node의 outer source·tailnet ACL·host firewall 확인 |
| AWS Pod ↔ 홈 Pod | 작은 패킷 먼저, 그다음 DF 세트로 크기 sweep(1200 → 1230 → 1250 → 1280) | **Pod netns overlay** — 위 다섯 행이 전부 통과해도 여기서 실패할 수 있다 | Pod 경로·정책·MTU가 확인될 때까지 vLLM 배포 금지 |
| AWS Pod → CoreDNS | 클러스터 내부 이름 `A` 질의 | Pod netns DNS(kube-dns Service 경로 + 정책) | DNS 허용 정책과 Service 경로를 따로 확인. 이름 해석 실패를 "네트워크 정상"으로 쓰지 않는다 |

MTU sweep은 **1280 통과만으로 끝내지 않는다.** underlay `tailscale0`이 1280이고 VXLAN
오버헤드가 50 bytes라 여유가 **0**이다(`bootstrap/cilium/README.md`). outer 헤더가 IPv6로
잡히는 등의 이유로 경계에서 실패하면 1260 이하로 낮춰 재확인한다. 반대로 작은 패킷만
통과한 것을 "MTU 정상"으로 기록하지 않는다.

두 가지는 **선언값이 아니라 기본값**이므로 실측으로 확인한다.

- **UDP 8472는 저장소 어디에도 선언돼 있지 않다.** `bootstrap/cilium/values.yaml`에
  `tunnelPort` 키가 없고, 8472는 Cilium 차트 기본값이다. 이 포트를 검사할 때 "우리가 정한
  값"이 아니라 "차트 기본값을 확인하는 것"임을 기록한다. `cilium-config` ConfigMap의 실제
  값을 읽어 대조한다.
- **masquerade 설정도 선언돼 있지 않다** → 차트 기본 `enableIPv4Masquerade: true`. Tailscale
  쪽 `--snat-subnet-routes=false`와 방향이 다른 두 SNAT이므로, 경로를 추론할 때 둘을 같은
  것으로 읽지 않는다. capture의 source 주소로만 판단한다.

SNAT-off 후보도 실제 동작 보장은 아니다. Host 연결만 통과하고 Pod 통신이 실패하면 Join을
성공으로 판정하지 않는다. 홈 Node InternalIP를 Tailscale IP로 일괄 변경하는 작업은 기존
클러스터에 영향이 크므로 이 계획에서 자동 대안으로 실행하지 않는다.

Cilium은 Argo 밖(`helm install`)이라 MTU를 바꾸면 ConfigMap만 갱신되고 agent는 옛 값으로
계속 돈다. `rollOutCiliumPods: true`가 있어도 helm이 모르는 키를 조용히 무시할 수 있으므로,
설정을 바꾼 뒤에는 **실제 인터페이스 MTU와 `ip route get` 값을 직접 읽어** 확인한다.

### Tailscale 명령 (실행하지 않음 — 형태만 고정)

auth key는 명령행에 남기지 않고 실행하는 사람이 그때 입력한다. 아래는 형태 기록이다.

```text
# 홈 CP(subnet router) — route는 실행 시 재확인한 홈 LAN CIDR로 바꾼다
tailscale up --advertise-routes=192.168.50.0/24 --snat-subnet-routes=false
#   광고한 route는 tailnet 관리 화면에서 사람이 승인해야 유효해진다.

# AWS GPU 노드 — 승인된 route를 수락한다
tailscale up --accept-routes
```

`--advertise-routes`·`--accept-routes`는 이 저장소에 처음 적는 플래그다. 기존 문서에는
산문으로만 있었다. 실제 실행·route 승인·ACL 변경은 이 계획의 범위가 아니다.

## 4. 호스트 준비 순서

EC2 생성 후에도 바로 Join하지 않는다.

첫 실행 후보의 호환 조합은 아래처럼 하나로 묶는다. 2026-09-19 공식 릴리스 기준으로
vLLM 기본 Docker image는 CUDA 13.0이고 CUDA 12.9 변형을 별도로 제공한다. L4 기준선은
필요 이상으로 CUDA major를 올리지 않기 위해 CUDA 12.9 변형을 선택한다.

아래 값은 **registry manifest와 image config를 직접 읽어 확인한 것**이다(2026-09-25).
tag 숫자에서 CUDA·driver를 추정한 값이 아니다.

| 구성 | 확인한 값 | 확인 방법·근거 |
| --- | --- | --- |
| vLLM image | `vllm/vllm-openai:v0.29.0-cu129-ubuntu2404` | — |
| parent OCI index digest | `sha256:b478e866ccff56876a0e159edae1620055c858c739fb20f23194fc636f1a4108` | `docker buildx imagetools inspect` |
| **배포에 고정할 linux/amd64 child** | **`sha256:51b1042786c1bb7ab640fd05e4a2b19ae41662959387cc07e1c3106ae2a851b8`** | 같은 명령. parent index나 tag로 배포하지 않는다 |
| CUDA runtime | **12.9.1** (`NV_CUDA_CUDART_VERSION=12.9.79-1`) | image config `Env` |
| 지원 GPU arch | `TORCH_CUDA_ARCH_LIST`에 **8.9 포함** → L4(Ada)용 kernel이 미리 빌드돼 있다 | image config `Env` |
| forward-compat layer | `VLLM_ENABLE_CUDA_COMPATIBILITY=0` — 꺼져 있다 | image config `Env` |
| image가 허용하는 driver 분기 | `NVIDIA_REQUIRE_CUDA=cuda>=12.9`, 열거된 분기는 **535·550·560·565·570** | image config `Env` |
| **NVIDIA driver** | **570 LTS** | 위 열거 목록 안에서 가장 높은 분기 |
| NVIDIA Container Toolkit | 1.20.x (최신 안정 1.20.1, 2026-09-19) | GitHub releases |
| 모델 revision | `Qwen/Qwen3-4B-Instruct-2507` @ `cdbee75f17c01a7cc42f958dc650907174af0554` | HF model API(2026-09-25 조회) |
| vLLM build commit | `98dff2a81d747d1dba01a47f939f48c3526d4206` | image config `Env` |

### driver를 580이 아니라 570으로 잡은 이유

이전 초안은 580.x를 적었다. 근거로 삼은 숫자(CUDA 12.9 Update 1 최소 575.57.08)는
**틀리지 않았지만 다른 질문에 대한 답**이었다. 두 숫자는 서로 다른 것을 말한다.

- CUDA Toolkit release notes: **CUDA 12.9 Update 1 → driver ≥ 575.57.08**, 12.9 GA →
  ≥ 575.51.03. 이것은 **12.9 toolkit의 기능을 쓰기 위한** 최소값이다.
- 같은 문서의 toolkit↔driver branch 표: **CUDA 13.0 → R580**. 즉 580은 CUDA 13 계열 분기다.
- 이 image는 **CUDA 12.x minor version compatibility**에 기대어 동작한다. 그래서 image 자신의
  `NVIDIA_REQUIRE_CUDA`가 535·550·560·565·570을 허용 분기로 열거한다. 12.x로 빌드된 앱은
  12.0 최소 driver 이상에서 돌기 때문이다.
- **580은 그 열거 목록에 없다.** Container Toolkit은 container 시작 시 `NVIDIA_REQUIRE_*`
  조건을 검사하므로, 580 host에서 이 image를 띄우면 조건 불충족으로 거부될 수 있다.
- `NVIDIA_DISABLE_REQUIRE=1`이 그 검사를 모두 끄는 공식 스위치지만 **쓰지 않는다.** 검사를
  끄는 것은 호환을 만드는 것이 아니라 확인을 없애는 것이다.

그래서 열거된 분기 안에서 가장 높은 **570 LTS**를 고른다. 이것은 "575 이상이어야 한다"와
모순이 아니다 — 575는 toolkit 기능 기준, 570은 이 image가 실제로 요구하는 실행 기준이다.

참고로 **vLLM 기본 tag는 CUDA 13 계열이다.** 최신 `v0.30.0`(2026-09-22)의 기본 tag를 읽어
보니 `CUDA_VERSION=13.0.2`였고, 허용 분기는 535~575로 `cuda>=13.0`을 요구했다 — 그 조합은
581 이상 없이는 성립하기 어렵다. cu129 변형을 고른 이 판단이 맞았음을 확인한 셈이다.
이번 기준선에서는 버전을 올리지 않는다.

### GPU 노출 방식: NVIDIA device plugin (GPU Operator 아님)

노드 1대 전제에서 **device plugin DaemonSet**을 쓴다.

- driver와 Container Toolkit은 Ansible이 소유한다(§4 호스트 준비). GPU Operator는 driver
  container·toolkit·validator를 제 방식으로 다시 설치하려 하므로 **같은 일을 두 주체가
  관리**하게 된다. 어느 쪽이 실제로 적용됐는지 추적하기 어려워진다.
- Operator는 namespace·RBAC·여러 DaemonSet·CRD를 추가한다. 노드 1대에서 얻는 것은
  `nvidia.com/gpu: 1` 노출 하나인데 운영 표면이 크게 늘어난다.

운영 한계를 받아들인다: driver 업그레이드가 수동이고, node feature discovery·MIG·DCGM을
각각 따로 붙여야 한다. **재검토 조건 — GPU 노드가 2대 이상이 되거나 driver 업그레이드가
반복 작업이 되면 GPU Operator를 다시 비교한다.**

최신 tag를 따라가지 않는다. 위 digest·driver patch·toolkit package version을 실제 설치
직전에 다시 기록하고, 하나를 바꾸면 조합 전체의 smoke를 다시 실행한다. CUDA compatibility
package로 낮은 driver를 우회하는 방식은 첫 기준선에 쓰지 않는다(`VLLM_ENABLE_CUDA_COMPATIBILITY=0`
이 이미 그 상태다). GPU가 아직 없으므로 `nvidia-smi`·container GPU 실행·device plugin
배포는 실행하지 않았다.

1. AWS 콘솔/CLI에서 instance ID·AZ·type·volume·SG·public IP를 Terraform plan과 대조한다.
2. 임시 `/32` SSH로 접속해 OS·kernel·clock sync·disk를 확인한다.
3. 선택한 vLLM image의 CUDA 요구사항에 맞는 NVIDIA driver를 고정 설치하고 재부팅한다.
4. `nvidia-smi`로 장치 1개·모델명·driver·가용 VRAM을 기록한다.
5. 홈 Node와 맞는 containerd/cgroup 설정을 적용한다. Docker를 Kubernetes CRI로 가정하지 않는다.
6. 현재 control plane과 같은 Kubernetes minor·patch의 `kubeadm`·`kubelet`을 설치하고 hold한다.
7. 일회용·tagged Tailscale auth key로 등록한다. key를 shell history·Terraform·Git에 남기지 않는다.
8. tailnet 관리 접속과 route를 검증한 다음 공개 SSH `/32` 제거 plan을 별도로 검토한다.

package 설치 성공을 호환성 검증으로 보지 않으며 `nvidia-smi`와 container 안의 GPU 접근을
각각 확인한다.

## 5. kubeadm Join 설계

### 5.1 노드 등록값

| 항목 | 값 |
| --- | --- |
| Node name | `persona-gpu-01` |
| kubelet `node-ip` | 실행 시 확인한 AWS Node의 Tailscale IPv4 |
| CRI socket | `unix:///run/containerd/containerd.sock` |
| 초기 taint | `personaruntime.xyz/dedicated=gpu-serving:NoSchedule` |
| labels | `personaruntime.xyz/node-pool=gpu`, `personaruntime.xyz/accelerator=nvidia-l4`, `personaruntime.xyz/provider=aws` |

일반 Pod가 Join 순간 GPU Node로 들어오는 것을 막기 위해 taint는 `JoinConfiguration`의
`nodeRegistration.taints`로 처음부터 등록한다. Cilium·kube-proxy·NVIDIA device plugin이
이 taint를 tolerate하는지 렌더 결과로 먼저 확인한다. 어느 하나라도 tolerate하지 않으면
taint를 빼고 무방비로 Join하지 말고 해당 DaemonSet 선언을 먼저 수정한다.

Join에는 실행 중인 클러스터가 지원하는 kubeadm API version을 사용한다. 현재 후보는
`kubeadm.k8s.io/v1beta4`지만, 실행 시 `kubeadm config print join-defaults`로 다시 확인한다.
짧은 TTL token과 CA hash는 CP에서 직전에 만들고 AWS의 tmpfs 파일에만 넣는다. 파일 mode를
600으로 제한하고 성공·실패와 무관하게 삭제한다. 실제 token·hash·Tailscale IP를 문서나
Git에 붙여 넣지 않는다.

Kubernetes 공식 정책상 새 Node의 `kubeadm join`은 클러스터를 마지막으로 생성/업그레이드한
`kubeadm` minor와 맞추는 것이 원칙이며, kubelet은 API server보다 새 버전이면 안 된다.
지원 범위가 넓더라도 첫 Join은 정확히 같은 patch를 우선한다.

### 5.2 성공 판정

아래가 전부 참이어야 Join 완료다.

- Node `Ready=True`, InternalIP가 검토한 Tailscale IPv4, 역할은 worker
- Cilium·kube-proxy Pod가 새 Node에서 Ready, 반복 restart 없음
- 기존 CP·홈 worker·DB·Gateway 상태가 Join 전과 동일
- 홈 Pod ↔ AWS Pod 양방향 DNS·ClusterIP·PodIP 통신 성공
- DF MTU sweep에서 예상 경계와 실제 경계가 일치하고 큰 패킷이 timeout으로 사라지지 않음
- Hubble에서 예상 흐름을 확인하고 원인 불명 drop이 없음
- Node label·taint가 정확하고 일반 앱이 GPU Node에 배치되지 않음

Node가 `Ready`여도 Pod 경로가 실패하면 성공이 아니다. Cilium 설정값만 보지 말고 AWS
Node의 실제 `cilium_vxlan`과 Pod route MTU를 확인한다. MTU를 바꿨다면 ConfigMap `Synced`가
아니라 Cilium DaemonSet 재시작과 실제 인터페이스 값을 근거로 삼는다.

## 6. GPU 노출과 vLLM 배포 순서

vLLM은 새 `persona-inference` namespace에 둔다. `persona-app`에 같이 넣지 않아 GPU
workload·Secret·NetworkPolicy의 수명주기를 Gateway와 분리한다. Service 이름은
`persona-vllm`, port는 TCP 8000으로 계획한다. namespace·workload·Service·inference 쪽
NetworkPolicy는 수동 Sync인 별도 `persona-inference` Argo Application이 소유하고,
Gateway egress만 기존 `persona-app-netpol` Application이 소유한다.

GPU smoke 다음의 관측 Target·대시보드·합성 부하·장애·실행 옵션 비교는
[vLLM GPU 기준선 관측·실험 계획](vllm-observability-experiment-plan.md)을 따른다.
vLLM Pod를 기동할 수 있어도 Prometheus Target과 GPU telemetry Target이 `UP`이 되기
전에는 성능 실험을 시작하지 않는다.

새 namespace는 먼저 PSA `restricted`로 선언하고 선택한 vLLM image를 server dry-run한다.
기본 image가 non-root·read-only root filesystem 조건을 충족하지 못하면 GPU 접근을 이유로
namespace 전체를 `privileged`로 낮추지 않는다. non-root image/파생 image 또는 필요한 최소
예외를 별도 리뷰한다. NVIDIA device plugin의 host 권한과 vLLM workload의 권한은 같은
것으로 취급하지 않는다.

1. host `nvidia-smi` 통과
2. NVIDIA Container Toolkit + containerd runtime 통과
3. pinned NVIDIA device plugin 배포, custom taint toleration 확인
4. Node `allocatable`에 `nvidia.com/gpu: 1` 확인
5. 합성 CUDA smoke Pod 한 개로 GPU 요청·종료 확인
6. pinned vLLM image digest와 pinned model revision으로 1 replica 배포
7. vLLM Pod에 label affinity, custom taint toleration, `nvidia.com/gpu: 1` limit 적용
8. ClusterIP 내부에서 `/health`와 최소 생성 요청 확인
9. Gateway 연결 전 엔진 직접 기준선 기록
10. `persona-inference`와 `persona-app` 양쪽 NetworkPolicy 허용을 선언·검증하고 수동 Sync
11. Gateway의 vLLM URL을 `persona-vllm.persona-inference.svc.cluster.local:8000`으로 전환
12. Gateway 연결 후 서비스 경로 기준선을 별도로 기록

NetworkPolicy는 연결 전 다음 두 방향을 동시에 준비한다.

- `persona-inference`: default-deny와 함께 `persona-app`의 `persona-gateway` Pod에서 vLLM
  Pod TCP 8000으로 오는 ingress만 허용한다.
- `persona-app-netpol`: `persona-gateway` Pod에서 `persona-inference`의 vLLM Pod TCP
  8000으로 나가는 egress를 추가한다.

모델을 Pod 시작 시 받는다면 `persona-inference` default-deny가 다운로드도 막는다. 첫
기준선에서는 모델 artifact를 미리 cache하거나, 필요한 registry/model host만 허용하는
별도 Cilium FQDN egress를 검토한다. steady state에 편의를 위한 `0.0.0.0/0:443`을 남기지
않는다. 두 policy의 server dry-run·렌더 검증 후 `persona-inference` policy →
`persona-app-netpol` 순으로 수동 Sync하고, Hubble에서 허용/차단을 확인한 다음에만 Gateway
설정을 바꾼다.

GPU Operator는 이 단계의 기본 선택이 아니다. 단일 Node에서 driver와 toolkit의 소유권을
명확히 하기 위해 host 설치 + pinned device plugin으로 시작한다. 운영 부담이 실제로 더
크다고 확인될 때만 별도 비교한다.

vLLM Pod는 public IP나 NodePort로 노출하지 않는다. 모델 cache는 재생성 가능 데이터이며
100 GiB 루트 볼륨의 사용량을 기록한다. 모델 다운로드 실패나 cache 손상은 DB 복구 문제로
분류하지 않는다.

## 7. 중단·재시작·원복

### 일상적인 비용 중단

1. 새 생성 요청을 막고 진행 중 요청 종료를 확인한다.
2. vLLM replica를 0으로 내려 GPU 사용을 끝낸다.
3. Node를 cordon하고 실험 Pod가 없는지 확인한다.
4. EC2를 **stop**하고 AWS 상태가 `stopped`인지 확인한다.

Node 오브젝트가 `NotReady`로 남는 것은 stop의 예상 결과다. 매번 `kubeadm reset`하거나
Node를 삭제하지 않는다. stop/start 뒤 public IP는 바뀔 수 있지만 Kubernetes InternalIP와
관리 경로는 Tailscale을 사용한다. EBS·public IPv4 등 잔여 비용은 별도로 확인한다.

### Join 실패 또는 노드 탈퇴

1. 기존 홈 서비스·DB 상태를 먼저 확인한다.
2. GPU Node를 cordon하고 GPU workload가 없음을 확인한다.
3. CP에서 정확한 Node 이름·UID를 대조한 뒤 drain/delete를 별도 승인으로 실행한다.
4. AWS host에서 `kubeadm reset`과 CNI 잔여 정리는 대상 확인 후 실행한다.
5. tailnet device·route·짧은 TTL token을 폐기한다.
6. EC2는 우선 stop한다. terminate와 EBS 삭제는 별도 파괴 승인 대상이다.

조인 실패를 `--ignore-preflight-errors=all`, CA 검증 생략, public 8472/10250 개방으로
우회하지 않는다. 실패 지점의 host route·ACL·MTU·version을 기록해 K8S-01 진단 자료로 남긴다.

## 8. 단계별 완료 증거

| 단계 | 필요한 증거 |
| --- | --- |
| Q0 quota | 서울 G/VT 적용값·사용량 확인, 부족 시 증설 요청·승인 후 적용값 4 이상 확인 |
| Terraform 준비 | fmt·validate·mock test, 실제 CIDR·AMI·AZ·예산 검토 |
| AWS 생성 | 승인한 saved plan과 실제 instance/volume/SG 대조 |
| Host 준비 | `nvidia-smi`, container GPU smoke, Tailscale direct/DERP 기록 |
| Join 전 네트워크 | API TLS, 8472/4240/ICMP 행렬, route·ACL·MTU 기록 |
| Kubernetes Join | Node Ready, InternalIP, system DaemonSet, 기존 서비스 무변경 |
| GPU 등록 | `nvidia.com/gpu: 1`, label·taint·toleration, smoke Pod |
| vLLM | pinned digest/revision, 4096 기준선 health·최소 생성; 8192는 후속 비교로 분리 |
| 기준선 | 엔진 직접/서비스 경로를 분리한 TTFT·완료 지연·tokens/s·오류·GPU 메모리 |
| 종료 | vLLM 0, EC2 stopped, 잔여 과금 자원 목록 |

## 근거

- [AWS accelerated instance 사양](https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html)
- [Kubernetes kubeadm cluster 생성·node-ip](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Kubernetes kubeadm join](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [Kubernetes version skew](https://kubernetes.io/releases/version-skew-policy/)
- [Cilium VXLAN routing과 UDP 8472](https://docs.cilium.io/en/stable/network/concepts/routing/)
- [Tailscale subnet routes](https://tailscale.com/docs/features/subnet-routers)
- [Tailscale route injection](https://tailscale.com/docs/reference/route-injection)
- [Tailscale site-to-site와 subnet route SNAT](https://tailscale.com/docs/features/site-to-site)
- [vLLM v0.29.0 release artifacts](https://github.com/vllm-project/vllm/releases/tag/v0.29.0)
- [CUDA 12.9 driver 요구사항](https://docs.nvidia.com/cuda/archive/12.9.1/cuda-toolkit-release-notes/)
- [NVIDIA Container Toolkit release notes](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/release-notes.html)
