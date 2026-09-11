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

# PriorityClass — 없으면 파드가 admission에서 거부된다
kubectl --context=kubernetes-admin@kubernetes get priorityclass persona-critical persona-low
```

확인할 것: GatewayClass `traefik` 존재, Traefik HTTP entryPoint `8000`,
`persona-data`·`persona-app` namespace 부재, 같은 이름의 기존 PV 부재,
`persona-critical`·`persona-low` PriorityClass 존재.

**Released 상태의 옛 PV가 남아 있으면** 새 PVC가 그것을 재사용하지 않는다.
노드에서 수동 정리가 필요한지 `docs/storage-and-recovery.md`를 보고 판단한다.

## 1. bootstrap — PriorityClass, namespace, Secret

### 1-a. PriorityClass

세 워크로드가 모두 PriorityClass를 참조한다 — DB는 `persona-critical`, Gateway·Web·migration
Job은 `persona-low`다. **클래스가 없으면 Deployment는 만들어지되 파드가 admission에서 거부된다.**
파드가 아예 생기지 않으므로 "왜 안 뜨지"를 한참 헤매기 쉽다.

Traefik이 이미 `persona-low`를 쓰고 있어 Traefik이 떠 있다면 존재할 가능성이 높다.
그래도 확인하고 넘어간다.

```sh
kubectl --context=kubernetes-admin@kubernetes get priorityclass persona-critical persona-low
```

없으면 준비한다. 이 선언은 클러스터 전역 자원이라 Argo가 관리하지 않는다.

```sh
kubectl --context=kubernetes-admin@kubernetes apply -f bootstrap/priorityclasses/priorityclasses.yaml
```

### 1-b. namespace

```sh
kubectl --context=kubernetes-admin@kubernetes apply -f bootstrap/namespaces/persona-data.yaml
kubectl --context=kubernetes-admin@kubernetes apply -f bootstrap/namespaces/persona-app.yaml
```

### 1-c. Secret

Secret 4개를 위 계약대로 만든다. 값은 이 문서에 적지 않는다.
이미 있으면 다시 만들지 않고 키 이름만 확인한다.

아래는 **키 이름만** 출력한다. `-o jsonpath='{.data}'`를 쓰지 않는 이유는 그것이 키가 아니라
base64로 인코딩된 **값 전체**를 내놓기 때문이다. base64는 암호화가 아니므로 DB 비밀번호와
토큰이 터미널 스크롤백과 셸 기록에 그대로 남는다.

```sh
for ns_secret in \
  "persona-data persona-db-migrator" \
  "persona-app persona-gateway-migrator" \
  "persona-app persona-gateway-runtime" \
  "persona-app persona-app-ghcr"; do
  set -- $ns_secret
  echo "== $2 ($1)"
  kubectl --context=kubernetes-admin@kubernetes -n "$1" get secret "$2" \
    -o go-template='{{range $k, $_ := .data}}{{$k}}{{"\n"}}{{end}}'
done
```

`go-template`은 kubectl에 내장돼 있어 `jq` 같은 추가 도구가 필요 없다.
`$_`로 값을 버리므로 값이 출력 경로에 들어가지 않는다.

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

비밀번호를 `CREATE ROLE ... PASSWORD '값'`으로 주지 않는다. 그렇게 하면 셸 기록뿐 아니라
**PostgreSQL 서버 로그에도 평문으로 남는다.** 대신 role을 비밀번호 없이 만든 뒤 psql의
`\password`로 설정한다. 이 명령은 입력을 숨겨 받아 암호화한 `ALTER ROLE`로 보내며,
매뉴얼이 밝히듯 *"명령 기록, 서버 로그, 그 밖 어디에도 평문이 남지 않게"* 한다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data exec -it persona-db-1 -- \
  psql -d persona_app
```

psql 세션에서:

```
CREATE ROLE persona_runtime LOGIN;
\password persona_runtime
```

이 비밀번호는 `persona-gateway-runtime` Secret의 `DATABASE_URL`에 들어간 것과 같아야 한다.

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

**운영 DB와 격리 DB는 검사 방법이 다르다.** 찾으려는 결함이 "권한이 과도하다"이므로,
운영에서 그 결함을 실행해 확인하면 결함이 있을 때 실제로 DB가 바뀐다.
`alembic_version`이 바뀌면 readiness가 막히고 다음 migration도 깨진다.

| | 운영 DB (여기) | 격리 DB (`scripts/verify-db-privileges.sh`) |
| --- | --- | --- |
| 기본 방법 | **카탈로그 조회** — 쓰기를 시도하지 않는다 | 실제 문장을 실행해 거부를 확인한다 |
| 실행 시도 | 필요하면 `BEGIN … ROLLBACK` 안에서만 | 제약 없음 |
| 안전 근거 | DB를 바꾸지 않는다 | 전용 임시 Postgres를 직접 만들고 끝나면 지운다. 운영을 가리킬 수 없다 |

### 7-a. 접속 — 비밀번호를 인자에 넣지 않는다

`postgresql://user:password@…`를 명령 인자로 주면 `ps` 출력과 셸 기록에 노출된다.
접속 문자열에서 비밀번호를 빼고 `-W`로 숨겨진 프롬프트를 받는다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-data exec -it persona-db-1 -- \
  psql -h 127.0.0.1 -U persona_runtime -d persona_app -W
```

### 7-b. 카탈로그로 권한을 읽는다 (쓰기 없음)

`has_*_privilege`에 권한을 **콤마로 나열하면 "하나라도 있으면 참"**이 된다. 그러면 느슨한
권한이 통과로 보이므로, 권한마다 컬럼을 나눈다.

```sql
SELECT has_database_privilege('persona_runtime','persona_app','CONNECT')                    AS connect_t,
       has_schema_privilege  ('persona_runtime','persona_minimal','USAGE')                  AS schema_usage_t,
       has_schema_privilege  ('persona_runtime','persona_minimal','CREATE')                 AS schema_create_f,
       has_schema_privilege  ('persona_runtime','public','CREATE')                          AS public_create_f;

SELECT has_table_privilege('persona_runtime','persona_minimal.alembic_version','SELECT')    AS ver_select_t,
       has_table_privilege('persona_runtime','persona_minimal.alembic_version','UPDATE')    AS ver_update_f,
       has_table_privilege('persona_runtime','persona_minimal.alembic_version','INSERT')    AS ver_insert_f,
       has_table_privilege('persona_runtime','persona_minimal.alembic_version','DELETE')    AS ver_delete_f;

SELECT has_table_privilege('persona_runtime','persona_minimal.personas','SELECT')           AS p_select_t,
       has_table_privilege('persona_runtime','persona_minimal.personas','INSERT')           AS p_insert_t,
       has_table_privilege('persona_runtime','persona_minimal.personas','UPDATE')           AS p_update_t,
       has_table_privilege('persona_runtime','persona_minimal.personas','DELETE')           AS p_delete_f,
       has_table_privilege('persona_runtime','persona_minimal.personas','TRUNCATE')         AS p_truncate_f;

-- 상속으로 우회할 수 있으면 위 결과가 무의미해진다.
SELECT pg_has_role('persona_runtime','persona_migrator','MEMBER')                           AS inherits_migrator_f;

-- ALTER와 DROP은 권한이 아니라 소유권이다. has_*_privilege로는 볼 수 없다.
SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'persona_minimal';
```

컬럼 이름의 `_t`/`_f`가 기대값이다. `_f`인데 `t`가 나오면 `db/grants/persona_minimal.sql`을
다시 본다. 마지막 질의의 `tableowner`는 전부 `persona_migrator`여야 하며,
`persona_runtime`이 하나라도 있으면 그 테이블은 runtime이 마음대로 바꿀 수 있다.

### 7-c. 실행 동작까지 보고 싶을 때 — 트랜잭션 안에서만

```sql
BEGIN;
UPDATE persona_minimal.alembic_version SET version_num = 'tampered';
ROLLBACK;

BEGIN;
CREATE TABLE persona_minimal.should_not_exist (id int);
ROLLBACK;
```

권한이 정상이면 각 문장이 거부되고 트랜잭션은 abort 상태가 되며 `ROLLBACK`이 그것을 정리한다.
권한이 과도해서 **성공하더라도 `ROLLBACK`이 되돌린다.** 어느 쪽이든 DB는 바뀌지 않는다.
`ROLLBACK`을 빠뜨리면 이 검사 자체가 사고가 된다.

확인 후 `alembic_version`이 그대로인지 본다:

```sql
SELECT version_num FROM persona_minimal.alembic_version;   -- 0001_persona_minimal
```

### 7-d. 격리 DB에서 먼저 돌려보기

```sh
scripts/verify-db-privileges.sh
```

전용 임시 Postgres를 직접 만들어 migration·grant 적용까지 재현한 뒤 거부를 실제로 확인한다.
홈 클러스터를 건드리지 않으며 운영 DB를 가리킬 수 없다.

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

## 10. 스케줄링 — 배포 중 진단

**기본 `kube-scheduler`를 쓴다.** 커스텀 스케줄러나 스케줄러 플러그인은 없다.
다만 배치·우선순위·업데이트 규칙은 우리가 직접 얹은 것이고, 파드가 안 뜰 때 봐야 할 곳이 그것들이다.

규칙 전체와 그 근거는 **[저장소 README의 "스케줄링 전략"](../README.md)** 에 있다.
여기서는 배포 중에 실제로 쓰는 진단 절차만 다룬다. 두 곳에 같은 표를 두면 갈라진다.

### 파드가 `Pending`일 때 보는 순서

```sh
kubectl --context=kubernetes-admin@kubernetes -n <ns> describe pod <pod> | sed -n '/Events:/,$p'
```

Events 메시지로 원인을 가른다.

| 메시지 | 원인 | 볼 곳 |
| --- | --- | --- |
| `no PriorityClass with name ... was found` | PriorityClass 부재 | 위 1-a |
| `didn't match Pod's node affinity/selector` | worker1·2에 배치 불가, 또는 노드 이름 불일치 | `kubectl get nodes`로 hostname 확인 |
| `Insufficient memory` / `Insufficient cpu` | 워커 자원 부족 | `kubectl top nodes`. requests는 초기 예산이라 실측 후 조정 대상이다 |
| `pod has unbound immediate PersistentVolumeClaims` | PVC 미바인딩 | local-path는 `WaitForFirstConsumer`라 파드 스케줄을 기다리는 정상 상태일 수 있다. 오래 `Pending`이면 worker1 디스크를 본다 |
| `ImagePullBackOff` (Pending 아님) | pull Secret 부재·만료 | `persona-app-ghcr`. 두 패키지는 private이다 |

필수 조건을 만족하는 노드에 자리가 없으면 파드는 그대로 `Pending`으로 남는다.
나중에 자리가 나도 **이미 실행 중인 파드가 자동으로 재분산되지는 않는다.**

### 사라진 파드가 축출인지 확인

`persona-low`는 값이 낮아 자원 압박 시 먼저 축출 대상이 된다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app get events --sort-by=.lastTimestamp | grep -iE 'evict|preempt'
```

### 업데이트 중 중단 구간

Gateway는 replica 1개에 `maxSurge: 0`이라 **교체 중 준비된 API가 없는 구간이 생긴다.**
Web은 2개라 정상 교체 중에는 한 대가 남지만 무중단 보장은 아니다.
브라우저 검증을 롤아웃 직후에 하면 이 구간에 걸릴 수 있다.

```sh
kubectl --context=kubernetes-admin@kubernetes -n persona-app rollout status deploy/persona-gateway
```

## 11. 실패 시 — 앱 rollback과 DB 복구를 구분한다

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
