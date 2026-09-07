# 클러스터 재구축 런북 (D0)

D1(스토리지·DB) 이전에 실행한다. **되돌릴 수 없는 단계가 있으므로 순서를 지킨다.**

## 확정된 결정

| 항목 | 결정 |
| --- | --- |
| 경로 | **재구축** — `kubeadm reset` 후 재설치 (Ubuntu는 유지) |
| CNI | **Cilium** — flannel은 아예 설치하지 않는다 |
| kube-proxy | **유지** (대체 기능은 v1에서 켜지 않는다) |
| 인그레스 | **Traefik + Gateway API** — ingress-nginx 제거 |
| 디스크 | **A안** — VM 디스크 확장 후 PVC 크기 확정 |
| 기존 워크로드 | Airflow / MLflow / postgresql-0 / 실험 네임스페이스 **전부 삭제** |

재구축은 **Kubernetes 계층만** 다시 세운다. Ubuntu를 새로 설치하지 않는다.
`kubeadm reset` + CNI 잔여물 제거 + 이미지 정리로 충분하며, OS 재설치는 시간 대비 이득이 없다.

---

## Phase 0 — 보존 (되돌릴 수 없는 것 먼저)

### 0-1. Argo CD가 바라보는 Git 레포를 확보한다 — 확인 완료

기존 클러스터는 **다른 프로젝트**의 GitOps 환경이다.

레포: `github.com/f-lab-edu/Market-Layer-Platform` · 브랜치 `develop`

| Application | path | auto-sync |
| --- | --- | --- |
| **`root-app`** | `infra/k8s/argocd/applications` | **prune + selfHeal** |
| `storageclass` | `infra/k8s/bootstrap/storageclass` | 없음 |
| `postgresql` | `infra/k8s/apps/platform/postgresql` | 없음 |
| `mlflow` | `infra/k8s/apps/platform/mlflow` | 없음 |
| `datalake` | `infra/k8s/apps/platform/datalake` | 없음 |
| `airflow` | (`.spec.source` 비어 있음 — 멀티소스 또는 Helm chart) | 없음 |
| `ingress-nginx` | (동일) | 없음 |

**결론 세 가지.**

1. **매니페스트는 전부 Git에 있다.** 클러스터를 부숴도 Market-Layer-Platform은
   레포에서 다시 배포할 수 있다. 잃는 것은 PV 데이터뿐이다
2. **`storageclass` 앱에 local-path의 0777 커스터마이즈가 들어 있다.**
   `infra/k8s/bootstrap/storageclass`에서 복원 가능하다 — 재설치 위험이 크게 줄었다
3. **`root-app`의 selfHeal + prune 때문에, 살아 있는 클러스터에서 네임스페이스를
   지우면 되살아난다.** 재구축 경로에서는 문제가 되지 않는다 (Phase 1·5 참고)

`airflow`와 `ingress-nginx`는 `.spec.source`가 비어 있다(멀티소스 또는 Helm chart 방식).
둘 다 삭제 대상이라 추적할 필요는 없고, 전체 정의는 `pre-reset/argocd-apps.yaml`에 남는다.

**재구축 후 살아남는 유일한 자산이다.** `local-path-config`에 Argo tracking-id가 붙어 있는 것으로
보아 인프라 매니페스트가 Git에 있다. 레포 위치와 경로를 먼저 확인한다.

```bash
kubectl get applications -n argocd -o custom-columns=\
NAME:.metadata.name,REPO:.spec.source.repoURL,PATH:.spec.source.path,\
REV:.spec.source.targetRevision,AUTO:.spec.syncPolicy.automated

kubectl get applications -n argocd -o yaml > pre-reset/argocd-apps.yaml
kubectl get appprojects -n argocd -o yaml > pre-reset/argocd-projects.yaml
```

레포를 로컬에 클론해 두고, Argo CD 자체 설치 방식(Helm chart / 매니페스트 / 버전)도 기록한다.

### 0-2. 현재 상태 기록

```bash
mkdir -p pre-reset
kubectl get all -A -o yaml            > pre-reset/all.yaml
kubectl get pv,pvc -A -o yaml         > pre-reset/storage.yaml
kubectl get nodes -o yaml             > pre-reset/nodes.yaml
kubectl -n kube-system get cm kubeadm-config -o yaml > pre-reset/kubeadm-config.yaml
kubectl -n local-path-storage get cm local-path-config -o yaml > pre-reset/local-path-config.yaml
```

`local-path-config`의 `setup` 스크립트에는 0777 권한 커스터마이즈가 들어 있다.
재설치 시 그대로 복원해야 한다 (non-root 컨테이너 기동 실패 방지).

**이 디렉토리는 Git에 넣지 않는다** — Secret 참조와 내부 주소가 들어간다.

### 0-3. 남길 데이터가 있는지 마지막 확인

```bash
kubectl exec -n platform postgresql-0 -- pg_dumpall -U postgres > pre-reset/platform-postgres-final.sql
```

MLflow 실험 기록이 여기에만 있다. 필요 없으면 건너뛴다.

### 0-4. 롤백 수단

**Proxmox VM 스냅샷 3대.** 재구축 실패 시 되돌리기 지점으로는 이것뿐이다.
`etcdctl snapshot`으로는 `kubeadm reset` 이후를 되돌릴 수 없다.

**다만 스냅샷은 백업이 아니다.** 같은 물리 디스크에 있으므로 디스크가 손상되면 같이 사라진다.

**먼저: 기존 `after-mlflow` 스냅샷을 정리한다.**

VM 3대 모두 `parent: after-mlflow` 스냅샷을 달고 있다. thin pool 블록을 붙들고 있는데,
MLflow는 이번에 삭제할 대상이므로 이 스냅샷은 더 이상 의미가 없다. 먼저 지워
공간을 회수하고, 새 스냅샷이 깨끗한 기준점이 되게 한다.

```bash
qm listsnapshot 101; qm listsnapshot 102; qm listsnapshot 103
qm delsnapshot 101 after-mlflow
qm delsnapshot 102 after-mlflow
qm delsnapshot 103 after-mlflow
pvesm status                                   # 회수량 확인

# 그다음 새 기준점
qm snapshot 101 pre-reset
qm snapshot 102 pre-reset
qm snapshot 103 pre-reset
qm listsnapshot 101                            # 생성 성공 확인
```

### thin pool 소진 주의 — 순서가 중요하다

LVM thin 스냅샷은 **블록이 달라질수록 공간을 먹는다.** D0는 대량 쓰기를 유발한다
(`kubeadm reset`, 이미지 prune, 디스크 확장). 스냅샷을 유지한 채로 이 작업을 전부
진행하면 풀이 찰 수 있고, **풀이 가득 차면 VM 3대가 동시에 쓰기 불능이 된다.**

권장 순서:

1. 스냅샷 생성 → `pvesm status`로 여유 기록
2. **Phase 1 reset 수행** (여기까지가 되돌리고 싶은 구간)
3. Phase 1 검증 통과 후 **스냅샷 삭제**
4. 그다음 Phase 2 디스크 확장

각 단계 사이에 `pvesm status`를 확인한다.

### 스냅샷이 실제로 쓸 수 있는지 확인하려면

롤백 테스트는 그 자체가 파괴적이라 현실적이지 않다. 엄밀하게 검증하려면
스냅샷에서 새 VM으로 클론해 부팅한다(디스크를 더 쓰므로 풀 여유 확인 후).
그렇게까지 하지 않을 경우, 최소한 스냅샷 생성 성공과 풀 여유는 확인한다.

노드 콘솔 접근도 확보한다 — SSH가 끊겨도 Proxmox 콘솔로 들어갈 수 있어야 한다.

---

## Phase 1 — reset

**네임스페이스를 하나씩 지우지 않는다.** `kubeadm reset`이 Argo CD를 포함해 클러스터
전체를 없애므로 `root-app`의 selfHeal이 개입할 여지가 없다. 살아 있는 클러스터에서
삭제를 시도하면 오히려 Argo와 싸우게 된다.

먼저 PV 데이터만 확인한다 — 특히 `datalake`가 무엇을 들고 있는지.

```bash
kubectl get pvc -A
kubectl get pv
```

확인 후 워커 → 컨트롤 플레인 순서로 진행한다.

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet /etc/kubernetes
sudo rm -rf /opt/local-path-provisioner        # 기존 PV 데이터. Retain 정책이라 수동 삭제 필요
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo iptables-save | grep -iE 'flannel|cali|cni' || echo "잔여 규칙 없음"
sudo systemctl restart containerd
sudo ctr -n k8s.io images prune --all          # 미사용 이미지 정리
```

정리 후 회수된 용량을 측정한다. **이 숫자로 Phase 2의 확장 크기를 정한다.**

```bash
df -h /
sudo du -sh /var/lib/containerd
```

## Phase 2 — 디스크 확장 (A안)

reset 직후 시스템이 조용할 때 수행한다. 온라인 확장이므로 VM 정지는 필요 없다.

목표 크기 — PVC 소요 + 기반 이미지 + 여유:

| 노드 | 현재 | 목표 | PVC 소요 |
| --- | --- | --- | --- |
| `k8s-worker1` | 80 GB | **120 GB** | 60 GiB (CNPG 20 · Qdrant 15 · corpus 10 · 백업 15) |
| `k8s-worker2` | 70 GB | **100 GB** | 37 GiB (Prometheus 25 · Tempo 10 · Grafana 2) |
| `k8s-cp` | 미측정 | 여유 20 GiB 이상 확보 | 없음 |

### 2-a. vCPU / RAM 조정 (worker2만)

hotplug를 켜두지 않았으므로 VM 재시작이 필요하다. 이 구간은 어차피 클러스터를
부순 상태라 재부팅이 공짜다.

```bash
qm shutdown 103 && sleep 20
qm set 103 --cores 4 --memory 8192
qm start 103
```

`k8s-cp`(2 vCPU / 4 GiB)와 `k8s-worker1`(4 vCPU / 10 GiB)은 그대로 둔다.
조정 후 VM 합계는 10/16 vCPU, 22/28 GiB — 호스트에 ~4.5 GiB가 남는다.

**`free -h`로 스왑 사용량이 0인지 확인한다.** 스왑이 시작되면 이후 모든 지연 측정이
무의미해지므로, 여기서 걸러야 한다.

### 2-b. 디스크 확장

**가상 디스크만 키우면 게스트는 아무것도 달라지지 않는다.**
파티션 → PV → LV → 파일시스템까지 네 단계를 모두 확장해야 실제 용량이 늘어난다.
각 단계마다 결과를 확인한다.

```bash
# 1) Proxmox host
pvesm status                     # 풀 여유 확인
qm resize <vmid> scsi0 +40G      # worker1
qm resize <vmid> scsi0 +30G      # worker2

# 2) 게스트 안에서 — 네 단계 전부
lsblk                            # 커널이 새 크기를 봤는지
sudo growpart /dev/sda 3         # 파티션
sudo pvresize /dev/sda3          # LVM PV
sudo pvs                         #   → PFree 증가 확인
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv   # 파일시스템 (xfs면 xfs_growfs)
df -h /                          #   → 최종 확인
```

`lsblk`에 새 크기가 안 보이면 SCSI 재스캔이 필요하다:
`echo 1 | sudo tee /sys/class/block/sda/device/rescan`

thin pool은 과다 할당이 가능하다. 확장 후에도 `pvesm status` 사용률을 주기적으로 본다 —
**풀이 가득 차면 VM 3대가 동시에 쓰기 불능이 된다.**

## Phase 3 — kubeadm init

### 반드시 지금 해야 하는 것: API server 인증서 SAN

나중에 AWS GPU 워커가 Tailscale 너머에서 API server에 접속한다. 그때 인증서에
Tailscale IP가 없으면 TLS 검증에 실패하고, **인증서 재발급은 클러스터를 다시 흔드는 작업이다.**
init 시점에 넣는 것이 압도적으로 싸다.

```bash
# CP의 Tailscale IP를 먼저 확인
tailscale ip -4

sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --apiserver-advertise-address=192.168.50.101 \
  --apiserver-cert-extra-sans=<CP의 Tailscale IP>,<필요시 DNS 이름>
```

Pod/Service CIDR은 기존 값을 유지한다 — LAN(192.168.50.0/24), VPC, Tailnet 대역과
겹치지 않는지 확인한다. 이것이 `persona-platform` Loop 1의 완료 조건이다.

컨트롤 플레인 taint는 **유지한다**. 2 vCPU / 3.8 GiB로 여유가 없고, 워크로드가 올라가면
etcd fsync 지연이 나빠져 관측하려는 신호 자체가 오염된다.

## Phase 4 — Cilium

flannel을 한 번도 설치하지 않으므로 잔여물 문제가 없다. **이것이 재구축의 가장 큰 이득이다.**

MTU를 명시적으로 고정한다. 자동 감지에 맡기면 상위 인터페이스를 보고 잘못 잡을 수 있고,
그것이 K8S-01이 재현하려는 상황 자체다.

```bash
ip link show tailscale0     # 실측 MTU 확인 → Cilium 설정에 명시
```

- 터널 모드 (VXLAN 또는 Geneve)
- **`kubeProxyReplacement` 비활성** — 변수를 하나씩만 바꾼다
- **Cilium의 Gateway API 기능 비활성.** kube-proxy replacement를 요구하므로 켤 수 없고,
  Gateway API 컨트롤러는 **Traefik 하나만** 둔다. Cilium ingressController와 L7 프록시도 끈다
- Hubble 활성화 — 드롭 이유 라벨과 흐름 관측이 K8S-01의 핵심 도구다

### MTU — 명시하되, 명시값이 정답은 아니다

`tailscale0`의 MTU는 **참고치일 뿐이다.** Cilium에 수동 지정한 MTU는 Cilium 자신의
가상 인터페이스에 적용되며, 실제 경로의 통과 가능 크기는 Tailscale의 캡슐화와
direct/DERP 상태에 따라 달라진다. 값을 넣은 뒤에는 **반드시 측정으로 확인한다**
(Phase 6 및 D1 완료 조건).

워커 조인 후 전체 파드 기동을 확인한다.

## Phase 5 — 기반 재설치

순서대로:

1. **local-path** — `pre-reset/local-path-config.yaml`의 0777 setup 스크립트를 그대로 복원
2. **Argo CD** — Phase 0에서 확보한 방식으로 재설치, Git 레포 재연결
3. **metrics-server** — 현재 없어서 `kubectl top`이 동작하지 않는다
4. **Gateway API CRD → Traefik** — NodePort / LoadBalancer 노출 없이.
   CRD는 **하나의 Argo Application이 단독으로 소유**한다. Cilium과 Traefik이 각자
   CRD를 관리하려 들면 Argo sync가 충돌한다. GatewayClass는 Traefik 것만 만든다
5. Tailscale Serve → Traefik 경로 연결

Grafana는 **무상태로 설치한다** — 데이터소스와 대시보드를 provisioning으로 주입하고
DB는 `emptyDir`에 둔다. CNPG에 연결하지 않으므로 worker1 장애가 대시보드를 같이
죽이지 않는다.

### 여기가 진짜 위험 지점이다

reset은 안전하다. 위험한 것은 **Argo CD를 다시 세우는 순간**이다.
새 Argo를 `Market-Layer-Platform`의 `develop`에 그대로 연결하면 `root-app`이
prune + selfHeal로 동작하면서 **airflow · mlflow · postgresql · datalake ·
ingress-nginx를 전부 되살린다.** 재구축의 의미가 사라진다.

**권장: 새 Argo CD는 `persona-platform` 레포를 바라보게 한다.**

이 프로젝트의 문서화된 아키텍처와도 일치한다 — `persona-platform`이 인프라와 배포
선언을 단독 소유하기로 되어 있다. 기존 레포는 사용하지 않게 되고,
Market-Layer-Platform은 나중에 필요하면 별도 환경에 다시 배포하면 된다.

대안(같은 레포를 계속 쓰는 경우)은 `develop`에서 삭제 대상 Application 매니페스트를
먼저 제거하고 푸시하는 것이다. 두 프로젝트의 인프라가 한 레포에 섞이므로 권장하지 않는다.

복원할 것은 하나다 — **local-path의 0777 setup 스크립트.**
`infra/k8s/bootstrap/storageclass`의 내용을 `persona-platform`으로 옮겨 온다.

## Phase 6 — 검증 게이트

**2026-09-07 전부 통과.** Phase 4까지 완료.

| 항목 | 결과 |
| --- | --- |
| 노드 3대 `Ready`, 재시작 루프 없음 | 통과 — cp / worker1 / worker2 |
| CP `NoSchedule` taint 유지, 워크로드 미배치 | 통과 |
| Pod-IP 직접 통신 (타 노드) | 통과 — 0.4ms, 손실 0 |
| ClusterIP → 엔드포인트 | 통과 — API server TLS alert 응답 확인 |
| CoreDNS | 통과 — `kubernetes.default` → 10.96.0.1 |
| **NetworkPolicy 적용·거부** | **통과** — flannel에서 불가능했던 항목 |
| MTU 경계 | 통과 — route 1230, `-s 1202` 통과 / `1203` 거부 |
| **Cilium drop 카운터 `reason` 라벨** | **통과** — K8S-01 진단 도구 확보 |
| kube-proxy 유지 | 통과 — `KubeProxyReplacement: False` |
| Cilium Gateway API 비활성, CRD 없음 | 통과 |
| API server 인증서 Tailscale IP SAN | 통과 — IP와 MagicDNS FQDN 모두 포함 |
| 디스크 확장 | 통과 — worker2 97G (여유 86G) |
| worker2 4 vCPU / 8 GiB | 통과 |
| Proxmox 호스트 스왑 0 | 통과 |
| `Released` PV 없음 | 통과 — 신규 클러스터 |

### 노드별 podCIDR

| 노드 | podCIDR | Tailscale |
| --- | --- | --- |
| `k8s-cp` | 10.244.0.0/24 | 있음 |
| `k8s-worker1` | 10.244.1.0/24 | 있음 |
| `k8s-worker2` | **10.244.3.0/24** | 있음 |

worker2가 `.2`가 아니라 `.3`을 받았다. 컨트롤러 할당 과정에서 건너뛴 것으로 무해하지만,
나중에 경로를 디버깅할 때 혼동하지 않도록 기록해 둔다.

### 진행 중 발견한 것 (별도 문서에 상세)

- **MTU는 인터페이스가 아니라 라우트가 실효값이다** — `bootstrap/cilium/README.md`
- **ConfigMap만 바뀌는 설정은 `helm upgrade`로 파드가 재시작되지 않는다.**
  Argo 도입 시 `Synced`·`Healthy`인 채로 옛 설정이 도는 드리프트가 발생한다 — 같은 문서
- **`discard=on`이 없으면 thin pool이 회수되지 않는다** — `docs/cluster-inventory.md`

      바뀐다. 한쪽만 측정하면 K8S-01의 결론이 재현되지 않는다
- [ ] Cilium 드롭 카운터가 `reason` 라벨과 함께 수집됨
- [ ] Cilium Gateway API / ingressController가 비활성, GatewayClass는 Traefik 하나뿐
- [ ] `Released` 상태 PV가 남아 있지 않음
- [ ] `openssl s_client`로 API server 인증서에 **Tailscale IP SAN이 포함**되었는지 확인
- [ ] `df -h`로 확장된 용량 확인 (worker1 ~120 GB, worker2 ~100 GB)
- [ ] worker2가 4 vCPU / 8 GiB로 인식됨
- [ ] Proxmox 호스트 `free -h`에서 **스왑 사용량 0**
- [ ] PriorityClass 적용, 자원 압박 시 축출 순서가 의도대로 동작
- [ ] Argo CD 정상 동기화, 삭제 대상이 되살아나지 않음

## Phase 5 결과 — 완료 (2026-09-07)

| 컴포넌트 | 버전 | 배치 | 확인 |
| --- | --- | --- | --- |
| local-path-provisioner | v0.0.37 | — | 0777 setup 적용, `nodePathMap`에 worker1/2만. UID 50000 쓰기 성공 |
| PriorityClass | — | — | `persona-critical` / `persona-standard` / `persona-low` |
| metrics-server | chart 3.14.0 | 자유 | `kubectl top` 동작 |
| Argo CD | chart 10.8.1 (v3.5.2) | worker1 | 설치 완료, **manual sync** (selfHeal/prune 미적용) |
| Gateway API CRD | v1.6.2 standard | — | 10개 CRD, **단일 소유** |
| Traefik | chart 41.4.0 (v3.7.12) | **worker2** | GatewayClass `traefik` **ACCEPTED True** |

### public inbound 0 확인

```
service/traefik   ClusterIP   10.104.208.56   <none>   80/TCP,443/TCP
kubectl get svc -A | grep NodePort   → 출력 없음
```

클러스터 전체에 NodePort가 하나도 없다. 이전 클러스터의 ingress-nginx
30080/30443 노출이 사라진 상태를 유지한다.

### 남은 것

- Tailnet 노출 (`tailscale serve` → Traefik ClusterIP). Gateway와 HTTPRoute를
  선언한 뒤에 의미가 있으므로 실제 앱이 생길 때 함께 붙인다
- Argo CD `argocd/applications/` 경로 구성 및 기존 수동 설치분의 Argo 편입

## 관련 문서

- `storage-and-recovery.md` — local-path 운영 규칙, PVC 삭제 절차, 저장소별 복구 전략
- `cluster-inventory.md` — 노드·디스크 실측과 결정 기록

## 노드 역할 (D1에서 사용)

local-path가 파드를 노드에 고정하므로, 배치가 곧 장애 범위다.

| 노드 | 담당 |
| --- | --- |
| `k8s-worker1` (4 vCPU / 9.7 GiB) | 데이터 — CNPG, Qdrant, private corpus |
| `k8s-worker2` (2 vCPU / 5.8 GiB) | 관측 — Prometheus, Tempo, Grafana |
| `k8s-cp` | 스케줄 금지 |

## 미결

없음. D1로 넘어갈 수 있다.

Phase 1 이후 회수된 용량과 Phase 4의 Tailscale MTU 실측값은 D1의 PVC·Cilium 설정에
그대로 들어가므로 기록해 둔다.
