# AWS GPU 호스트 Ansible 준비 경계

상태: **2026-09-25 제안**. 이 문서는 Ansible 역할과 실행 경계를 정할 뿐, EC2 생성,
패키지 설치, Tailscale 등록, Kubernetes Join을 실행하지 않는다.

## 결론

첫 GPU 노드에는 **Terraform + 수동 게이트가 있는 Ansible**을 사용한다.

- Terraform은 VPC, subnet, Security Group, EC2, 암호화 EBS처럼 AWS에서만 결정할
  자원을 소유한다.
- Ansible은 생성된 한 호스트를 재실행 가능하게 준비한다. 운영자가 SSH 또는 검증된
  Tailnet 접속으로 명시적으로 실행한다.
- `kubeadm join` token, CA hash, Tailscale auth key, 모델 접근 token은 Ansible inventory,
  변수 파일, Terraform state, user-data에 넣지 않는다.
- CodeDeploy는 채택하지 않는다. EC2용 CodeDeploy는 agent, AppSpec, deployment group,
  artifact(S3 또는 GitHub)와 instance IAM 권한을 추가한다. 단일 GPU host를 한 번 준비하는
  현재 단계에는 그 공급망이 join token의 일회성·사람 승인 경계를 더 안전하게 만들지 않는다.

Ansible playbook은 원하는 상태를 다시 실행해도 같은 결과가 되도록 작성할 수 있어 driver,
containerd, kubelet 같은 host 설정에 적합하다. 그러나 재실행 가능하다는 이유로 인증·Join까지
자동화해도 된다는 뜻은 아니다. [Ansible의 idempotency 설명](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_intro.html)을 따른다.
CodeDeploy가 EC2에서 수행하는 일은 application revision을 내려받아 AppSpec lifecycle hook을
실행하는 것이다. 이 노드의 Kubernetes worker 등록에는 맞지 않는다. [AWS CodeDeploy EC2 배포 방식](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-steps-server.html)을 참고한다.

## 준비할 디렉터리와 실행 단위

구현을 시작할 때 아래처럼 `persona-platform/ansible/gpu-node/`만 추가한다. Terraform과
Kubernetes 매니페스트의 소유권을 섞지 않는다.

```text
ansible/gpu-node/
  README.md                    # 실행 전 게이트와 실제 실행 명령
  inventory.example.yml        # IP·사용자명만 든 합성 예시, 비밀값 없음
  playbooks/
    00-preflight.yml           # 읽기 전용 — OS·디스크·메모리·swap·clock·네트워크·MTU
    10-base.yml                # swap/kernel/sysctl + containerd·kubeadm/kubelet·hold
    20-tailscale.yml           # 패키지 설치와 서비스 활성화까지만
    30-gpu-runtime.yml         # NVIDIA driver + Container Toolkit 설치·검증
    40-join-preflight.yml      # 읽기 전용 — Join 직전 버전·port·token 존재 여부
```

번호를 10 단위로 띄운다 — 나중에 한 계층을 둘로 쪼갤 때 전체를 다시 번호 붙이지 않는다.
`roles/`와 `requirements.yml`은 만들지 않았다. 지금 playbook은 `ansible.builtin`만 쓰므로
collection 고정이 필요 없고, 실행 환경이 없는 상태에서 의존성 목록을 만들면 검증되지 않은
선언이 생긴다.

첫 실행을 한 playbook으로 처리하지 않는다. driver 설치·재부팅 뒤에는 실제 kernel과
`nvidia-smi`를 다시 읽어야 하므로 `30-gpu-runtime`을 분리하고, tailnet 등록은 사람이 하는
일이라 `20-tailscale`을 설치까지만으로 끊는다. 각 단계는 성공 증거를 남기지만 민감값·
prompt·모델 token을 로그에 남기지 않는다.

## Ansible이 해도 되는 일

| 단계 | 허용 작업 | 다음 단계로 가는 증거 |
| --- | --- | --- |
| `00-preflight` | OS·architecture·디스크 여유·메모리·swap·clock sync·인터페이스와 MTU·binary 존재의 **읽기 전용** 확인 | 루트 여유 20 GiB 이상, RAM 14 GiB 이상, 현재 MTU와 미설치 binary 목록 |
| `10-base` | swap 비활성화, kernel module·sysctl 준비, containerd 설치와 `SystemdCgroup=true`, 저장소 목록(`apt-cache madison`)에서 확인한 version으로 kubeadm/kubelet/kubectl 고정 설치·hold | swap 0, sysctl 실효값 1, containerd socket, 넘긴 package version이 저장소에 있음 |
| `20-tailscale` | Tailscale 패키지 설치와 `tailscaled` 활성화 | binary 존재. **등록 상태는 미등록이 정상** |
| `30-gpu-runtime` | 검토한 driver branch 설치, 필요 시에만 재부팅, Container Toolkit 네 패키지 설치, containerd runtime 등록 | `nvidia-smi`로 GPU **정확히 1장**과 요청한 driver 분기 확인 |
| `40-join-preflight` | binary·kube 버전(API server 기준 skew: 같은 minor, kubelet patch ≤ API server)·swap·containerd socket/cgroup·API 6443 도달성·host 방화벽·token 환경변수 존재 여부의 **읽기 전용** 확인 | Join 전 네트워크 행렬을 실행할 수 있는 상태 |

`10-base`와 `30-gpu-runtime`은 실제 값을 넘겨야 동작한다(`gpu_kubernetes_minor`,
`gpu_kubernetes_package_version`과 설치 전 patch 판정용 `api_server_version`, `nvidia_driver_branch`,
`nvidia_container_toolkit_version`).
`40-join-preflight`는 `api_server_version`과 `control_plane_kubelet_version`이 없으면 실패한다 —
각 값의 의미는 `ansible/gpu-node/README.md` "버전 입력의 의미와 Join 판정"에 있다.
비어 있으면 해당 단계를 건너뛰고 그 사실을 출력한다 — 추측한 패키지 버전으로 설치하지 않는다.

driver 분기는 **570 LTS**다. 580이 아닌 이유는 vLLM image 자신의 `NVIDIA_REQUIRE_CUDA`가
580을 허용 분기로 열거하지 않기 때문이며 근거는 [Join 계획 §4](vllm-node-join-plan.md)에 있다.

### `--check`가 실제로 검사하게 만든 것

`ansible.builtin.command`는 `--check`에서 건너뛰어진다. 읽기와 쓰기를 모두 `command`로 두면
`--check` 실행이 아무것도 확인하지 못한 채 통과로 보인다. 그래서 상태를 **읽는** task에는
`check_mode: false`를 붙여 check mode에서도 실행하고, **바꾸는** task는 그 결과를 `when`
조건으로 삼고, 판정은 `command` 결과가 아니라 `assert`로 한다.

`04-kubernetes-packages`는 `kubelet`을 설치해도 worker를 Join하지 않는다. Tailscale 패키지
설치도 가능하지만 `tailscale up --auth-key=...`, subnet-route 수락, ACL 변경은 이 playbook에서
실행하지 않는다. 해당 값은 단기 비밀·네트워크 승인에 해당하며, [vLLM 노드 Join 계획](vllm-node-join-plan.md)의
실행 시점 게이트에서 별도로 처리한다.

## Ansible이 하면 안 되는 일

- `kubeadm join` 또는 JoinConfiguration에 token/CA hash를 기록하는 일
- `tailscale up`에 auth key를 전달하거나 subnet router의 SNAT/광고 route를 바꾸는 일
- AWS Security Group, VPC route, Tailnet ACL을 바꾸는 일
- NVIDIA device plugin, DCGM, vLLM, NetworkPolicy를 `kubectl apply`하는 일
- 모델 다운로드, Hugging Face token 저장, vLLM 서비스 기동
- GPU Node taint를 제거하거나 일반 workload 배치를 허용하는 일

이들은 각각 Join 직전의 일회용 자격증명, Tailnet 경로 검증, 또는 GitOps가 소유한
Kubernetes 선언이다. Ansible에 넣으면 재실행 편의와 승인 경계가 충돌한다.

## NetworkPolicy와의 접점

Ansible은 Kubernetes NetworkPolicy를 만들지 않는다. Join 후 GitOps가 다음을 소유한다.

1. `persona-inference` namespace의 default-deny
2. `persona-app/persona-gateway`에서 vLLM Pod TCP 8000으로 가는 egress
3. Gateway ingress와 별개인 `monitoring` Prometheus의 vLLM `/metrics` TCP 8000 ingress
4. DCGM exporter TCP 9400의 monitoring ingress

특히 vLLM API와 `/metrics`는 같은 TCP 8000을 쓰므로 monitoring 허용을 Gateway 허용으로
대체할 수 없다. 두 주체가 같은 포트에 접근하지만 목적·수명·허용 범위가 다르다.

## 실제 실행 전 체크포인트

1. AWS quota·AMI·AZ·CIDR·비용과 Terraform saved plan을 사람이 확인한다.
2. EC2 생성 후 임시 SSH `/32`로 Ansible `01-base`만 실행한다.
3. `02-nvidia` 실행과 재부팅 뒤 `nvidia-smi`를 확인한다.
4. `03-containerd`, `04-kubernetes-packages`, `05-preflight`를 순서대로 실행한다.
5. Tailscale 등록과 SNAT-off subnet route를 수동으로 설정하고, Join 계획의 6443·10250·8472·MTU
   양방향 행렬을 통과시킨다.
6. 그 시점에만 CP에서 짧은 TTL Join token을 만들고 tmpfs JoinConfiguration으로 Join한다.
7. GPU Node taint를 유지한 채 device plugin → GPU smoke → NetworkPolicy → vLLM 순서로 GitOps
   수동 Sync한다.

## 구현 착수 조건

playbook 골격을 만들기 전에 아래 네 값은 아직 실제값이 아니라는 점을 유지한다.

- 정확한 Ubuntu package repository와 NVIDIA driver patch
- control plane의 실제 Kubernetes minor·patch
- 실제 SSH 접근 사용자와 접속 IP
- 실제 Tailnet IP·auth key·subnet route 승인 상태

따라서 지금은 이 문서와 파일 구조만 준비해도 충분하다. 이 네 값이 확인된 뒤에도
`ansible-playbook --check` → 단계별 실제 실행 → 각 단계 증거 확인 순서를 지킨다.
