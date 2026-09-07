# 홈 클러스터 인벤토리 (persona-platform Loop 1)

측정일 2026-09-07. AWS GPU 워커 조인 **이전** 상태.

## 노드

| 노드 | 역할 | vCPU | MEM | Pod CIDR | IP |
| --- | --- | --- | --- | --- | --- |
| `k8s-cp` | control-plane | 2 | 3.8 GiB | 10.244.0.0/24 | 192.168.50.101 |
| `k8s-worker1` | worker | 4 | 9.7 GiB | 10.244.1.0/24 | 192.168.50.102 |
| `k8s-worker2` | worker | 2 | 5.8 GiB | 10.244.2.0/24 | 192.168.50.99 |

공통: Ubuntu 24.04.4 · 커널 **6.8.0-137** · containerd 2.2.1 · Kubernetes **v1.36.2**

- Cluster Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/12`
- 커널 6.8은 Cilium 요구 조건(5.10+)을 여유 있게 만족한다
- **워커 합계는 6 vCPU / 15.5 GiB뿐이다.** 이 프로젝트의 모든 상태 저장 서비스가 여기 들어간다
- 컨트롤 플레인은 2 vCPU / 3.8 GiB로 여유가 없다. **워크로드를 CP에 스케줄하지 않는다** —
  etcd fsync 지연이 곧바로 나빠지고, 그건 우리가 관측하려는 신호 자체를 오염시킨다

## StorageClass — 제약이 세다

```
local-path (default) · rancher.io/local-path
RECLAIM=Retain · BINDING=WaitForFirstConsumer · EXPANSION=false
```

| 속성 | 결과 |
| --- | --- |
| `Retain` | PVC를 지워도 PV와 **노드 디스크의 디렉토리가 남는다**. 노드에서 수동 정리 필요. 남은 PV는 `Released`가 되어 재사용되지 않는다 |
| `WaitForFirstConsumer` | 파드가 스케줄된 노드에 볼륨이 생긴다. 이후 그 파드는 **영구히 그 노드에 고정**된다 |
| **`EXPANSION=false`** | **PVC를 나중에 늘릴 수 없다.** 가득 차면 새 PVC를 만들어 데이터를 옮기는 수밖에 없다 |
| CSI 스냅샷 | 미지원 → CNPG volume snapshot 백업 경로 없음. 논리 덤프만 가능 |

**따라서 모든 PVC 크기는 지금 확정해야 하며, 나중에 고칠 수 없다.**

## Proxmox 호스트 (`pve`) 실측

AMD Ryzen 7 7840HS — 8코어 / **16스레드**, RAM **28 GiB**, swap 8 GiB (미사용), load ~0.4

| VM | vCPU | RAM | 디스크 | 스냅샷 |
| --- | --- | --- | --- | --- |
| 101 `k8s-cp` | 2 | 4 GiB | 55 GB | `after-mlflow` |
| 102 `k8s-worker1` | 4 | 10 GiB | 80 GB | `after-mlflow` |
| 103 `k8s-worker2` | 2 | 6 GiB | 70 GB | `after-mlflow` |
| **합계** | **8 / 16** | **20 / 28 GiB** | 205 GB (풀 349 GiB) | |

전 VM `cpu: host`, `balloon` 미설정(고정 메모리) — 지연 측정에 유리하다. 유지한다.

### RAM이 유일한 병목이다

`free -h`의 "12 GiB used"는 **과소 표시다.** KVM은 게스트가 실제로 건드린 페이지만
할당하는데, VM들이 최근 재부팅되어 게스트 page cache가 비어 있다. 시간이 지나면
할당량인 20 GiB에 수렴한다. 따라서 판단 기준은 `free`가 아니라 **할당 합계**다.

- 할당 20 GiB + Proxmox 호스트 오버헤드 ~1.5 GiB ≈ **21.5 GiB 커밋됨**
- 물리 28 GiB → **실질 여유 약 6 GiB**

**RAM은 절대 오버커밋하지 않는다.** 스왑이 시작되는 순간 TTFT·RTT·PMTU 측정이
전부 무의미해진다. 이 프로젝트가 측정하려는 신호가 정확히 그것이다.

vCPU는 16스레드 중 8개만 쓰고 있어 여유가 크다. 디스크도 풀 349 GiB 중 236 GiB 여유다.

## VM 리소스 조정 (D0 Phase 2에서 수행)

| VM | 현재 | **목표** | 근거 |
| --- | --- | --- | --- |
| `k8s-cp` | 2 vCPU / 4 GiB / 55 GB | **유지** | 3노드 클러스터 etcd·apiserver에 충분 |
| `k8s-worker1` | 4 vCPU / 10 GiB / 80 GB | 4 vCPU / 10 GiB / **120 GB** | RAM은 예산에 맞음. 디스크만 확장 |
| `k8s-worker2` | 2 vCPU / 6 GiB / 70 GB | **4 vCPU / 8 GiB** / **100 GB** | 관측 스택 + 경량 stateless |
| 조정 후 합계 | | **10 / 16 vCPU · 22 / 28 GiB · 275 GB** | 호스트에 ~4.5 GiB 여유 |

**worker2를 12 GiB로 올리지 않는 이유**: VM 합계가 26 GiB가 되어 Proxmox 호스트에
2 GiB밖에 남지 않는다. 스파이크 여유가 없고 스왑 위험이 생긴다. 8 GiB로도 충분하다 —
아래 예산 참고.

## D0 실행 결과 (2026-09-07)

### reset 회수량

| 노드 | reset 전 여유 | reset 후 여유 |
| --- | --- | --- |
| worker1 | 31 GiB | **67 GiB** |
| worker2 | 21 GiB | 58 GiB → 확장 후 **86 GiB** |
| k8s-cp | — | 43 GiB |

### thin pool — `discard=on`이 결정적이었다

VM 디스크에 `discard` 옵션이 없어 게스트에서 지운 블록이 풀로 반환되지 않고 있었다.
활성화 후 `fstrim -av` 결과:

| | 전 | 후 |
| --- | --- | --- |
| local-lvm 사용 | 105 GiB (28.80%) | **16.5 GiB (4.74%)** |
| 여유 | 248 GiB | **332 GiB** |

**약 88 GiB가 유령 블록이었다.** 오버커밋 경고(프로비저닝 410 GiB vs 풀 349 GiB)는
실제 소비가 16.5 GiB이므로 무해하다. 단, 이 조건은 discard가 계속 동작할 때만 유지된다.

- 전 VM에 `discard=on,ssd=1` 적용 완료
- 게스트의 `fstrim.timer`가 도는지 확인할 것 (Ubuntu 기본 주간)
- **thin pool 사용률은 클러스터 밖 신호다.** Prometheus가 직접 못 보므로 node-exporter
  textfile collector 등으로 끌어와야 한다. 여기가 차면 VM 3대가 동시에 쓰기 불능이 된다

### 최종 VM 사양

| VM | vCPU | RAM | 디스크 | 비고 |
| --- | --- | --- | --- | --- |
| `k8s-cp` | 2 | 4 GiB | 55 GB (여유 43 GiB) | 변경 없음 |
| `k8s-worker1` | 4 | 10 GiB | 80 GB (여유 67 GiB) | **확장 불필요** — reset 회수로 충분 |
| `k8s-worker2` | **4** | **8 GiB** | **100 GB** (여유 86 GiB) | 확장 완료 |

합계 10/16 vCPU · 22/28 GiB · 235 GB 프로비저닝. 호스트 swap 0 확인.

## 노드 역할 배치 (확정)

local-path가 파드를 노드에 고정하므로, 무엇을 어디에 둘지가 곧 장애 범위다.
데이터 계층과 관측 계층을 **다른 노드로 분리**해서, 한쪽 장애가 다른 쪽 진단 수단을
같이 앗아가지 않게 한다.

| 노드 | 담당 | 이유 |
| --- | --- | --- |
| `k8s-worker1` | **데이터** — CNPG, Qdrant, private corpus, ingestion Job | corpus·serving SoT가 여기 |
| `k8s-worker2` | **관측** — Prometheus, Tempo, Grafana, OTel Collector | 데이터 노드가 흔들려도 원인을 볼 수단이 남는다 |
| **미확정** | Traefik, persona-gateway, persona-web, Argo CD | 아래 참고 |
| AWS GPU worker | **vLLM만** | 상태 저장 서비스 0개 |
| `k8s-cp` | 스케줄 금지 | etcd 보호 |

### stateless 앱 배치 (확정)

worker2를 4 vCPU / 8 GiB로 증설하면 **관측 우선 + 경량 stateless 허용**이 성립한다.

| 노드 | 현재 실측 | 추가 예정 | 예상 합계 | allocatable |
| --- | --- | --- | --- | --- |
| worker1 | 0.74 GiB | CNPG 1.1 + Qdrant 1.0 + Argo CD 1.5 | **~4.4 GiB** | ~9 GiB |
| worker2 | 0.76 GiB | Prometheus 2.0 + Tempo 1.0 + Grafana 0.3 + Collector 0.2 + Traefik/gateway/web 0.45 | **~4.8 GiB** | ~7 GiB |

양쪽 모두 2 GiB 이상 여유가 남는다. worker2를 8 GiB로 정한 결정이 유효함을 실측이 확인했다.

양쪽 모두 여유가 남는다. Argo CD를 worker1에 두어 균형을 맞춘다 (PVC가 없어 배치가 자유롭다).

### PriorityClass 정책

관측이 흔들리면 실험 결과를 믿을 수 없다. 자원 압박 시 축출 순서를 의도대로 고정한다.

| 계층 | PriorityClass | requests |
| --- | --- | --- |
| 관측 (Prometheus, Tempo, Collector) | **높음** | 명시적으로 설정 — 실측 후 확정 |
| 데이터 (CNPG, Qdrant) | **높음** | 명시적으로 설정 |
| stateless (Traefik, gateway, web, Grafana) | **낮음** | 가볍게 |

D1 완료 조건에 **축출 순서가 의도대로 동작하는지 확인**을 포함한다.

## 실측 기준선 (2026-09-07, Phase 5 중반)

Cilium · CoreDNS · local-path · metrics-server만 올라간 상태.

| 노드 | CPU | 메모리 | 비율 |
| --- | --- | --- | --- |
| `k8s-cp` | 54m (2%) | **1310 Mi** | 34% |
| `k8s-worker1` | 22m (0%) | **739 Mi** | 7% |
| `k8s-worker2` | 27m (0%) | **761 Mi** | 9% |

주요 파드:

| 파드 | 메모리 |
| --- | --- |
| `kube-apiserver` | 318 Mi |
| `cilium` (노드당) | 85–92 Mi |
| `kube-controller-manager` | 54 Mi |
| `etcd` | 45 Mi |
| `cilium-operator` | 34 Mi |
| `kube-scheduler` | 23 Mi |
| `metrics-server` | 17 Mi |
| `cilium-envoy` (노드당) | 13–14 Mi |

### 추정치 보정

- **Cilium을 노드당 300 Mi로 잡았으나 실제는 ~100 Mi** (agent 90 + envoy 14). 3배 과대추정
- CPU는 전 노드 합쳐 100m 미만. 이 규모에서 CPU는 제약이 아니다
- **`k8s-cp`가 비율상 가장 빡빡하다** (34%). 컨트롤 플레인 컴포넌트만으로 1.3 GiB.
  taint 유지 결정이 옳았음을 실측이 뒷받침한다

## 메모리 예산 (실측 보정 후)

Airflow / MLflow / postgresql-0 삭제를 전제로 한다. 이 셋이 없으면 여유가 생기고,
그대로 두면 아래 스택이 들어갈 자리가 없다.

| 구성 요소 | 추정 | 배치 |
| --- | --- | --- |
| Argo CD (7 파드) | ~1.5 GiB | 자유 |
| Cilium agent × 2 워커 + operator | **~0.25 GiB** (실측 기반) | 전 노드 |
| CNPG operator + Postgres 1 인스턴스 | ~1.1 GiB | worker1 |
| Qdrant | ~1.0 GiB | worker1 |
| Prometheus | ~2.0 GiB | worker2 |
| Tempo (monolithic) | ~1.0 GiB | worker2 |
| Grafana | ~0.3 GiB | worker2 |
| OTel Collector | ~0.2 GiB | 자유 |
| Traefik | ~0.15 GiB | 자유 |
| persona-gateway / persona-web | ~0.3 GiB | 자유 |
| kube-state-metrics / node-exporter / metrics-server | ~0.3 GiB | 자유 |
| **합계** | **~8.0 GiB** | (워커 allocatable ~16 GiB) |

**들어간다. 다만 여유가 크지 않다.** 두 가지를 지켜야 한다.

- Prometheus는 보수적으로 — scrape interval 30s, retention **시간과 용량 둘 다** 상한
- worker2는 2 vCPU에 Prometheus + Tempo + Grafana가 함께 올라간다. 룰 평가와 트레이스
  수집이 겹치는 순간이 CPU 병목 지점이다. 트레이스 샘플링 비율을 반드시 정한다

## 디스크 — 실측

| 노드 | 디스크 | 파일시스템 | 사용 | **여유** |
| --- | --- | --- | --- | --- |
| `k8s-worker1` | sda 80 GB | 77 GiB | 43 GiB (59%) | **31 GiB** |
| `k8s-worker2` | sda 70 GB | 67 GiB | 44 GiB (69%) | **21 GiB** |

Proxmox host `pve`:

| 스토리지 | 종류 | 전체 | 사용 | 여유 |
| --- | --- | --- | --- | --- |
| `local` | dir | ~94 GiB | 8.6 GiB (9%) | **~80 GiB** |
| `local-lvm` | lvmthin | ~349 GiB | ~112 GiB (32%) | **~236 GiB** |

### 결론 1 — 현재 여유로는 계획한 볼륨이 안 들어간다

워커 합계 여유가 52 GiB뿐이다. 앞서 제안한 90 GiB는 들어가지 않는다.

### 결론 2 — 그러나 이것은 하이퍼바이저에서 고칠 수 있는 제약이다

`local-lvm`에 236 GiB가 남아 있고 thin provisioning이므로, VM 디스크를 키워도
실제로 쓴 블록만큼만 소비된다. **`EXPANSION=false`라 PVC는 나중에 못 늘리므로,
PVC 크기를 정하기 전에 VM 디스크부터 키우는 것이 올바른 순서다.**

VM 정지 없이 온라인 확장 가능:

```bash
# Proxmox host
qm resize <vmid> scsi0 +70G

# 해당 노드 안에서
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

thin pool은 과다 할당이 가능하므로, 늘린 뒤에도 `pvesm status`의 사용률을 주기적으로
확인해야 한다. 풀이 가득 차면 모든 VM이 동시에 쓰기 불능이 된다.

### 결론 3 — 정리로 회수되는 양이 상당할 것이다

워커 2대가 각각 43·44 GiB를 쓰고 있는데, 파드 수에 비해 과하다.
`vllm-test`와 `vllm-affinity-proof-*`가 받아둔 vLLM 컨테이너 이미지가 유력하다
(vLLM 이미지는 단독으로 10 GiB를 넘는다). 정리 전에 측정한다:

```bash
sudo crictl images --digests | head -30
sudo du -sh /var/lib/containerd
sudo du -sh /var/lib/kubelet
kubectl -n local-path-storage get cm local-path-config -o yaml   # 실제 저장 경로 확인
```

`/opt/local-path-provisioner`는 존재하지 않았다. 저장 경로가 기본값이 아니므로
ConfigMap에서 실제 경로를 확인한 뒤에야 PV 잔여물을 정리할 수 있다.

## PVC 크기 — 확장 불가이므로 한 번에 정한다

두 안을 둔다. **디스크를 키우는 A안을 권장한다.**

| 볼륨 | 노드 | A안 (디스크 확장 후) | B안 (현 상태 유지) |
| --- | --- | --- | --- |
| CNPG | worker1 | 20 GiB | 10 GiB |
| Qdrant | worker1 | 15 GiB | 5 GiB |
| private corpus (raw/parsed) | worker1 | 10 GiB | 5 GiB |
| 논리 백업 대상 | worker1 | 15 GiB | 5 GiB |
| Prometheus | worker2 | 25 GiB (retention.size 18 GiB) | 12 GiB (상한 8 GiB) |
| Tempo | worker2 | 10 GiB | 5 GiB |
| Grafana | worker2 | 2 GiB (무상태면 0) | 1 GiB |
| **합계** | | **97 GiB** | **43 GiB** |

실제 코퍼스는 작다 — 발화 수만 개면 텍스트는 수 MB, 임베딩도 수백 MB 수준이다.
공간을 먹는 것은 코퍼스가 아니라 **Prometheus·Tempo·컨테이너 이미지**다.
B안은 들어가지만 Prometheus 보존 기간을 먼저 희생하게 된다.

## 단일 장애 지점 — 명시해야 할 사실

`pvesm status`에 `local`과 `local-lvm`만 있다. 공유 스토리지도, 두 번째 호스트도 없다.
따라서:

- **k8s 노드 3대가 모두 같은 물리 머신의 VM이다**
- 모든 PV 데이터가 그 머신의 디스크에 있다
- 같은 노드·같은 호스트에 둔 "백업 PVC"는 백업이 아니다
- Proxmox VM 스냅샷도 같은 디스크에 있다 — 실수 복구용이지 재해 복구용이 아니다

**결론: 외부 암호화 사본은 선택이 아니라 v1 필수다.**

포트폴리오 서술에서도 정확히 적는다. "홈 워커 2대"는 물리 2대가 아니라 **한 호스트 위의
VM 2대**다. 노드 장애 실험은 VM 수준을 다루며 하드웨어 내결함성을 보이지 않는다.
`persona-ops-lab`이 "HA 또는 automatic recovery claim"을 제외 항목으로 둔 것과 일치한다.

## 확정된 결정

| 항목 | 결정 | 비고 |
| --- | --- | --- |
| 클러스터 | **재구축** (Kubernetes 계층만, Ubuntu 유지) | `cluster-reset-runbook.md` |
| 디스크 | **A안** — worker1 80→120 GB, worker2 70→100 GB | PVC 확정 전에 확장 |
| **오프사이트 백업** | **없음** | 단일 Proxmox 호스트 장애 시 전부 소실. 감수하는 리스크로 명시 |
| 논리 백업 | `pg_dump` CronJob은 유지 | 재해복구가 아니라 실수 복구용. D2 복구 리허설의 대상 |
| Grafana | **무상태** — provisioning 주입, DB `emptyDir` | Postgres 의존 없음. worker1 장애 시에도 대시보드 생존 |
| 실험 구간 표시 | Grafana annotation 대신 **Prometheus 게이지** | 측정 데이터와 같은 저장소. Grafana를 지워도 남음 |
| 트레이스 샘플링 | **head 100%** (v1) | 부하가 자체 생성이라 양이 통제됨 |
| OTel Collector | **포함** | 속성 필터링이 주 목적, tail sampling은 예비 |

### 포트폴리오 서술 주의

백업이 없으므로 "백업·복구 체계를 갖췄다"고 말하지 않는다. 대신 정확히 적는다 —
논리 덤프로 실수 복구는 가능하고, 호스트 장애에 대한 재해복구는 범위에 없다.
