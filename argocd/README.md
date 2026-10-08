# argocd/ — Application 목록

Sync 통제 원칙(`runbooks/public-ingress.md` Gate 3-7 상단, 2026-09-18): "Argo Sync는
'기능 하나 배포'가 아니라 '그 Application이 보는 Git 경로 전체를 반영'이다." 이 표는 각
Application이 정확히 무엇을 반영하는지 이름만으로 헷갈리지 않게 하려는 것이다 — **한
Application = 한 종류의 변경**을 목표로 2026-09-19에 `persona-app`·`persona-db`를 나눴다.

Git source를 쓰는 모든 Application은 `targetRevision: develop`, `syncPolicy.automated` 없음
(자동 Sync·prune 없음, `scripts/validate-*.sh`가 assert)이 원칙이다. Helm chart source는 검토한
chart version을 고정한다. Sync 전에는 `scripts/argo-preflight.sh <app>`로 승인 SHA·전체 diff·
선행 조건을 확인한다.

## Application

| Application | 경로 | 네임스페이스 | 관리 리소스 종류 | 선행 조건 |
| --- | --- | --- | --- | --- |
| `metallb` | (Helm `metallb/metallb`) | `metallb-system` | MetalLB 컨트롤러·CRD | `bootstrap/namespaces/metallb-system.yaml` 먼저 적용(PSA `privileged`) |
| `metallb-config` | `kustomize/overlays/prod/metallb-config` | `metallb-system` | IPAddressPool·L2Advertisement | `metallb` Sync 먼저(CRD) |
| `cert-manager` | (Helm `jetstack/cert-manager`) | `cert-manager` | cert-manager 컨트롤러·CRD | `bootstrap/namespaces/cert-manager.yaml` 먼저 적용 |
| `cert-manager-issuers` | `kustomize/overlays/prod/cert-manager-issuers` | `cert-manager` | ClusterIssuer(staging·prod) | `cert-manager` Sync 먼저(CRD) |
| `public-gateway` | `kustomize/overlays/prod/public-gateway` | `persona-app` | 공개 진입 Gateway 객체 `persona-app`(http+https listener)만. Certificate·TLS Secret `persona-app-tls`는 cert-manager gateway-shim이 만들며 Git에 선언하지 않음 | 소유권 이관(Phase 1) 완료 상태여야 한다 — live Gateway tracking-id가 `public-gateway`, Certificate 소유자가 현재 Gateway(`scripts/argo-preflight.sh public-gateway`) |
| `maintenance-page` | `kustomize/overlays/prod/maintenance-page` | `persona-app` | 정적 준비 중 페이지(nginx Deployment·Service·ConfigMap), 공개(https)·내부(http) HTTPRoute, `maintenance-security-headers` Middleware, persona-app NetworkPolicy(`maintenance-` 접두사) | Traefik `kubernetesCRD` 프로바이더, Gateway Programmed, Certificate `persona-app-tls` Ready. 다음 서비스 공개(M8) 때 backendRef를 바꾸고 정리한다 |
| `persona-edge` | `kustomize/overlays/prod/persona-edge` | `persona-edge` | DDNS CronJob + oauth2-proxy + 그 NetworkPolicy(**아직 분리 안 함**) | Secret `oauth2-proxy`·`cloudflare-dns-token` 존재 |
| `mafest-db` | `kustomize/overlays/prod/mafest-db` | `mafest-data` | CNPG Cluster `mafest-db`(PG16+AGE, 2 인스턴스, `Prune=false,Delete=false`)·PodMonitor. Cluster 이미지는 승인 릴리스 digest로 고정돼 렌더에 연결돼 있다 | CNPG operator·CRD, StorageClass local-path, ns `mafest-data`, Secret `mafest-db-owner`·`mafest-db-runtime`·`mafest-ghcr`(이름만), 두 홈 워커 Ready |
| `mafest-db-netpol` | `kustomize/overlays/prod/mafest-db-netpol` | `mafest-data` | NetworkPolicy·CiliumNetworkPolicy만(`mafest-` 접두사, allow wave 0 → default-deny wave 1) | Cluster `mafest-db` healthy, Cilium 상태 ok |
| `monitoring-stack` | (Helm `kube-prometheus-stack`) | `monitoring` | Prometheus·Grafana | 없음(유일하게 `syncOptions: [ServerSideApply=true]` — CRD가 커서, `automated`는 아님) |
| `gpu-runtime` | `kustomize/overlays/prod/gpu-runtime` | `kube-system` | `RuntimeClass/nvidia`만 | `persona-gpu-01` Ready, `node-pool=gpu`, GPU 전용 taint 확인 |
| `dcgm-exporter` | (Helm `dcgm-exporter`) | `monitoring` | GPU 전용 DCGM exporter DaemonSet·Service·ServiceMonitor | `gpu-runtime` Sync 뒤 `RuntimeClass/nvidia` 존재, monitoring Prometheus Available, ServiceMonitor CRD 존재 |
| `nvidia-device-plugin` | `kustomize/overlays/prod/nvidia-device-plugin` | `kube-system` | GPU capacity를 광고하는 NVIDIA device plugin DaemonSet만 | `RuntimeClass/nvidia`, GPU Node Ready, DCGM exporter available=1 |
| `mafest-app-netpol`(**초안** `.yaml.draft`) | `kustomize/overlays/prod/mafest-app-netpol` | `mafest-app` | NetworkPolicy만(`mafest-` 접두사, allow wave 0 → default-deny wave 1): API ← Traefik·Prometheus, API → DNS·DB·vLLM, 적재 Job → DNS·DB, 웹 ← Traefik | M6 승인 뒤 활성화. 적재 Job이 돌지 않을 때, 짝 정책(Traefik `allow-egress-backends`·persona-inference `allow-vllm-gateway`) 수동 적용 뒤 |
| `mafest-app`(**초안** `.yaml.draft`) | `kustomize/overlays/prod/mafest-app` | `mafest-app` | API·웹 Deployment·Service·PDB, API PodMonitor. overlay는 평상시 `resources: []`(자리표시 digest) | P7·웹 W 머지, API·웹 digest·`MAFEST_DATA_BASE_DATE` 승인, Secret `mafest-api-db`·`mafest-ghcr`(이름만), `mafest-app-netpol` 먼저. 공개 HTTPRoute 전환(M8 초안 `kustomize/base/mafest-public/route.yaml.draft`)은 넣지 않는다 |

## Argo 밖(수동 `kubectl apply -k`/de-registered)

Argo Application이 없는 이유까지 같이 적는다 — "왜 여기 없는가"도 지도의 일부다.

| 경로 | 적용 방식 | 이유 |
| --- | --- | --- |
| `kustomize/overlays/prod/traefik-networkpolicy` | `kubectl apply -k`(CP 수동) | Traefik 본체가 `helm --create-namespace`로 Argo 밖에 설치돼 있어(`bootstrap/traefik/`), 그 NetworkPolicy도 같은 방식으로 다룬다 |
| `kustomize/overlays/prod/traefik-observability` | `kubectl apply -k`(CP 수동) | 위와 같은 이유(Traefik 부속) |
| `kustomize/overlays/prod/mock-sse` | 없음(2026-09-16 de-registered) | 완료된 실험 자원 정리 — 재등록 절차는 `runbooks/test-resource-cleanup.md`(로컬) |
| `kustomize/overlays/prod/mafest-load` | `kubectl apply -k`(CP 수동, runbook 단계마다 한 Job) | 일회성 적재(stage → graph)라 상시 Sync 대상에 두지 않는다. 평상시 `resources: []` |

## 폐기한 Application (2026-10-07)

`persona-app`·`persona-app-ingress`·`persona-app-netpol`·`persona-db`·`persona-db-netpol`·
`csi-driver-nfs`·`persona-nfs-storage`와 de-registered였던 `persona-migrate` overlay를 Git에서 뺐다
(브랜치 `chore/retire-persona`). 모두 수동 Sync·prune 없음이라 **Git에서 빠져도 클러스터 리소스는
남는다**. 실제 삭제는 사람이 삭제 runbook 순서(공개 Route → 앱 → DB → PVC/PV → 노드 디렉터리 →
NetworkPolicy·NFS → Application)로 실행하고, 그 뒤 이 변경을 머지한다.
남긴 것: `public-gateway`(Gateway·TLS), `persona-edge`, vLLM·모델 캐시·inference NetworkPolicy(Argo 밖),
Traefik, 공용 Application.

## 신규 Application 추가 시

1. `kustomize/overlays/prod/<name>/`에 그 종류의 리소스만 넣는다(다른 종류를 섞지 않는다).
2. `argocd/<name>.yaml`을 기존 Application 모양으로 만든다. Helm chart와 Git values를 함께
   쓸 때는 `monitoring-stack`처럼 multi-source로 두고, `syncPolicy.automated`를 넣지 않는다.
3. 이 표에 행을 추가한다.
4. `scripts/argo-preflight.sh`의 선행 조건 표에 그 Application의 조건을 추가한다.
5. 관련 `scripts/validate-*.sh`가 새 경로를 렌더·검사하도록 확장한다.
