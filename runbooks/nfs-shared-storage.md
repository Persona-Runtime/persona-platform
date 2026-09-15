# NFS 공유 저장소 — CSI 연결과 노드 간 파일 유지 검증

2026-09-15 기준: NFS VM과 수동 마운트는 사용자 출력으로 확인했다.
CSI·StorageClass·PVC·Pod는 선언 준비 단계이며 실제 적용 결과가 아니다.
[실행 위치 정책](execution-locations.md)에 따라 클러스터 명령은 홈 CP에서만 실행한다.

## 1. 현재 상태와 연결 원리

VM 104 `nfs-storage`는 같은 Proxmox 안의 독립 Ubuntu 24.04.4 VM이다.
1 vCPU·RAM 2 GiB, OS 디스크 16 GiB, 데이터 디스크 80 GiB를 사용한다.
ext4 `LABEL=nfs-data`가 `/srv/nfs`에 마운트되고,
DHCP 예약은 MAC `BC:24:11:D2:BB:FF` → `192.168.50.205`다.

`/srv/nfs/k8s`는 UID/GID `10001:10001`, mode `2770`이다.
export는 worker1 `192.168.50.102`, worker2 `192.168.50.99`만 허용하고,
`rw,sync,no_subtree_check,root_squash,anonuid=10001,anongid=10001,mountpoint=/srv/nfs`를 사용한다.
두 워커의 NFSv4.1 수동 마운트 및 동일 파일 조회까지 확인했다.
수동 테스트 파일 삭제·마운트 해제 완료 여부는 아직 확인하지 않았다.

PVC가 저장소를 요청하면 CSI controller가 공유 안에 PV 이름의 디렉터리를 만든다.
Pod가 실행되는 워커의 CSI node 플러그인이 그 디렉터리를 마운트한다.
StorageClass는 이 연결 규칙이며 NFS 서버나 새 물리 디스크를 만드는 기능이 아니다.

- chart는 `4.13.4`로 고정한다. CSI 컨테이너는 upstream 버전 태그를 사용하며,
  테스트 BusyBox만 별도로 확인한 linux/amd64 manifest digest로 고정했다.
- controller 1개와 node DaemonSet은 두 홈 워커만 허용한다. CP·미래 GPU 노드는 제외한다.
  chart 기본 자원 requests/limits는 초기값이며 부하 실측치는 아니다.
- chart의 `hostNetwork: true`로 서버에 워커 주소로 접근한다. privileged와 hostPath는
  CSI의 노드 마운트에 필요하며 테스트 Pod에는 부여하지 않는다.
- 추가 PriorityClass와 snapshotter·snapshot CRD 설치를 끈다.
- 테스트 Pod는 UID/GID 10001로 실행하며 `fsGroup` 재귀 chown은 사용하지 않는다.
  root_squash는 모든 UID를 격리하지 않는다. 신뢰하는 홈 워커용이지 테넌트 보안 경계가 아니다.
- `nfs-shared`는 비기본 SC, `Retain`, `nfsvers=4.1,hard`다. 기존 기본 SC와
  DB·Prometheus·Qdrant 및 웹 업로드의 Postgres 보관 계약은 변경하지 않는다.
- PVC `1Gi`는 NFS 디렉터리의 실제 quota가 아니다. VM·Proxmox 디스크 여유를 함께 본다.
  같은 물리 호스트이므로 노드 간 공유는 가능해도 물리 장애 HA나 백업은 아니다.

## 2. 로컬 검사와 게시 경계

```sh
sh scripts/validate-nfs-manifests.sh /임시경로/csi-driver-nfs
```

인자는 공식 chart 4.13.4를 내려받아 압축 해제한 디렉터리다. 검사 자체는 네트워크나
클러스터에 접근하지 않는다. Helm lint/template, Kustomize 렌더, 정책 음성 검사를 실행한다.
chart는 임시 디렉터리를 만든 뒤 아래 명령으로 준비할 수 있다. 이 다운로드는 설치가 아니다.

```sh
helm pull csi-driver-nfs --repo https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts --version 4.13.4 --untar --untardir /준비한임시디렉터리
```

Argo는 `develop`을 참조하므로 **관련 파일이 develop에 게시되기 전 Sync하지 않는다.**
커밋·push·PR·머지는 별도 승인 범위다.

이번 로컬 실행 기록:

- Helm lint·template, SC Kustomize 렌더·정책 검사 통과. 정책 음성 검사 8건 통과.
- 새 YAML·런북 Prettier format check, 셸·Ruby 구문 검사, 공백 검사 통과.
- 기존 mock SSE·persona-app 선언 검사 통과. persona-app 검사는 UTF-8 locale을 지정해 실행했다.
- Helm 없는 PATH에서 즉시 실패하는 도구 가드 확인.
- Docker daemon에 연결할 수 없어 실제 테스트 이미지의 writer/reader 실행은 검증하지 못했다.
  홈 클러스터 server dry-run·Argo Sync·PVC Bound·Pod 파일 검증·NFS 장애 복구도 미검증이다.

## 3. CP 사전 조회 — 먼저 이 결과 확인

2026-09-15 사용자 CP 출력: `kubernetes-admin@kubernetes`, 세 노드 Ready,
worker1 `.102`·worker2 `.99`로 export 목록과 일치했다. 등록된 CSIDriver는 없고
기본 SC는 `local-path` 하나였다. Argo에는 monitoring-stack·persona-mock-sse만 있었다.
monitoring-stack은 OutOfSync/Healthy였으며 이번 작업에서는 Sync하거나 수정하지 않는다.
기존 설치의 잔존 Deployment/DaemonSet과 PVC 목록은 아래 조회로 추가 확인한다.
이 기록은 당시 사용자 출력이며 적용 시점의 재확인을 대신하지 않는다.

```sh
hostname
kubectl config current-context
git status --short --branch
git log -1 --oneline
kubectl get nodes -o wide
kubectl get storageclass
kubectl get csidriver
kubectl get pvc -A
kubectl get applications -n argocd
kubectl get deployment,daemonset -A
```

기존 NFS 설치·동명 SC/Application이 있으면 중복 설치하지 말고 Helm/Argo 소유권부터 확인한다.
노드 IP가 export 목록과 일치하고 두 워커에 `nfs-common`이 있어야 한다.
CP 자체는 NFS 클라이언트나 CSI node 설치 대상이 아니다.
이후 명령은 확인된 CP context를 유지한 상태에서만 실행한다.

## 4. CSI → StorageClass 순서로 수동 Sync

게시된 파일을 CP checkout에 반영한 뒤 실행한다. unrelated 로컬 수정을 덮어쓰지 않는다.

```sh
kubectl apply --dry-run=server -f argocd/csi-driver-nfs.yaml
kubectl apply -f argocd/csi-driver-nfs.yaml
```

Argo UI에서 `csi-driver-nfs`의 렌더를 확인하고 수동 Sync한다. 자동 Sync·prune은 켜지 않는다.
CSI가 준비된 것을 확인한 후에만 다음 Application을 적용한다.

```sh
kubectl -n kube-system rollout status deployment/csi-nfs-controller --timeout=180s
kubectl -n kube-system rollout status daemonset/csi-nfs-node --timeout=180s
kubectl -n kube-system get pods -o wide
kubectl get csidriver nfs.csi.k8s.io
kubectl apply --dry-run=server -f argocd/persona-nfs-storage.yaml
kubectl apply -f argocd/persona-nfs-storage.yaml
```

`persona-nfs-storage`를 별도로 수동 Sync하고 `kubectl get sc nfs-shared -o yaml`로
server/share·비기본·Retain을 확인한다. 두 Application 순서는 sync-wave가 보장하지 않는다.

## 5. 테스트 PVC와 writer — CP에서 명시적으로 적용

테스트 PVC/Pod는 Argo 관리 대상에서 제외했다. writer 삭제가 GitOps 재생성과 싸우지 않게 한다.
동명 namespace/PVC/Pod가 이미 있으면 반복 적용하지 말고 이전 실행 결과부터 확인한다.

```sh
kubectl apply -f tests/nfs/namespace.yaml
kubectl apply --dry-run=server -f tests/nfs/pvc.yaml
kubectl apply -f tests/nfs/pvc.yaml
kubectl -n persona-nfs-test wait --for=jsonpath='{.status.phase}'=Bound pvc/nfs-smoke-data --timeout=180s
kubectl -n persona-nfs-test get pvc nfs-smoke-data -o wide
kubectl get pv
kubectl apply --dry-run=server -f tests/nfs/writer.yaml
kubectl apply -f tests/nfs/writer.yaml
kubectl -n persona-nfs-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-writer --timeout=180s
kubectl -n persona-nfs-test get pod nfs-writer -o wide
kubectl -n persona-nfs-test logs nfs-writer
```

**어느 명령이든 실패하면 다음으로 진행하지 않는다.** `describe pvc/pod`, Events와
컨테이너 종료 코드를 확인한다. writer는 합성 파일과 SHA-256 파일을 쓰고 종료한다.
이전 파일이 있으면 덮어쓰지 않고 실패해 과거 파일로 새 검사를 통과시키지 않는다.

## 6. writer 제거 후 worker2에서 같은 PVC 읽기

writer 성공과 로그를 기록한 후에만 실행한다. 삭제 대상은 합성 테스트 writer Pod 하나다.

```sh
kubectl -n persona-nfs-test delete pod nfs-writer --wait=true --timeout=120s
kubectl apply --dry-run=server -f tests/nfs/reader.yaml
kubectl apply -f tests/nfs/reader.yaml
kubectl -n persona-nfs-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-reader --timeout=180s
kubectl -n persona-nfs-test get pod nfs-reader -o wide
kubectl -n persona-nfs-test logs nfs-reader
```

reader는 worker2에서 read-only로 마운트해 알려진 합성 내용과 해시를 검사한다.
완료 조건은 **writer Succeeded → writer 삭제 → reader Succeeded 및 해시 일치**다.
PVC/PV UID, Pod UID·노드·로그를 기록한다. 이는 순차 재마운트 검증이며,
동시 RWX 접근·노드 장애 failover·성능 검증은 아니다.

## 7. 정리와 실패 진단

reader 로그 기록 후 `kubectl -n persona-nfs-test delete pod nfs-reader`로 Pod만 정리한다.
PVC/PV와 NFS 디렉터리는 보존한다. `Retain`은 백업이 아니며 PVC를 삭제해도
PV·서버 데이터 정리는 별도다. 재실험은 보존 대상과 이름을 먼저 결정한다.
namespace·PVC 일괄 삭제나 volume prune을 정리 명령으로 쓰지 않는다.

- PVC Pending: controller Events/로그, 서버 IP·경로·허용 IP를 확인한다.
- ContainerCreating: 해당 워커 CSI node 로그와 마운트 실패 Events를 확인한다.
- Permission denied: 부모 디렉터리 `10001:10001`, `2770`, export의 anonuid/anongid와
  Pod UID/GID를 비교한다. `0777`·`no_root_squash`로 우회하지 않는다.
- hard 마운트는 서버 장애 시 I/O가 기다릴 수 있다. Pod deadline만으로 커널 I/O가
  항상 즉시 종료된다고 보장하지 않는다. 서버 연결 복구를 먼저 확인한다.

공식 근거: [chart values](https://github.com/kubernetes-csi/csi-driver-nfs/blob/v4.13.4/charts/latest/csi-driver-nfs/values.yaml),
[드라이버 매개변수](https://github.com/kubernetes-csi/csi-driver-nfs/blob/v4.13.4/docs/driver-parameters.md).
