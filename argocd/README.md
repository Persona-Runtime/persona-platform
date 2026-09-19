# argocd/ — Application 목록

Sync 통제 원칙(`runbooks/public-ingress.md` Gate 3-7 상단, 2026-09-18): "Argo Sync는
'기능 하나 배포'가 아니라 '그 Application이 보는 Git 경로 전체를 반영'이다." 이 표는 각
Application이 정확히 무엇을 반영하는지 이름만으로 헷갈리지 않게 하려는 것이다 — **한
Application = 한 종류의 변경**을 목표로 2026-09-19에 `persona-app`·`persona-db`를 나눴다.

모든 Application은 `targetRevision: develop`, `syncPolicy` 키 없음(자동 Sync·prune 없음,
`scripts/validate-*.sh`가 assert)이 원칙이다. Sync 전에는 `scripts/argo-preflight.sh <app>`로
승인 SHA·전체 diff·선행 조건을 확인한다.

## Application

| Application | 경로 | 네임스페이스 | 관리 리소스 종류 | 선행 조건 |
| --- | --- | --- | --- | --- |
| `metallb` | (Helm `metallb/metallb`) | `metallb-system` | MetalLB 컨트롤러·CRD | `bootstrap/namespaces/metallb-system.yaml` 먼저 적용(PSA `privileged`) |
| `metallb-config` | `kustomize/overlays/prod/metallb-config` | `metallb-system` | IPAddressPool·L2Advertisement | `metallb` Sync 먼저(CRD) |
| `cert-manager` | (Helm `jetstack/cert-manager`) | `cert-manager` | cert-manager 컨트롤러·CRD | `bootstrap/namespaces/cert-manager.yaml` 먼저 적용 |
| `cert-manager-issuers` | `kustomize/overlays/prod/cert-manager-issuers` | `cert-manager` | ClusterIssuer(staging·prod) | `cert-manager` Sync 먼저(CRD) |
| `persona-db` | `kustomize/overlays/prod/persona-db` | `persona-data` | CNPG Cluster(DB)만 | CNPG operator 설치됨(`bootstrap/cnpg/`) |
| `persona-db-netpol` | `kustomize/overlays/prod/persona-db-netpol` | `persona-data` | NetworkPolicy·CiliumNetworkPolicy만 | 다른 네임스페이스 정책을 먼저 확인·적용한 뒤 **맨 마지막**(운영 중인 DB에 영향, Gate 4-2·4-6) |
| `persona-app` | `kustomize/overlays/prod/persona-app` | `persona-app` | Gateway·Web 워크로드, Gateway 객체(http+https listener), 내부(Tailnet/Serve) HTTPRoute, `strip-auth-header` Middleware | **Traefik이 `kubernetesCRD` 프로바이더를 켠 뒤에만**(`bootstrap/traefik/values.yaml`) — 내부 HTTPRoute도 Middleware를 ExtensionRef로 참조해 그 프로바이더가 없으면 거부된다 |
| `persona-app-ingress` | `kustomize/overlays/prod/persona-app-ingress` | `persona-app` | 인터넷 진입 HTTPRoute(`persona-app-public`) + Middleware 4개(`oauth-forward`·`rate-limit`·`security-headers`·`body-limit`) | `persona-app` Sync 먼저(Gateway https listener 필요), Secret `persona-app-tls` Ready, Service `oauth2-proxy.persona-edge` 존재, ReferenceGrant 존재 |
| `persona-app-netpol` | `kustomize/overlays/prod/persona-app-netpol` | `persona-app` | NetworkPolicy만 | Cilium 상태 ok, 대상 Pod Ready |
| `persona-edge` | `kustomize/overlays/prod/persona-edge` | `persona-edge` | DDNS CronJob + oauth2-proxy + 그 NetworkPolicy(**아직 분리 안 함** — 이번 라운드는 persona-app·persona-db만) | Secret `oauth2-proxy`·`cloudflare-dns-token` 존재 |
| `csi-driver-nfs` | (Helm) | `kube-system` | NFS CSI 드라이버 | 없음 |
| `persona-nfs-storage` | `kustomize/overlays/prod/nfs-storage` | `default` | StorageClass | `csi-driver-nfs` 준비됨 |
| `monitoring-stack` | (Helm `kube-prometheus-stack`) | `monitoring` | Prometheus·Grafana | 없음(유일하게 `syncOptions: [ServerSideApply=true]` — CRD가 커서, `automated`는 아님) |

## Argo 밖(수동 `kubectl apply -k`/de-registered)

Argo Application이 없는 이유까지 같이 적는다 — "왜 여기 없는가"도 지도의 일부다.

| 경로 | 적용 방식 | 이유 |
| --- | --- | --- |
| `kustomize/overlays/prod/traefik-networkpolicy` | `kubectl apply -k`(CP 수동) | Traefik 본체가 `helm --create-namespace`로 Argo 밖에 설치돼 있어(`bootstrap/traefik/`), 그 NetworkPolicy도 같은 방식으로 다룬다 |
| `kustomize/overlays/prod/traefik-observability` | `kubectl apply -k`(CP 수동) | 위와 같은 이유(Traefik 부속) |
| `kustomize/overlays/prod/mock-sse` | 없음(2026-09-16 de-registered) | 완료된 실험 자원 정리 — 재등록 절차는 `runbooks/test-resource-cleanup.md`(로컬) |
| `kustomize/overlays/prod/persona-migrate` | 없음(2026-09-16 de-registered) | migration Job은 일회성이라 상시 Application 목록에 안 둔다 — Job 계약 검증은 `scripts/validate-persona-app-manifests.sh`가 계속 한다 |

## 신규 Application 추가 시

1. `kustomize/overlays/prod/<name>/`에 그 종류의 리소스만 넣는다(다른 종류를 섞지 않는다).
2. `argocd/<name>.yaml`을 기존 단일 source Application 모양(`persona-app.yaml` 등)으로
   만든다 — `syncPolicy` 키를 넣지 않는다.
3. 이 표에 행을 추가한다.
4. `scripts/argo-preflight.sh`의 선행 조건 표에 그 Application의 조건을 추가한다.
5. 관련 `scripts/validate-*.sh`가 새 경로를 렌더·검사하도록 확장한다.
