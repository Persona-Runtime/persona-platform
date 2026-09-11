# Gateway·Web·Postgres 배포·검증 런북

현재 구현된 **토큰 인증 → 캐릭터 목록 → 캐릭터 생성**만 대상이다.
업로드·ingestion·Qdrant·채팅·GPU·Go dispatcher는 이 런북의 범위가 아니다.

```
브라우저 → Traefik ├─ /v1 → Python Gateway → Postgres
                   └─ /   → Web
```

실행 위치: **아래 운영 명령은 홈 CP(`k8s-cp`)에서 실행**한다. 노트북에서 실행하지 않는다.
[실행 위치·접속 정책](execution-locations.md)을 따른다. 아래 명령은 CP에 등록된
`kubernetes-admin@kubernetes` context를 명시한다.

## 선언 상태와 금지선

| 구성 | 경로 |
| --- | --- |
| namespace | `bootstrap/namespaces/persona-data.yaml`, `persona-app.yaml` |
| CNPG operator | `bootstrap/cnpg/README.md` (Argo가 관리하지 않는다) |
| DB | `kustomize/overlays/prod/persona-db` · Application `argocd/persona-db.yaml` |
| migration | `kustomize/overlays/prod/persona-migrate` · Application `argocd/persona-migrate.yaml` |
| 앱 | `kustomize/overlays/prod/persona-app` · Application `argocd/persona-app.yaml` |
| grant | `db/grants/persona_minimal.sql` |

- namespace는 bootstrap이 소유한다. Argo overlay에 Namespace를 넣지 않는다.
- Deployment와 Job은 검증된 linux/amd64 child manifest digest를 직접 고정한다.
  tag, `latest`, parent OCI index digest로 바꾸지 않는다.
- Traefik Service의 HTTP 포트 `80`은 클라이언트가 연결하는 Service 포트이고,
  Gateway listener `8000`은 Traefik의 내부 HTTP entryPoint 포트다.
- Secret 값은 Git에 없다. 아래 계약대로 CP에서 만든다.
- **세 Application 사이의 순서는 sync-wave가 보장하지 않는다.** 서로 다른 Application이라
  Argo는 순서를 알지 못한다. 아래 단계를 사람이 차례로 확인하며 Sync한다.

## 고정 이미지 계약

| 항목 | 값 |
| --- | --- |
| Gateway 소스 커밋 | `34d65f5` |
| Gateway 배포용 amd64 child manifest | `sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6` |
| Web 소스 커밋 | `95d7a55` |
| Web 배포용 amd64 child manifest | `sha256:26e6f0ed439ee02374be3b726bb34ee1a8fccbbeace60219084d9acbd3caf968` |
| PostgreSQL | `ghcr.io/cloudnative-pg/postgresql:16.15-standard-bookworm` (index `sha256:fe883b2153a4…`) |
| CNPG operator | v1.30.0 |

두 패키지는 **private GHCR**이다. 게시 기록과 검증 결과는
`../../docs/ghcr-publication-2026-09-11.md`에 있다.

## Secret 계약 — 값은 여기 적지 않는다

| Secret | namespace | 키 | 쓰는 곳 |
| --- | --- | --- | --- |
| `persona-db-migrator` | `persona-data` | `username`, `password` | CNPG initdb owner |
| `persona-gateway-migrator` | `persona-app` | `DATABASE_URL` | migration Job만 |
| `persona-gateway-runtime` | `persona-app` | `DATABASE_URL`, `PERSONA_STATIC_BEARER_TOKEN`, `PERSONA_STATIC_USER_ID`, `PERSONA_STATIC_DISPLAY_NAME`, `PERSONA_CURSOR_SIGNING_KEY` | Gateway |
| `persona-app-ghcr` | `persona-app` | GHCR read-only pull token | Gateway·Web·migration Job |

- `persona-gateway-migrator`의 `DATABASE_URL`은 **migrator 계정**,
  `persona-gateway-runtime`의 것은 **runtime 계정**이다. 같은 값을 쓰면 계정 분리가 무의미해진다.
- `PERSONA_DB_TIMEOUT_SECONDS=2`는 비밀이 아니라 Deployment의 평문 env다.
- GHCR pull Secret은 **이미지가 실행되는 `persona-app`에** 만든다. 기존
  `persona-mock-sse` namespace의 Secret은 공유되지 않는다.

---

## 0. 현재 상태 확인

무엇이 이미 있는지 먼저 본다. **아래는 조회만 한다.**

```sh
hostname
kubectl config current-context
kubectl --context=kubernetes-admin@kubernetes cluster-info
kubectl --context=kubernetes-admin@kubernetes get nodes -o wide

# CNPG가 이미 설치돼 있는가
kubectl --context=kubernetes-admin@kubernetes get crd clusters.postgresql.cnpg.io
kubectl --context=kubernetes-admin@kubernetes -n cnpg-system get deploy
kubectl --context=kubernetes-admin@kubernetes get clusters.postgresql.cnpg.io -A

# 기존 PVC와 PV — local-path는 reclaimPolicy=Retain이라 과거 잔여물이 남아 있을 수 있다
kubectl --context=kubernetes-admin@kubernetes get pvc -A
kubectl --context=kubernetes-admin@kubernetes get pv
kubectl --context=kubernetes-admin@kubernetes get storageclass

# 기존 Gateway·HTTPRoute 소유권
kubectl --context=kubernetes-admin@kubernetes get gatewayclass,gateway,httproute -A
kubectl --context=kubernetes-admin@kubernetes -n traefik get svc,deploy -o wide

# 기존 namespace·Secret
kubectl --context=kubernetes-admin@kubernetes get ns
kubectl --context=kubernetes-admin@kubernetes get applications.argoproj.io -A
```

확인할 것: GatewayClass `traefik` 존재, Traefik HTTP entryPoint `8000`,
`persona-data`·`persona-app` namespace 부재, 같은 이름의 기존 PV 부재.

**Released 상태의 옛 PV가 남아 있으면** 새 PVC가 그것을 재사용하지 않는다.
노드에서 수동 정리가 필요한지 `docs/storage-and-recovery.md`를 보고 판단한다.

## 1. bootstrap — namespace와 Secret

```sh
kubectl --context=kubernetes-admin@kubernetes apply -f bootstrap/namespaces/persona-data.yaml
kubectl --context=kubernetes-admin@kubernetes apply -f bootstrap/namespaces/persona-app.yaml
```

Secret 4개를 위 계약대로 만든다. 값은 이 문서에 적지 않는다.
이미 있으면 다시 만들지 않고 키 이름만 확인한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data get secret persona-db-migrator -o jsonpath='{.data}' | tr ',' '\n'
kubectl --context=kubernetes-admin@kubernetes -n persona-app  get secret persona-gateway-migrator -o jsonpath='{.data}' | tr ',' '\n'
kubectl --context=kubernetes-admin@kubernetes -n persona-app  get secret persona-gateway-runtime  -o jsonpath='{.data}' | tr ',' '\n'
kubectl --context=kubernetes-admin@kubernetes -n persona-app  get secret persona-app-ghcr
```

## 2. CNPG operator

`bootstrap/cnpg/README.md`를 따른다. **중복 설치를 먼저 확인**하고 없을 때만 설치한다.

## 3. DB

Argo에 `persona-db` Application을 등록하고 **수동 Sync**한다.

```sh
kubectl --context=kubernetes-admin@kubernetes apply -f argocd/persona-db.yaml
```

완료 확인 — 다음 단계로 넘어가기 전에 `Cluster`가 healthy여야 한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data get cluster persona-db -o wide
kubectl --context=kubernetes-admin@kubernetes -n persona-data get pod,pvc
kubectl --context=kubernetes-admin@kubernetes -n persona-data get svc
```

`persona-db-rw` Service가 있어야 하고, PVC가 `Bound`이며 파드가 **worker1**에 있어야 한다.
PVC가 `Pending`이면 `WaitForFirstConsumer`라 파드 스케줄을 기다리는 중인지,
아니면 worker1에 공간이 없는지 구분한다.

## 4. runtime role 준비

migration 전에 role만 만든다. 권한은 migration 뒤에 준다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data exec -it persona-db-1 -- \
  psql -d persona_app -c "CREATE ROLE persona_runtime LOGIN PASSWORD '<값>'"
```

이 비밀번호는 `persona-gateway-runtime` Secret의 `DATABASE_URL`과 같아야 한다.

## 5. migration

```sh
# 진행 중인 migration Job이 없는지 먼저 본다. 동시 실행을 만들지 않는다.
kubectl --context=kubernetes-admin@kubernetes -n persona-app get job

kubectl --context=kubernetes-admin@kubernetes apply -f argocd/persona-migrate.yaml
```

Argo에서 수동 Sync한 뒤 완료를 확인한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app get job persona-migrate-0001-persona-minimal
kubectl --context=kubernetes-admin@kubernetes -n persona-app logs job/persona-migrate-0001-persona-minimal
```

`COMPLETIONS 1/1`이어야 한다. `backoffLimit: 0`이라 실패하면 재시도하지 않고 그대로 남는다.

**재실행이 필요하면**: 로그를 먼저 보관한 뒤 Job을 삭제하고 다시 Sync한다.
Job은 불변 필드가 많아 같은 이름으로 수정되지 않는다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app logs job/persona-migrate-0001-persona-minimal > migrate-failed-$(date +%Y%m%d%H%M%S).log
kubectl --context=kubernetes-admin@kubernetes -n persona-app delete job persona-migrate-0001-persona-minimal
```

**자동 downgrade를 실행하지 않는다.** 현재 `downgrade()`는 `DROP SCHEMA persona_minimal CASCADE`다.

## 6. grant 적용

migration이 끝난 뒤에 한다. 테이블이 없으면 GRANT 대상이 없어 실패한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data exec -i persona-db-1 -- \
  psql -d persona_app -v ON_ERROR_STOP=1 < db/grants/persona_minimal.sql
```

## 7. runtime 권한 검증

앱을 올리기 전에 계정 경계가 실제로 서 있는지 본다.
아래는 **모두 거부되어야** 한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data exec -it persona-db-1 -- \
  psql "postgresql://persona_runtime:<값>@127.0.0.1:5432/persona_app" -c \
  "UPDATE persona_minimal.alembic_version SET version_num = 'tampered'"

kubectl --context=kubernetes-admin@kubernetes -n persona-data exec -it persona-db-1 -- \
  psql "postgresql://persona_runtime:<값>@127.0.0.1:5432/persona_app" -c \
  "CREATE TABLE persona_minimal.should_not_exist (id int)"
```

같은 검사를 로컬에서 격리 Postgres로 먼저 돌려볼 수 있다:
`scripts/verify-db-privileges.sh` (홈 클러스터를 건드리지 않는다).

## 8. 앱 배포

```sh
kubectl --context=kubernetes-admin@kubernetes apply -f argocd/persona-app.yaml
```

Argo에서 Diff를 확인하고 수동 Sync한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app get deploy,pod,svc -o wide
kubectl --context=kubernetes-admin@kubernetes -n persona-app get gateway,httproute
```

확인할 것:

- Gateway 파드 1개, Web 파드 2개가 **worker1·2에** 있고 CP에는 없다
- Web 두 파드가 서로 다른 노드에 있으면 anti-affinity가 의도대로 동작한 것이다
  (preferred라 한 노드에 몰려도 실패는 아니다)
- Gateway readiness가 통과한다. 계속 `0/1`이면 grant 부족이나 DB 연결을 의심한다:
  `kubectl -n persona-app logs deploy/persona-gateway`

**Gateway·HTTPRoute의 상태 조건을 본다.** 파드가 떠 있어도 라우팅이 안 붙을 수 있다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app get gateway persona-app -o jsonpath='{.status.conditions}' | tr ',' '\n'
kubectl --context=kubernetes-admin@kubernetes -n persona-app get gateway persona-app -o jsonpath='{.status.listeners}' | tr ',' '\n'
kubectl --context=kubernetes-admin@kubernetes -n persona-app get httproute persona-app -o jsonpath='{.status.parents}' | tr ',' '\n'
```

`Accepted=True`, `Programmed=True`, HTTPRoute의 `ResolvedRefs=True`를 확인한다.
backend 참조가 `persona-gateway:8080`, `persona-web:8080`으로 풀렸는지도 본다.

### mock SSE 경로와의 충돌 확인 — 반드시 본다

`persona-mock-sse` Gateway가 **같은 Traefik entryPoint 8000**에 붙어 있고
Exact `/mock/chat`을 가진다. 이번 HTTPRoute는 PathPrefix `/`를 가지므로 같은 entryPoint의
모든 경로를 후보로 잡는다.

Gateway API 명세상 Exact가 PathPrefix보다 먼저 맞으므로 이론상 공존하지만,
**두 Gateway가 한 entryPoint를 공유할 때 Traefik이 실제로 어떻게 합치는지는 확인해야 안다.**
아래로 실제 동작을 본다.

```sh
# 기존 mock 경로가 그대로 응답하는가
kubectl --context=kubernetes-admin@kubernetes -n persona-mock-sse get httproute persona-mock-sse -o jsonpath='{.status.parents}' | tr ',' '\n'
kubectl --context=kubernetes-admin@kubernetes -n traefik logs deploy/traefik | tail -50
```

`/mock/chat`이 Web으로 넘어가기 시작하면 충돌이다. 그 경우 이번 Gateway에 별도 hostname을
주거나 entryPoint를 나누는 설계가 필요하다. **임의로 주소를 만들지 말고 사용자와 정한다.**

## 9. 브라우저 종단 검증

Tailnet 진입 방식은 기존 결정과 실제 설정을 먼저 확인한다.
이 문서는 접속 주소를 지어내지 않는다. 공개 LoadBalancer·NodePort·Funnel을 추가하지 않는다.

같은 origin에서 확인할 것:

| 시나리오 | 기대 |
| --- | --- |
| `/` 로드 | 웹 화면이 뜬다 |
| 토큰 입력 | `/v1/me`가 200, 사용자 이름 표시 |
| 잘못된 토큰 | 401, 민감 정보 없는 오류 |
| 캐릭터 목록 | `/v1/personas` 200 |
| 캐릭터 생성 | 201, 목록에 반영 |
| 같은 이름 재생성 | 409 중복 |
| **3개 한도** | 4번째 생성이 409 |
| 새로고침 | 토큰은 브라우저 메모리에만 있어 다시 입력해야 한다 (설계된 동작) |
| Gateway 파드 재시작 후 | 캐릭터 목록이 그대로 유지된다 |

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app rollout restart deploy/persona-gateway
kubectl --context=kubernetes-admin@kubernetes -n persona-app rollout status deploy/persona-gateway
```

## 10. 실패 시 — 앱 rollback과 DB 복구를 구분한다

**앱 rollback** (선언을 되돌리는 것)

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app rollout undo deploy/persona-gateway
kubectl --context=kubernetes-admin@kubernetes -n persona-app rollout undo deploy/persona-web
```

또는 Argo에서 이전 revision으로 Sync한다.

**여기에 PVC 삭제나 DB 초기화를 포함하지 않는다.** 앱을 되돌리는 것과 데이터를 되돌리는 것은
다른 작업이고, 섞으면 복구 가능한 상황을 복구 불가능하게 만든다.
`persona-db` Cluster에는 `Prune=false,Delete=false`가 걸려 있어 Argo가 지우지 못한다.

**DB 복구**는 `docs/storage-and-recovery.md`의 논리 덤프 절차를 따른다.
`pg_dump`만으로는 role과 전역 설정이 빠지므로 `pg_dumpall --globals-only`가 함께 필요하다.
migration을 되돌리려고 `alembic downgrade`를 쓰지 않는다 — 스키마를 통째로 지운다.

**주의**: local-path는 `reclaimPolicy=Retain`이라 PVC를 지워도 노드 디스크의 디렉터리가 남고,
PV는 `Released`가 되어 재사용되지 않는다. 그리고 `allowVolumeExpansion=false`라
PVC 크기는 나중에 못 늘린다.

## 이 런북이 다루지 않는 것

업로드·ingestion·Qdrant·채팅·GPU·Go dispatcher, 백업 서비스 추가, HA·replica 확장,
공개 인터넷 노출, CNPG operator 업그레이드·제거.
