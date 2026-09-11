-- Gateway runtime 계정의 권한을 확정한다. migration이 끝난 뒤에 적용한다.
--
-- 왜 migration 뒤인가: 테이블은 Alembic이 만들고 소유자는 persona_migrator다.
-- 테이블이 없는 상태에서는 GRANT 대상이 없어 실패한다.
--
-- 왜 테이블을 하나씩 적는가: `GRANT ... ON ALL TABLES IN SCHEMA`나
-- `ALTER DEFAULT PRIVILEGES ... GRANT UPDATE`를 쓰면 alembic_version에도 UPDATE가 붙는다.
-- 그러면 runtime이 migration 상태를 바꿀 수 있게 되어 계정 분리의 의미가 사라진다.
-- 새 migration이 테이블을 추가하면 이 파일도 함께 고쳐야 한다. 그 책임은 운영 절차에 있고
-- migration Job이 대신해 주지 않는다.
--
-- 테이블 정의는 Gateway의 Alembic이 소유한다. 여기에 CREATE TABLE을 복제하지 않는다.
--
-- 적용 방법(값은 사용자가 CP에서):
--   psql "$MIGRATOR_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/grants/persona_minimal.sql

\set ON_ERROR_STOP on

-- 1. 기본으로 열려 있는 경로를 먼저 닫는다.
--    PUBLIC은 모든 role이 자동으로 속하므로, 여기 남은 권한은 runtime에도 그대로 적용된다.
REVOKE ALL ON DATABASE persona_app FROM PUBLIC;
REVOKE ALL ON SCHEMA persona_minimal FROM PUBLIC;
-- PostgreSQL 15부터 public 스키마의 CREATE는 PUBLIC에서 빠졌지만, 이전 버전에서
-- 복원된 DB일 수 있으므로 명시적으로 한 번 더 회수한다.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- 2. 접속과 스키마 탐색.
--    USAGE만 준다. CREATE를 주지 않으므로 runtime은 스키마에 객체를 만들 수 없다.
GRANT CONNECT ON DATABASE persona_app TO persona_runtime;
GRANT USAGE ON SCHEMA persona_minimal TO persona_runtime;

-- 3. 앱 테이블. DELETE는 주지 않는다 — 현재 코드는 행을 지우지 않는다.
--    users는 ON CONFLICT DO UPDATE 때문에 UPDATE가 필요하고,
--    SELECT ... FOR UPDATE(사용자별 생성 직렬화)도 UPDATE 권한을 요구한다.
GRANT SELECT, INSERT, UPDATE ON persona_minimal.users            TO persona_runtime;
GRANT SELECT, INSERT, UPDATE ON persona_minimal.personas         TO persona_runtime;
GRANT SELECT, INSERT, UPDATE ON persona_minimal.idempotency_records TO persona_runtime;

-- 4. migration 상태는 읽기만. readiness가 required revision을 확인할 때 필요하다.
GRANT SELECT ON persona_minimal.alembic_version TO persona_runtime;
-- 앞선 운영이나 복원으로 쓰기 권한이 붙어 있을 수 있으므로 명시적으로 회수한다.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON persona_minimal.alembic_version FROM persona_runtime;

-- 5. 시퀀스 권한은 주지 않는다. 0001_persona_minimal에는 시퀀스가 없다.
--    id는 앱이 만든 uuid이고 시각은 now() 기본값이다. 시퀀스가 생기면 이 주석도 고친다.
