# persona-mem-01 Ansible 골격 (MEM-01 메모리 압박 실험용)

상태: **실행 전 골격.** 이 디렉터리는 생성된 EC2 host를 `kubeadm join` 직전 상태까지 준비한다.
EC2 생성, tailnet 등록, `kubeadm join`, Kubernetes 리소스 적용은 하지 않는다.

**실행한 적이 없다.** 이 저장소를 쓰는 개발 환경에 `ansible`이 설치돼 있지 않아
`--syntax-check`와 `ansible-lint`를 돌리지 못했다. YAML 파싱과 모듈 이름·인자만 수동으로
대조했다. 실제 host에 쓰기 전에 두 검사를 먼저 통과시킨다.

## `ansible/gpu-node`와 왜 분리했는가

`ansible/gpu-node`를 재사용하지 않는다. 그 트리는 GPU driver와 container toolkit 설치를 전제로
하고, `00-preflight`의 binary 목록과 `40-join-preflight`가 가속기 도구의 존재를 확인한다.
이 노드에는 가속기가 없으므로 그 확인이 항상 실패하거나, 통과시키려고 검사를 무력화하게 된다.
두 노드의 준비 절차를 한 트리에 담으면 어느 쪽 전제가 깨졌는지 구분할 수 없다.

`scripts/test-mem-lab-negative.sh`가 이 분리를 강제한다 — `playbooks/` 안에 가속기 runtime
관련 토큰이 하나라도 들어오면 실패하고, playbook 파일 집합이 아래 네 개와 달라지면 실패한다.

## 실행 경계

번호는 10 단위로 띄운다. `gpu-node`의 `30-` 자리는 **의도적으로 비어 있다** — 이 노드에는
runtime 설치 단계가 없다는 것을 번호로 드러낸다.

| Playbook | 하는 일 | 하지 않는 일 |
| --- | --- | --- |
| `00-preflight.yml` | OS·architecture·**메모리 4 GiB 범위**·디스크 여유·swap·시계·MTU·cgroup v2·binary 상태 **읽기** | 어떤 설정도 변경하지 않음 |
| `10-base.yml` | swap off, kernel module, Kubernetes sysctl, **`src_valid_mark=0` 부팅값**, containerd·kubeadm·kubelet·kubectl 준비·hold | Tailscale 등록, Join |
| `20-tailscale.yml` | Tailscale 패키지 설치, tailscaled 활성화, **`src_valid_mark` 재적용 drop-in** | `tailscale up`, auth key 전달, route 광고·수락, SNAT |
| `40-join-preflight.yml` | Join 직전 binary·버전·swap·containerd·`src_valid_mark`·tailnet L3·6443·4240·MTU·node-ip **읽기** | `kubeadm join`, token·CA hash 수신·저장 |

## 메모리 4 GiB를 검사로 고정한 이유

`00-preflight`가 `MemTotal`의 **위아래를 모두** 막는다. 아래쪽은 흔한 검사지만 이 실험에서는
위쪽이 더 중요하다. 노드가 계획보다 크면 lab consumer가 선언된 상한까지 올라가도 kubelet이
`MemoryPressure`를 선언하지 않는다. 그 결과는 "축출이 일어나지 않았다"가 아니라 **압박 주입
실패**이고, 그것을 모른 채 기록하면 실험 결론이 뒤집힌다.

## `src_valid_mark=0` — 취향이 아니라 측정된 필수 설정

Tailscale은 기동할 때 `net.ipv4.conf.all.src_valid_mark`를 1로 켠다. 그런데 Cilium이 L7/DNS
프록시를 쓰면 프록시 패킷에 fwmark가 붙고, 출발지 검증이 그 mark를 포함해 별도 라우팅 테이블을
조회하면서 Pod 출발지를 로컬 주소로 오인한다. 커널은 그 패킷을 `IP_LOCAL_SOURCE`로 버리는데
**로그도 카운터도 남지 않는다**(cilium/cilium#48706). 증상은 "DNS가 간헐적으로 안 된다"로만
보인다. 홈 3노드는 이미 0으로 고정돼 있고, 이 노드도 같은 tailnet·같은 Cilium 위에 붙는다.

**장치가 두 개인 이유**: 서로 다른 시점을 맡는다.

| 장치 | 담당 시점 | 없으면 |
| --- | --- | --- |
| `/etc/sysctl.d/99-cilium-srcmark.conf` (10-base) | 부팅 시점 값 | 재부팅 직후 tailscaled가 뜨기 전 구간에서 1 |
| `tailscaled.service.d/10-cilium-srcmark.conf` (20-tailscale) | tailscaled 기동 뒤 재적용 | tailscaled가 기동하며 1로 되돌림 |

**이미 실패한 두 가지를 다시 시도하지 않는다**(홈 노드 적용 기록):

1. `ExecStartPost`로 **한 번만** 0을 쓰는 방식 — tailscaled가 그보다 늦게 1로 켜서 소용이
   없었다. 그래서 일정 시간(기본 30초) 반복한다.
2. `TS_DISABLE_SRC_VALID_MARK` 환경변수 — tailscale 1.102.2에서 아무 효과가 없었다. 이 값을
   읽는 코드 경로가 없다.

알려진 비용: 재적용 루프가 끝날 때까지 `systemctl restart tailscaled`가 30초 동안 반환하지
않는다. 막아야 할 값이 아니라 예상해야 하는 값이다.

남는 위험: tailscaled가 30초 이후에 다시 1로 켜는 경로가 생기면 재발한다. 정기 점검 항목이다.

## 재부팅 뒤 유지를 어떻게 "확인"하는가

선언 파일이 있다는 것은 유지의 증거가 아니다. 선언을 쓴 뒤 한 번도 재부팅하지 않았다면 그
경로는 검증되지 않았다. `40-join-preflight`는 `/proc/stat`의 `btime`과 두 선언 파일의 수정
시각을 비교해, **부팅이 선언보다 나중일 때만** 통과시킨다. 아니면 "재부팅하고 다시 돌려라"로
실패한다. 그래서 순서가 `tailscale up` → **재부팅** → `40-join-preflight`다.

## `--check`가 실제로 무엇을 검사하는가

`ansible.builtin.command`는 기본적으로 `--check`에서 **건너뛰어진다**. 읽기와 쓰기를 모두
`command`로 두면 `--check` 실행이 아무것도 검사하지 못한 채 통과로 보인다.

- **상태를 읽는 task**: `check_mode: false` + `changed_when: false` → `--check`에서도 실행된다.
  host를 바꾸지 않으므로 안전하다.
- **바꾸는 task**: 위에서 읽은 상태를 `when` 조건으로 삼는다 → 두 번째 실행에서 건너뛰고,
  `--check`에서는 "무엇이 바뀔지"가 실제 상태 기준으로 보인다.
- **검증**: `command` 결과가 아니라 `assert`로 판정한다 → `--check`에서도 발동한다.

## 멱등성

두 번째 실행에서 재시작이나 재설치가 일어나지 않는다.

- kernel module: `/proc/modules`를 읽어 **빠진 것만** `modprobe`
- sysctl: 두 선언 파일 중 하나라도 **바뀐 경우에만** `sysctl --system`, 실효값은 `assert`
- swap: `swaptotal_mb > 0`일 때만 `swapoff`
- tailscaled drop-in: 파일이 **바뀐 경우에만** `daemon-reload`와 재시작
- containerd 기본 설정: `creates:`로 이미 있으면 생성하지 않음

## 비밀 경계

inventory와 vars에는 공인 IP·SSH 사용자명·tailnet 주소만 둔다. 다음은 **어디에도** 넣지
않는다 — inventory, vars, playbook, 출력, 셸 인자.

- Tailscale auth key → 사람이 host에서 `tailscale up` 실행 시 직접 입력
- kubeadm join token·CA hash → `40-join-preflight.yml`은 환경변수가 **비어 있지 않은지만** 보고
  값을 읽지 않는다. 유효성·만료도 확인하지 않는다(그건 Join 명령이 판정한다)
- AWS credential → 이 host는 AWS API를 부르지 않는다(instance profile도 없다)

## 현재 가능한 검사

```bash
# 먼저 ansible을 설치한 환경에서
ansible-playbook -i inventory.example.yml playbooks/00-preflight.yml --syntax-check
ansible-lint playbooks/

# 예시 inventory는 접속할 수 없는 합성 IP(TEST-NET-3)라 실행은 연결 단계에서 실패한다.
```

실제 실행은 EC2 생성 뒤 사용자가 만든 로컬 inventory로만 한다. 변경 playbook은 `--check`를
먼저 돌린 뒤 사람이 결과를 확인하고 실행한다.

## 실행 순서와 사람이 끼어드는 지점

```text
00-preflight  →  10-base  →  20-tailscale
              →  [사람: tailscale up + tailnet에서 route 승인]
              →  [사람: 재부팅 — src_valid_mark 유지 확인을 위해 필요하다]
              →  40-join-preflight  →  [사람: kubeadm join + label·taint]
              →  [사람: Join 뒤 확인 행렬 — 10250·VXLAN·CoreDNS·Pod MTU]
```

`10-base`와 `40-join-preflight`는 실제 값을 넘겨야 전부 동작한다. 비어 있으면 해당 확인을
건너뛰고 그 사실을 출력한다 — 추측한 값으로 진행하지 않는다.

| 넘길 값 | 어디서 읽는가 |
| --- | --- |
| `mem_kubernetes_minor` (예: `1.36`) | apt 저장소 등록용 minor |
| `mem_kubernetes_package_version` (예: `1.36.4-1.1`) | `apt-cache madison kubelet`에서 API server patch를 넘지 않는 값 |
| `mem_api_server_version` (예: `v1.36.4`) | CP에서 `kubectl version -o json`의 `serverVersion.gitVersion` — **버전 게이트의 기준값. `10-base`와 `40-join-preflight`가 모두 쓴다** |
| `mem_control_plane_tailnet_ip` | CP의 **tailnet** 주소(100.x). LAN 주소를 넣으면 tailnet 경로를 확인하는 의미가 없다 |
| `mem_intended_node_ip` | 이 노드가 `--node-ip`로 쓸 tailnet 주소 |
| `mem_control_plane_kubelet_version` (예: `v1.36.2`) | CP kubelet. **drift 기록용이며 판정 기준이 아니다** |

## 버전 게이트의 기준은 API server다

kubelet version skew 정책이 정하는 상한은 **API server** 버전이다. CP kubelet이 아니다. 같은
클러스터에서도 CP kubelet과 API server의 patch는 다를 수 있어, CP kubelet을 기준으로 삼으면
허용되는 조합을 막거나 막아야 할 조합을 통과시킨다. CP kubelet과의 차이는 출력만 하고 판정에
쓰지 않는다.

규칙 세 가지다.

1. 노드 `kubeadm`·`kubelet`의 major.minor가 API server와 같다.
2. 노드 `kubelet` patch가 API server patch **이하**다(kubelet은 API server보다 새로울 수 없다).
3. CP kubelet과의 차이는 drift로 출력만 한다.

`10-base`가 `mem_kubernetes_package_version`으로 patch까지 고정해 설치하고, **설치 전에 같은
기준으로 한 번 더 막는다.** 두 경로를 모두 닫아야 하기 때문이다.

| 경로 | 무엇이 들어오는가 | 막는 곳 |
| --- | --- | --- |
| 고정하지 않음 | 저장소의 최신 patch(API server보다 새로울 수 있다) | `10-base`가 설치하지 않고 이유를 출력 |
| 잘못된 값으로 고정 | 넘긴 값 그대로. 저장소에 있으니 설치는 성공한다 | `10-base`의 설치 전 skew 단정 |

두 번째 경로를 설치 전에 막는 이유: API server가 `v1.36.4`인데 `1.36.5-1.1`을 넘기면 저장소에
그 값이 있으니 설치가 성공하고, `40-join-preflight`에 가서야 거부된다. 그때는 이미 노드에 새
kubelet이 깔려 있어 되돌리는 작업이 추가로 필요하다. 저장소가 조건에 맞는 patch를 내놓지
않으면 설치하지 않고 멈춘다. `mem_api_server_version` 없이 patch를 고정하려 하면 그 자체로
실패한다 — 대조 기준이 없으면 허용 범위인지 판단할 수 없다.

요청한 값이 저장소에 실제로 있는지도 `apt-cache madison`으로 확인한다.

**부분 문자열로 비교하지 않는다.** 이전 판은 `CP버전 in stdout` 형태였고 두 가지가 틀렸다 —
`v1.36.2`가 `v1.36.21`에도 포함되어 patch가 19 앞선 kubelet이 통과했고, `kubeadm`과 `kubelet`
출력이 한 stdout에 붙어 있어 **둘 중 하나만** 맞아도 통과했다. 두 경우를 모두 재현한 뒤
major.minor 문자열 일치와 patch 숫자 비교로 바꿨다. patch는 `| int`로 캐스팅해 비교한다 —
문자열로 두면 `"4" > "21"`이 되어 게이트가 막아야 할 경우를 통과시킨다.

## 이 골격이 확인하지 못하는 것

`40-join-preflight` 통과는 "Join을 실행할 수 있다"까지다. 아래 네 가지는 Join 전에 확인할 수
없어, playbook이 확인했다고 말하지 않고 Join 뒤 실행할 명령을 출력한다.

- **kubelet 10250 수신** — control plane → 이 노드 방향이다. 이 노드에서 자기 포트로 접속하는
  것은 loopback이라 tailnet을 지나지 않아 같은 확인이 아니다. CP에서 확인한다.
- **Cilium VXLAN UDP 8472** — UDP는 연결이 없어 TCP처럼 "열렸다"를 확인할 수 없고, 이 노드에
  Cilium agent가 아직 없어 응답할 상대도 없다.
- **CoreDNS 질의** — Pod netns 안에서만 의미가 있다.
- **Pod-to-Pod MTU** — 위와 같다. underlay(tailscale0 **1280**)가 전부 맞아도 Pod route
  (**1230**)에서 깨질 수 있다. 두 숫자는 다른 계층이며 섞지 않는다.

## 관측에 대한 전제

`kube-prometheus-stack`의 node-exporter는 affinity가 control plane·worker1·worker2로 묶여
있어 **이 노드에는 배치되지 않는다.** 의도한 상태이며, MEM-01은 cAdvisor와
kube-state-metrics로 관측한다. 이 노드의 node 단위 지표가 Prometheus에 없는 것을 수집 실패로
읽지 않는다.
