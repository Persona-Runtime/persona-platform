#!/usr/bin/env bash
set -euo pipefail

# migrator와 runtime 계정 분리가 실제로 동작하는지 격리된 Postgres에서 확인한다.
# 선언과 SQL을 읽는 것만으로는 "runtime이 DDL을 못 한다"를 알 수 없다. 실제로 시도해 본다.
#
# GHCR에 게시된 Gateway digest를 그대로 쓴다.
# 홈 클러스터를 건드리지 않는다. 합성 자격증명만 사용한다.
#
# 사용법: scripts/verify-db-privileges.sh [gateway-image]

# 도구가 없으면 검사가 조용히 건너뛰어진다. 먼저 확인하고 멈춘다.
for tool in docker curl grep awk mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
grants_sql="${repo_dir}/db/grants/persona_minimal.sql"

gateway_image="${1:-ghcr.io/persona-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6}"
# 운영은 CNPG 이미지(ghcr.io/cloudnative-pg/postgresql:16.15-standard-bookworm)를 쓰지만
# 여기서는 공식 이미지를 쓴다. CNPG 이미지에는 Entrypoint도 Cmd도 없어서 — operator가
# instance manager를 주입하는 베이스 이미지다 — 단독 컨테이너로 띄울 수 없다.
#
# 검사 대상인 GRANT·REVOKE 동작은 PostgreSQL 자체의 것이고 이미지에 따라 달라지지 않는다.
# 그래도 차이를 줄이려고 **같은 마이너 버전 16.15와 같은 bookworm 베이스**로 맞춘다.
# CNPG 설정(WAL, 확장, 파라미터)까지 재현하지는 않으므로, 이 검사는 권한 계약만 확인한다.
postgres_image="postgres:16.15-bookworm@sha256:bb3e1a57e5407e0a5280b4211980a5e537f4abd234a87014ac979849a78dd825"

# PID를 붙여 다른 작업의 컨테이너를 재사용하지 않는다.
prefix="db-priv-$$"
network="${prefix}-net"
postgres="${prefix}-pg"
api="${prefix}-api"

# --- 합성 자격증명 (실제 값 아님) ---
bootstrap_user="postgres"
bootstrap_password="bootstrap_password_not_real"
db_name="persona_app"
migrator_user="persona_migrator"
migrator_password="migrator_password_not_real"
runtime_user="persona_runtime"
runtime_password="runtime_password_not_real"
bearer_token="db-priv-bearer-token-not-real"
user_id="db-priv-user-0001"
display_name="권한 검증 사용자"
cursor_key="db-priv-cursor-signing-key-not-real"

migrator_url="postgresql://${migrator_user}:${migrator_password}@${postgres}:5432/${db_name}"
runtime_url="postgresql://${runtime_user}:${runtime_password}@${postgres}:5432/${db_name}"

# 서버가 응답하지 않아도 검사가 멈추지 않게 하는 상한이다. 판정 기준이 아니다.
connect_timeout_seconds="3"
request_timeout_seconds="10"

workdir="$(mktemp -d)"
failures=0

cleanup() {
  # postgres 이미지에는 데이터 볼륨 선언이 있어 실행마다 익명 볼륨이 생긴다.
  # --volumes는 그 컨테이너에 달린 익명 볼륨만 지운다. volume prune은 쓰지 않는다.
  docker rm --force --volumes "$api" "$postgres" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }
step() { printf '\n[%s]\n' "$1"; }

status_of() {
  local output rc
  output="$(curl --silent \
    --connect-timeout "$connect_timeout_seconds" \
    --max-time "$request_timeout_seconds" \
    --output "$workdir/body.json" \
    --write-out '%{http_code}' "$@")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '000 %s' "$rc"
    return 0
  fi
  printf '%s 0' "$output"
}

http_code() { printf '%s' "${1%% *}"; }
curl_exit() { printf '%s' "${1##* }"; }

psql_as() {
  local user="$1" password="$2"
  shift 2
  docker exec --env PGPASSWORD="$password" "$postgres" \
    psql --quiet --no-align --tuples-only \
    --username "$user" --dbname "$db_name" "$@"
}

# 거부되어야 하는 문장을 시험한다. 성공하면 그 자체가 결함이다.
expect_denied() {
  local desc="$1" sql="$2"
  local out
  if out="$(psql_as "$runtime_user" "$runtime_password" --set ON_ERROR_STOP=1 --command "$sql" 2>&1)"; then
    fail "${desc}: 거부돼야 하는데 성공했다"
    return
  fi
  # 권한 오류인지 확인한다. 문법 오류나 연결 실패를 "거부됨"으로 세지 않는다.
  if printf '%s' "$out" | grep -qiE 'permission denied|must be owner'; then
    ok "${desc}: 권한 거부"
  else
    fail "${desc}: 권한 오류가 아닌 이유로 실패했다"
  fi
}

step "0. 대상"
echo "  gateway  : ${gateway_image}"
echo "  postgres : ${postgres_image}"
echo "  참고     : 운영은 CNPG 이미지다. 권한 동작만 같은 마이너 버전으로 확인한다."
if [ "$(uname -m)" != "x86_64" ]; then
  echo "  주의: amd64가 아닌 호스트다. 에뮬레이션 실행이며 성능 기준선으로 쓰지 않는다."
fi

step "1. 격리 Postgres 기동"
docker network create "$network" >/dev/null
docker run --detach --name "$postgres" --network "$network" --platform linux/amd64 \
  --env POSTGRES_USER="$bootstrap_user" \
  --env POSTGRES_PASSWORD="$bootstrap_password" \
  --env POSTGRES_DB="$db_name" \
  "$postgres_image" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$postgres" pg_isready --username "$bootstrap_user" --dbname "$db_name" >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$postgres" pg_isready --username "$bootstrap_user" --dbname "$db_name" >/dev/null
ok "Postgres 준비 완료 (호스트 포트 비공개)"

step "2. 계정 분리 — CNPG bootstrap과 같은 모양"
# CNPG는 initdb.owner로 migrator를 만들고 DB 소유권을 준다. 그 상태를 재현한다.
# runtime은 이 단계에서 role만 만들고, 권한은 migration 뒤에 grants SQL이 준다.
docker exec --env PGPASSWORD="$bootstrap_password" "$postgres" \
  psql --quiet --username "$bootstrap_user" --dbname "$db_name" --set ON_ERROR_STOP=1 --command "
    CREATE ROLE ${migrator_user} LOGIN PASSWORD '${migrator_password}';
    CREATE ROLE ${runtime_user}  LOGIN PASSWORD '${runtime_password}';
    ALTER DATABASE ${db_name} OWNER TO ${migrator_user};
  " >/dev/null
ok "migrator·runtime role 생성, DB 소유자는 migrator"

step "3. migrator로 migration 실행"
docker run --rm --network "$network" --platform linux/amd64 \
  --entrypoint /app/.venv/bin/alembic \
  --env DATABASE_URL="$migrator_url" \
  "$gateway_image" upgrade head >"$workdir/migrate.log" 2>&1 || {
    echo "--- migration 실패 로그 ---" >&2
    cat "$workdir/migrate.log" >&2
    exit 1
  }
applied="$(psql_as "$bootstrap_user" "$bootstrap_password" --command \
  'SELECT version_num FROM persona_minimal.alembic_version' | tr -d '[:space:]')"
if [ "$applied" = "0001_persona_minimal" ]; then
  ok "migration 성공, revision ${applied}"
else
  fail "적용된 revision이 예상과 다르다: ${applied}"
fi

step "4. grant 적용"
docker cp "$grants_sql" "${postgres}:/tmp/grants.sql" >/dev/null
docker exec --env PGPASSWORD="$migrator_password" "$postgres" \
  psql --quiet --username "$migrator_user" --dbname "$db_name" \
  --set ON_ERROR_STOP=1 --file /tmp/grants.sql >"$workdir/grants.log" 2>&1 || {
    echo "--- grant 실패 로그 ---" >&2
    cat "$workdir/grants.log" >&2
    exit 1
  }
ok "db/grants/persona_minimal.sql 적용"

step "5. runtime 자격증명으로 앱이 동작하는가"
docker run --detach --name "$api" --network "$network" --platform linux/amd64 \
  --user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,uid=10001,gid=10001,mode=1700 \
  --publish 127.0.0.1::8080 \
  --env DATABASE_URL="$runtime_url" \
  --env PERSONA_STATIC_BEARER_TOKEN="$bearer_token" \
  --env PERSONA_STATIC_USER_ID="$user_id" \
  --env PERSONA_STATIC_DISPLAY_NAME="$display_name" \
  --env PERSONA_CURSOR_SIGNING_KEY="$cursor_key" \
  --env PERSONA_DB_TIMEOUT_SECONDS="2" \
  "$gateway_image" >/dev/null
port="$(docker port "$api" 8080/tcp | awk -F: 'NR == 1 { print $NF }')"
base_url="http://127.0.0.1:${port}"

ready=false
for _ in $(seq 1 30); do
  if [ "$(http_code "$(status_of "${base_url}/readyz")")" = "200" ]; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" = true ]; then
  # readiness는 필수 revision까지 확인한다. 즉 alembic_version SELECT 권한이 살아 있다는 뜻이다.
  ok "readiness 200 — runtime이 alembic_version을 읽을 수 있다"
else
  fail "readiness가 200이 되지 않았다 — grant가 부족할 수 있다"
fi

result="$(status_of --header "Authorization: Bearer ${bearer_token}" "${base_url}/v1/me")"
if [ "$(http_code "$result")" = "200" ] && grep -q "$user_id" "$workdir/body.json"; then
  ok "인증 성공"
else
  fail "인증 실패 (status $(http_code "$result"), curl exit $(curl_exit "$result"))"
fi

idem_key="22222222-3333-4444-8555-666666666666"
persona_name="권한 검증 캐릭터"
result="$(status_of --request POST \
  --header "Authorization: Bearer ${bearer_token}" \
  --header "Idempotency-Key: ${idem_key}" \
  --header "Content-Type: application/json" \
  --data "{\"name\":\"${persona_name}\"}" \
  "${base_url}/v1/personas")"
created_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$workdir/body.json")"
if [ "$(http_code "$result")" = "201" ] && [ -n "$created_id" ]; then
  ok "생성 성공 (INSERT·UPDATE 권한 확인)"
else
  fail "생성 실패 (status $(http_code "$result"))"
fi

result="$(status_of --header "Authorization: Bearer ${bearer_token}" "${base_url}/v1/personas")"
if [ "$(http_code "$result")" = "200" ] && grep -q "$created_id" "$workdir/body.json"; then
  ok "목록 조회 성공"
else
  fail "목록 조회 실패 (status $(http_code "$result"))"
fi

result="$(status_of --request POST \
  --header "Authorization: Bearer ${bearer_token}" \
  --header "Idempotency-Key: ${idem_key}" \
  --header "Content-Type: application/json" \
  --data "{\"name\":\"${persona_name}\"}" \
  "${base_url}/v1/personas")"
replay_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$workdir/body.json")"
rows="$(psql_as "$bootstrap_user" "$bootstrap_password" --command \
  'SELECT count(*) FROM persona_minimal.personas' | tr -d '[:space:]')"
if [ "$replay_id" = "$created_id" ] && [ "$rows" = "1" ]; then
  ok "멱등 재전송: 같은 ID, 행 수 ${rows}"
else
  fail "멱등 재전송 실패 (id ${replay_id}, rows ${rows})"
fi

step "6. runtime이 할 수 없어야 하는 것"
expect_denied "스키마에 테이블 생성"       "CREATE TABLE persona_minimal.should_not_exist (id int)"
expect_denied "public 스키마에 테이블 생성" "CREATE TABLE public.should_not_exist (id int)"
expect_denied "테이블 구조 변경"           "ALTER TABLE persona_minimal.personas ADD COLUMN should_not_exist int"
expect_denied "테이블 삭제"               "DROP TABLE persona_minimal.idempotency_records"
expect_denied "테이블 비우기"             "TRUNCATE persona_minimal.personas"
expect_denied "행 삭제"                  "DELETE FROM persona_minimal.personas"
expect_denied "migration revision 변경"   "UPDATE persona_minimal.alembic_version SET version_num = 'tampered'"
expect_denied "migration revision 삭제"   "DELETE FROM persona_minimal.alembic_version"

# 권한 우회 경로도 본다. 멤버십이나 PUBLIC 권한이 남아 있으면 위 거부가 무의미해진다.
membership="$(psql_as "$bootstrap_user" "$bootstrap_password" --command \
  "SELECT pg_has_role('${runtime_user}', '${migrator_user}', 'MEMBER')" | tr -d '[:space:]')"
if [ "$membership" = "f" ]; then
  ok "runtime은 migrator의 멤버가 아니다"
else
  fail "runtime이 migrator를 상속한다 — 위 거부를 우회할 수 있다"
fi

public_create="$(psql_as "$bootstrap_user" "$bootstrap_password" --command \
  "SELECT has_schema_privilege('public', 'public', 'CREATE')" | tr -d '[:space:]')"
if [ "$public_create" = "f" ]; then
  ok "PUBLIC에 public 스키마 CREATE 권한이 없다"
else
  fail "PUBLIC이 public 스키마에 CREATE를 가진다"
fi

step "결과"
if [ "$failures" -eq 0 ]; then
  echo "  권한 분리 검증 통과"
  exit 0
fi
echo "  실패 ${failures}건" >&2
exit 1
