# vLLM GPU 노드 사양·Terraform·Join 계획

상태: **2026-09-19 실행 전 계획**. AWS 생성, Terraform `plan/apply`, Tailscale 등록,
Kubernetes Join, NVIDIA 설치, vLLM 배포를 실행하지 않았다.

이 문서는 홈 클러스터에 AWS GPU 워커 한 대를 추가하는 순서와 중단 조건을 정한다.
실행할 때는 한 단계를 검증한 뒤 다음 단계로 넘어간다. GPU 생성 승인과 Kubernetes Join
승인은 별개이며, 이 문서가 둘 중 어느 것도 자동 승인하지 않는다.

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
| 모델 | `Qwen/Qwen3-4B-Instruct-2507`, BF16 | 모델 revision과 vLLM image digest는 배포 전에 별도 고정한다. |
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

권장 후보 경로는 다음과 같다.

```text
AWS Node(InternalIP=Tailscale IP)
  ├─ API: Tailnet에서 홈 LAN route를 통해 CP LAN IP:6443
  └─ VXLAN: 홈 Node LAN InternalIP:8472/UDP ↔ AWS Tailscale InternalIP:8472/UDP
```

홈 subnet router가 LAN route를 광고하고 AWS Linux client가 승인된 route를 수락해야 한다.
Cilium VXLAN은 모든 Node 사이의 UDP 8472 도달성을 요구한다. 이 포트는 **public SG에
개방하지 않고**, Tailscale로 복호화된 host 간 경로와 호스트 방화벽에서만 허용한다.
선택적으로 Cilium health용 ICMP와 TCP 4240도 tailnet Node 사이에서 확인한다.

다음 행렬이 양방향으로 성공하기 전에는 `kubeadm join`을 실행하지 않는다.

| 출발 → 도착 | 검사 | 실패 시 |
| --- | --- | --- |
| AWS host → CP LAN IP | TCP 6443 + API TLS SAN | Join 중단. `--discovery-token-unsafe-skip-ca-verification` 사용 금지 |
| CP → AWS Tailscale IP | kubelet 예정 경로 TCP 10250 | route·ACL·host firewall 수정 후 재검사 |
| AWS ↔ 홈 worker1/2 | ICMP, UDP 8472, TCP 4240 | Cilium 경로 미완성. public SG 개방으로 우회 금지 |
| AWS ↔ 홈 Pod | 작은 패킷 후 DF 크기 sweep | Pod 경로·정책·MTU가 확인될 때까지 vLLM 배포 금지 |

subnet router의 기본 SNAT와 비대칭 경로가 VXLAN에서 문제를 만들 수 있다. Host 연결만
통과하고 Pod 통신이 실패하면 Join을 성공으로 판정하지 않는다. 홈 Node InternalIP를
Tailscale IP로 일괄 변경하는 작업은 기존 클러스터에 영향이 크므로 이 계획에서 자동
대안으로 실행하지 않는다.

## 4. 호스트 준비 순서

EC2 생성 후에도 바로 Join하지 않는다.

1. AWS 콘솔/CLI에서 instance ID·AZ·type·volume·SG·public IP를 Terraform plan과 대조한다.
2. 임시 `/32` SSH로 접속해 OS·kernel·clock sync·disk를 확인한다.
3. 선택한 vLLM image의 CUDA 요구사항에 맞는 NVIDIA driver를 고정 설치하고 재부팅한다.
4. `nvidia-smi`로 장치 1개·모델명·driver·가용 VRAM을 기록한다.
5. 홈 Node와 맞는 containerd/cgroup 설정을 적용한다. Docker를 Kubernetes CRI로 가정하지 않는다.
6. 현재 control plane과 같은 Kubernetes minor·patch의 `kubeadm`·`kubelet`을 설치하고 hold한다.
7. 일회용·tagged Tailscale auth key로 등록한다. key를 shell history·Terraform·Git에 남기지 않는다.
8. tailnet 관리 접속과 route를 검증한 다음 공개 SSH `/32` 제거 plan을 별도로 검토한다.

driver, container toolkit, vLLM image의 CUDA 조합은 하나를 고른 뒤 함께 기록한다. 설치가
된다는 이유만으로 호환된다고 보지 않으며 `nvidia-smi`와 container 안의 GPU 접근을 각각
확인한다.

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

1. host `nvidia-smi` 통과
2. NVIDIA Container Toolkit + containerd runtime 통과
3. pinned NVIDIA device plugin 배포, custom taint toleration 확인
4. Node `allocatable`에 `nvidia.com/gpu: 1` 확인
5. 합성 CUDA smoke Pod 한 개로 GPU 요청·종료 확인
6. pinned vLLM image digest와 pinned model revision으로 1 replica 배포
7. vLLM Pod에 label affinity, custom taint toleration, `nvidia.com/gpu: 1` limit 적용
8. ClusterIP 내부에서 `/health`와 최소 생성 요청 확인
9. Gateway 연결 전 엔진 직접 기준선 기록
10. Gateway 연결 후 서비스 경로 기준선을 별도로 기록

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
| Terraform 준비 | fmt·validate·mock test, 실제 CIDR·AMI·AZ·quota·예산 검토 |
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
