# mem-lab — persona-mem-01 전용 일반 EC2 worker

상태: **선언 초안.** `terraform apply`를 실행한 적이 없고 EC2를 만든 적도 없다. 이 디렉터리에
파일이 있다는 것을 "노드가 존재한다"로 읽지 않는다.

## 목적

GPU 없이 MEM-01 메모리 압박 실험을 수행할 **단일 amd64 worker** 한 대를 준비한다. 홈
worker1·worker2에는 DB가 있어 일부러 메모리를 소진시키는 워크로드를 올릴 수 없다.

이 노드는 **미래 GPU Join의 저가 네트워크 리허설**도 겸한다. 같은 tailnet, 같은 Cilium overlay,
같은 `src_valid_mark` 문제, 같은 MTU 제약을 GPU 인스턴스 비용 없이 먼저 통과시켜 본다. 여기서
막히는 것은 GPU 노드에서도 막힌다.

`terraform/envs/prod`(GPU 기준선)를 **건드리지 않는다.** 공유 모듈을 만들지 않고 파일 세트를
독립적으로 둔다 — 지금 두 환경밖에 없는 상태에서 모듈을 뽑으면, 한쪽 실험 때문에 다른 쪽
기준선이 함께 바뀔 수 있는 결합이 생긴다.

## envs/prod와 의도적으로 다른 점

| 항목 | envs/prod (GPU) | mem-lab | 이유 |
| --- | --- | --- | --- |
| 인스턴스 | `g6.xlarge` | `t3a.medium` (4 GiB) | 아래 "왜 4 GiB인가" |
| 루트 볼륨 | gp3 100 GiB | gp3 30 GiB | 모델 cache가 없다 |
| CPU credit | 해당 없음 | `standard` | burstable이다. `unlimited`은 credit 소진 시 초과 요금이 자동으로 붙는다 |
| `prevent_destroy` | **있음** | **없음** | 아래 "왜 prevent_destroy를 두지 않는가" |
| `reserved_cidrs` | 없음 (정규식 모양 검사만) | **필수 입력 + 겹침 계산** | 아래 "CIDR 겹침 게이트" |

같은 것: IMDSv2 required·hop limit 1·metadata tags disabled, instance profile 없음,
`user_data` 없음, public inbound 기본 차단, encrypted gp3, 게스트 shutdown은 stop.

### 왜 4 GiB인가 (feedback의 `t3a.large`에서 벗어난 값이다)

지시서 원문은 `t3a.large`(8 GiB)였다. 4 GiB로 바꾼 것은 **실험이 성립하려면 그래야 하기
때문이다**: lab consumer가 64Mi 단위로 상한 3584Mi(limit 3712Mi)까지 올라가도록 이미 선언돼
있어, 8 GiB 노드에서는 상한까지 올려도 kubelet이 `MemoryPressure`를 선언하지 않는다. 그 결과는
"축출이 일어나지 않았다"가 아니라 **압박 주입 실패**이고, 그것을 모른 채 기록하면 결론이
뒤집힌다. 사용자 결정으로 4 GiB에 맞췄다.

크기를 바꾸려면 consumer 단계 수와 **함께** 바꾼다. `tests/safety.tftest.hcl`과
`ansible/mem-lab-worker`의 `00-preflight`가 이 값을 위아래 모두 고정한다.

### 왜 `prevent_destroy`를 두지 않는가

GPU 인스턴스에는 있고 여기에는 없다. 의도한 차이다. 이 노드는 실험이 끝나면 제거하는 것이
정상 수명주기이고, 그 마지막 단계가 `terraform destroy`다(아래 "종료 절차"). `prevent_destroy`는
바로 그 단계를 막아, 절차를 따르는 사람이 코드를 고쳐야 destroy할 수 있는 상태를 만든다.

실수로 지우는 것을 막는 장치는 여기가 아니라 종료 절차의 **"lab Pod 없음 확인"** 단계다.

## CIDR 겹침 게이트

Terraform 1.14에는 두 CIDR의 겹침을 판정하는 함수가 없다(`cidrcontains`는 존재하지 않는다).
그래서 각 블록을 `[시작, 시작+크기)` 정수 구간으로 바꿔 직접 비교한다. `main.tf`의
`local.overlapping_reserved`가 그 계산이고, `aws_vpc.lab`의 `lifecycle.precondition`이 plan을
멈춘다.

`reserved_cidrs`는 **기본값 없는 필수 변수**다. home LAN과 Pod CIDR은 저장소에 기록이 있지만
**Service CIDR은 없다** — kube-dns가 `10.96.0.10`이라는 사실만으로 prefix 길이를 알 수 없다.
값을 추측해 고정하면 게이트가 실제보다 강해 보인다. 네 값을 어디서 읽는지는
`terraform.tfvars.example`에 적었다.

**증명하는 것**: 선언된 `vpc_cidr`가 `reserved_cidrs`의 어떤 항목과도 주소 구간이 겹치지 않는다.
경계 사례(바로 붙은 블록)와 정규화(호스트 비트가 남은 표기)까지 `terraform test`로 확인했다.

**증명하지 않는 것**: 실제 라우팅이 성립한다는 것. 이것은 **입력된 목록**과의 비교이며, tailnet
광고 경로나 홈 라우터의 실제 테이블을 읽지 않는다. 목록에서 빠진 경로와의 충돌은 잡지 못한다.

## public inbound

선언된 inbound는 두 개뿐이고, 기본값으로는 **둘 다 0개**가 되어 완전히 닫힌다.

- bootstrap SSH(TCP 22) — `bootstrap_ssh_cidr`에 관리자 공인 IP `/32`를 넣을 때만
- Tailscale 전송(UDP 41641) — `tailscale_peer_cidrs`에 피어 공인 IP `/32`를 넣을 때만

**API 6443, kubelet 10250, Cilium VXLAN 8472, NodePort 30000-32767은 열지 않으며, 변수로도 열 수
없다.** 그 트래픽은 tailnet WireGuard 터널 안에서만 흐르므로 VPC 경계에 구멍을 낼 이유가 없다.
`scripts/test-mem-lab-negative.sh`가 두 방향(테스트 단정 + 선언 파일 정적 검사)으로 강제한다.

## 비밀 경계

tailnet auth key, kubeadm join token, CA hash, 비밀번호를 `terraform.tfvars`, `user_data`,
Terraform state, output, Ansible inventory에 **넣지 않는다.**

`user_data`를 아예 두지 않는 이유: IMDS로 평문 조회되고 state에도 남는다. OS 준비는
`ansible/mem-lab-worker`가 SSH로 한다. instance profile도 없어 이 노드는 AWS API를 부르지 않는다.

## Join 직후 label과 taint

taint는 `kubeadm join` 명령의 `JoinConfiguration`에서 `nodeRegistration.taints`로 **처음부터**
등록한다. Join 뒤에 `kubectl taint`로 붙이면, 등록과 taint 사이의 구간에 일반 Pod가 이 노드로
스케줄될 수 있다. 이 노드는 일부러 메모리를 소진시키는 곳이라 그 구간을 남기지 않는다.

- label: `persona.runtime/role=eviction-lab`
- taint: `persona.runtime/eviction-lab=true:NoSchedule`

### prefix가 두 개가 되는 것에 대해

이 저장소의 기존 **노드** 라벨·taint 관례는 `personaruntime.xyz/`다(GPU node-pool과 dedicated
taint). `persona.runtime/`은 지금까지 migration Job **annotation**으로만 쓰였다. 위 두 키를
쓰면 노드 메타데이터에 prefix가 두 개 공존한다.

그래도 이 키를 쓰는 이유는 lab 매니페스트 쪽이 이미 이 값으로 작성돼 있고, 실험이 성립하려면
노드와 Pod가 **같은 키**를 봐야 하기 때문이다. 나중에 통일한다면 아래를 함께 고친다 — 한 곳만
고치면 Pod가 노드를 고르지 못한다.

1. lab 매니페스트의 `nodeSelector`와 `tolerations`
2. 이 문서와 아래 Join 명령
3. 이미 등록된 노드의 label·taint (재등록 없이 `kubectl label`·`kubectl taint`로 교체)

### taint를 넣기 전에 검증할 것 (순서가 중요하다)

`NoSchedule` taint는 **그것을 tolerate하지 않는 DaemonSet을 전부 막는다.** Cilium agent나
kube-proxy가 이 노드에 뜨지 못하면 노드가 `Ready`가 되지 않고, lab Pod도 뜨지 않는다.

`bootstrap/cilium/values.yaml`은 `tolerations` 키를 **설정하지 않는다**. 즉 chart 기본값에
의존한다. 기본값이 모든 taint를 tolerate하는 형태로 알려져 있지만, 여기서 그것을 전제하지 않고
**실제 렌더로 확인한다.**

```sh
# Cilium: 실제로 무엇이 tolerate되는지 렌더해서 본다
helm template cilium cilium/cilium --version <배포한 버전> \
  -n kube-system -f bootstrap/cilium/values.yaml \
  | yq 'select(.kind == "DaemonSet") | .spec.template.spec.tolerations'

# kube-proxy: kubeadm이 설치한 것이라 클러스터에서 직접 읽는다
kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.tolerations}'
```

`{"operator": "Exists"}`(키 없는 전체 tolerate)가 있으면 통과한다. 없으면 **taint를 빼지
않는다.** 해당 DaemonSet 선언에 이 taint에 대한 toleration을 먼저 더하고, 그 변경을 정상 경로로
반영한 뒤 Join한다. taint를 제거해 통과시키면 그 순간 이 노드의 격리가 사라지고, 일반 워크로드가
메모리 압박 실험 노드로 밀려 들어온다 — 막으려던 바로 그 상황이다.

Join 뒤 실제 배치도 확인한다.

```sh
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=persona-mem-01
# cilium과 kube-proxy Pod가 Running이어야 한다. Pending이면 위 toleration을 다시 본다.
```

## 관측 전제

`kube-prometheus-stack`의 node-exporter는 affinity가 control plane·worker1·worker2로 묶여 있어
**이 노드에는 배치되지 않는다.** 의도한 상태이며 MEM-01은 cAdvisor와 kube-state-metrics로
관측한다. 이 노드의 node 단위 지표가 Prometheus에 없는 것을 수집 실패로 읽지 않는다.

## 종료 절차

순서를 지킨다. 각 단계는 다음 단계가 무엇을 지우는지에 의존한다.

| # | 단계 | 건너뛰면 |
| --- | --- | --- |
| 1 | `kubectl cordon persona-mem-01` | 아래 단계 도중 새 Pod가 들어와 무엇이 축출이고 무엇이 정리인지 섞인다 |
| 2 | **lab Pod가 없음을 확인** | 남은 Pod가 노드와 함께 사라지면, 기록에서 그것이 **축출인지 삭제인지 구분할 수 없다**. 그 회차 데이터가 무효가 된다 |
| 3 | `kubectl delete node persona-mem-01` | API에 죽은 노드가 남아 이후 스케줄링 판단이 흐려진다 |
| 4 | host에서 `kubeadm reset` | 노드에 cluster 자격과 CNI 상태가 남는다. 같은 host를 다시 쓰면 오래된 상태로 Join한다 |
| 5 | tailnet 관리 화면에서 device 제거 | tailnet에 죽은 device와 광고된 route가 남는다. 다음 노드가 같은 100.x 주소를 받으면 경로가 엉킨다 |
| 6 | `terraform destroy` | 인스턴스가 살아 있어 시간당 비용이 계속 발생한다 |

2번이 이 절차의 안전장치다(`prevent_destroy`를 두지 않는 이유가 여기 있다).

```sh
# 2번 확인
kubectl get pods -A -o wide --field-selector spec.nodeName=persona-mem-01
# kube-system의 DaemonSet Pod만 남아 있어야 한다. lab Pod가 보이면 먼저 정리하고
# 그 결과(축출이었는지 수동 삭제였는지)를 실험 기록에 남긴다.
```

6번에서 루트 볼륨이 함께 사라진다(`delete_on_termination = true`). 노드의 journal과 kubelet
로그가 필요하면 **destroy 전에** 가져온다.

## 검증

```sh
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
# 저장소 루트에서
sh scripts/test-mem-lab-negative.sh
```

`terraform test`는 `mock_provider`를 쓰므로 AWS에 접속하지 않고 자원을 만들지 않는다.

### 검증하지 않은 것

- **실제 AWS 동작 전부.** `apply`를 실행한 적이 없다. AZ의 `t3a.medium` 제공 여부, 계정 한도,
  AMI 존재는 plan 시점에 실제 계정에서 확인해야 한다.
- **tailnet 경로, `kubeadm join`, Cilium overlay, Pod 간 통신.** 노드를 만들지 않았다.
- **`MemoryPressure` 도달 여부.** 4 GiB와 consumer 값의 조합이 실제로 압박을 만드는지는 실험
  당일 측정한다. 도달하지 않으면 "축출이 없었다"가 아니라 **압박 주입 실패**로 기록한다.
- **Ansible 전체.** 개발 환경에 `ansible`이 없어 `--syntax-check`와 `ansible-lint`를 돌리지
  못했다(`ansible/mem-lab-worker/README.md` 참고). `tflint`·`checkov`도 없다.
