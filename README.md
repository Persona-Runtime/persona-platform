# persona-platform

AWS와 Kubernetes 실행 환경·배포·보안 정책을 소유한다.
최신 설계는 **[현재 기획과 아키텍처](../docs/current-plan.md)** 하나를 기준으로 한다.

## 지금 하는 작업

홈 현황 확인 → 최소 모니터링 → CPU 모의 서빙·부하 도구 → GPU 절차 준비 → 실제 GPU 서빙·기준선 → 병목 개선 순서다.
Go Gateway·dispatcher·업로드 자동화의 개발/배포는 보류한다. 아래 앱 배치 항목은 후속 제품 목표다.
[AWS GPU Terraform 준비](terraform/envs/prod/README.md)를 추가했다. 아직 실제 AWS 생성·GPU 조인·vLLM 배포는 하지 않았다.
서울 GPU 할당량은 증가 요청 대기 중이며 실제 입력/비용/접근 검토 후 생성 여부를 별도로 승인받는다.
할당량이 승인돼도 홈 준비가 끝날 때까지 EC2는 생성하지 않는다.
2026-09-09 초기 [홈 현황 수집](docs/cluster-inventory.md) 이후 사용자 출력에서 모니터링 Application의 Synced/Healthy, Prometheus PVC Bound와 Grafana 대시보드 표시를 확인했다. 다음은 H2 CPU 모의 서빙/SSE 경로다.

## H1 최소 모니터링 선언

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) `89.2.0`을
고정해 Prometheus·Grafana·Prometheus Operator·kube-state-metrics·node-exporter만
선언했다. 값은 [monitoring-stack.yaml](helm/values/monitoring-stack.yaml), Argo CD
Application은 [monitoring-stack.yaml](argocd/monitoring-stack.yaml)에 있다.

Prometheus는 worker2의 `local-path` 20 GiB PVC를 사용하며 7일 또는 15 GB 중 먼저
도달하는 시점까지 보존한다. Grafana DB는 영구화하지 않고 Git의 dashboard/data source
선언으로 복구한다. Alertmanager·Tempo·Loki·Ingress·Gateway·LoadBalancer·NodePort는 H1에
포함하지 않는다. Grafana와 Prometheus 접근 검증은 이후 홈 클러스터에서 localhost
`port-forward`로만 시작한다.

`local-path`의 PVC 요청 크기는 실제 디스크 사용량을 강제하지 않는다. 따라서 15 GB
retentionSize도 worker2 디스크 고갈을 완전히 막지는 않으며, 실제 배포 후에는 노드 디스크
여유와 Prometheus TSDB 크기를 함께 관측한다. 상주 구성의 초기 메모리 request는 node-exporter
3개와 Grafana sidecar·Prometheus config reloader를 포함해 약 2.0 GiB이며, 이는 실측 사용량이 아닌 예약 예산이다.

2026-09-09 사용자 제공 출력에서 Grafana 본체가 limit 256Mi 상태로 OOMKilled(137),
05:56:52 UTC에 종료되고 직후 port-forward가 끊긴 것을 확인했다. Grafana 본체만
memory request 128Mi → 256Mi, limit 256Mi → 512Mi로 조정했다. CPU·sidecar는 유지한다.
사용자 후속 출력에서 request 256Mi / limit 512Mi 적용과 새 Grafana Pod의 약 7분간
재시작 0회를 확인했다. 이는 장시간 안정성 보장이 아니다.

### H1 수집 범위와 보류 대상 — 2026-09-09

- 사용자 Targets 화면에서 Grafana·API server·CoreDNS·세 노드 kubelet/cAdvisor의 UP을 확인했다.
- node-exporter·kube-state-metrics·Prometheus 자체 수집은 선언에 유지한다. 제공된 화면만으로 이들의 모든 target 상태를 검증한 것은 아니다.
- controller-manager·scheduler·etcd 각 1개, kube-proxy 3개는 connection refused였다. CP의 실제 listen 주소는 모두 127.0.0.1이며 kube-proxy 설정은 기본 주소를 사용한다.
- 사용자 승인에 따라 위 4종류의 ServiceMonitor·수집용 Service와 관련 기본 알림/recording rule을 H1에서 제외한다. K8s 컴포넌트 자체는 중지하지 않는다.
- CP의 UFW는 inactive, Cilium 정책 조회는 0개, hostFirewall은 false였다. 이를 이유로 메트릭 포트를 개방하거나 UFW/Host Firewall을 활성화하지 않는다. 다른 계층의 방화벽 유무는 미확인이다.
- etcd 내부 지연·scheduler/controller 내부 성능·kube-proxy 내부 메트릭은 관측 공백이다. 관련 장애 실험 전에 접근 통제와 probe를 포함해 수집 경로를 별도 설계한다.
- 이번 보류 변경은 로컬 선언만 수정했다. 렌더 차이는 해당 수집용 Service 4개, ServiceMonitor 4개, PrometheusRule 5개, 전용 대시보드 ConfigMap 4개 제거뿐이다. commit/push 후 Argo Diff에서도 같은 범위인지 확인하고 수동 Sync한다. 기존 리소스 삭제에는 선택적 Prune이 필요하며, PVC·Secret·CRD·다른 리소스가 삭제 대상이면 중단한다. 자동 Prune은 켜지 않는다. 기본 노드·파드 대시보드는 유지한다.
- Sync 후 의도한 4종류가 Targets에서 제외되는지, 나머지 대상은 UP인지 확인한다. 대상 제거는 해당 컴포넌트의 건강함을 증명하지 않는다. Prometheus Pod 교체 후 데이터 유지 검증은 아직 별도 잔여 항목이다.

선택 이유는 루트 `tradeoff/04-observability.md`에 기록한다.

Argo CD는 외부 차트와 이 저장소의 values를 함께 읽으며 `feat/monitoring-stack`을
추적한다. 자동 sync/prune은 설정하지 않았다. 따라서 Git push만으로 배포되지 않으며,
실제 홈 context·StorageClass·worker2 디스크 여유·Argo 소유권을 확인한 뒤 Application
등록 및 수동 Sync를 별도 요청으로 진행한다. 노트북에는 별도 kubeconfig
`~/.kube/persona-home.yaml`의 `persona-home` context를 등록했다. 기본 context를
가정하지 말고 실제 배포 대상을 매번 명시한다.

최초 홈 배포 전에는 `monitoring` namespace와 `monitoring-grafana-admin` Opaque Secret을
수동으로 준비한다. Secret은 `admin-user`와 `admin-password` 키를 가져야 하며, 값·매니페스트는
Git에 저장하지 않는다. 이 bootstrap이 끝난 뒤에만 Application을 등록하고 수동 Sync한다.
비밀번호를 교체하면 Secret 갱신 후 Grafana Pod를 명시적으로 재시작한다.

로컬 렌더 검증은 다음과 같이 수행한다.

```bash
helm pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 89.2.0 --destination /tmp
tar -xzf /tmp/kube-prometheus-stack-89.2.0.tgz -C /tmp
helm lint /tmp/kube-prometheus-stack -f helm/values/monitoring-stack.yaml
helm template monitoring-stack /tmp/kube-prometheus-stack \
  --namespace monitoring -f helm/values/monitoring-stack.yaml > /tmp/monitoring-rendered.yaml
```

차트 기본 selector는 `release: monitoring-stack`이다. `persona-ops-lab`에서 추가하는
`ServiceMonitor`와 `PrometheusRule`은 이 라벨을 포함해야 수집·평가된다. 대시보드와 규칙의
실제 작성은 ops-lab 책임이다.

## 현재 배치 원칙

- 홈 CP 1 + 공용 홈 워커 2 + AWS GPU 워커 1의 단일 Kubernetes 클러스터.
- 웹·Gateway·ingestion·무상태 관측 앱은 두 홈 워커를 공유한다.
- 서비스 전용 워커 / 관측 전용 워커 구분은 없다.
- Postgres·Qdrant·Prometheus·Tempo는 각자의 local-path 볼륨 위치에 제약을 받는다.
- vLLM은 단일 GPU 노드에 배치하며 필수 GPU·네트워크 에이전트도 해당 노드에서 실행한다.
- 웹 2·Traefik 2·Gateway 1 채택. 웹·Traefik은 홈 워커 간 분산 권장, Traefik은 적용 확인.
- 별도 Go dispatcher 1개와 작업별 ingestion Job 채택, 구현·배포 전. 전체 동시 작업 1개 제어와 세부 RBAC는 후속 설계.
- 나머지 앱 개수와 저장소별 최초 노드는 미정이다.
- Tailscale + Cilium VXLAN + kube-proxy, Traefik Gateway API 방향을 유지한다.
- 접속은 Tailnet 전용이다. Tailscale Serve의 호스트 배치는 파드 스케줄링과 별개다.

GPU Operator 사용 여부·드라이버 관리 주체, 최종 자원 수치는 후속 결정이다.
이 README는 설치나 마이그레이션을 실행하라는 지시가 아니다.

## 운영 자료

- [클러스터 실측·설치 기록](docs/cluster-inventory.md)
- [Cilium 운영](bootstrap/cilium/README.md)
- [local-path 운영](bootstrap/local-path/README.md)
- [Traefik 운영](bootstrap/traefik/README.md)
- [설계 트레이드오프 목록](../tradeoff/README.md)
- [추후 확장 후보](../tradeoff/06-future-extensions.md)

배포 선언은 `bootstrap/`, `helm/`, `kustomize/`, `argocd/` 등에서 관리한다.
dispatcher의 별도 Deployment·ServiceAccount·제한된 Role과 ingestion 실행 환경도 platform이 소유한다.
dispatcher 코드·작업 계약은 `persona-gateway`, 실제 처리 코드는 `persona-ingestion`의 책임이다.
이번 문서 정리로 기존 매니페스트·클러스터·PV를 변경하지 않았다.
