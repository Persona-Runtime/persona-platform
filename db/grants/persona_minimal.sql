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
--
-- 이 파일은 GRANT/REVOKE만 담고 여러 번 적용해도 결과가 같다. 권한을 넓히는 변경은
-- 그 권한을 쓰는 Gateway 이미지를 Sync하기 **전에** 적용한다 — 이전 이미지는 추가 권한을
-- 쓰지 않으므로 먼저 적용해도 동작이 바뀌지 않지만, 순서가 반대면 새 이미지의 해당
-- 요청이 permission denied로 실패한다.

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

-- 3. 앱 테이블. users·personas에는 DELETE를 주지 않는다 — 캐릭터 삭제
--    (DELETE /v1/personas/{id}, persona-gateway 4eaa9cc)는 캐릭터 행을 지우지 않고
--    이름을 비운 tombstone으로 남긴다(deleted_at·deletion_id). 생성·삭제 멱등 기록이
--    그 행을 가리켜야 옛 키 재전송이 새 캐릭터를 만들지 않기 때문이다.
--    users는 ON CONFLICT DO UPDATE 때문에 UPDATE가 필요하고,
--    SELECT ... FOR UPDATE(사용자별 생성 직렬화)도 UPDATE 권한을 요구한다.
GRANT SELECT, INSERT, UPDATE ON persona_minimal.users            TO persona_runtime;
GRANT SELECT, INSERT, UPDATE ON persona_minimal.personas         TO persona_runtime;
--    idempotency_records는 캐릭터 삭제가 초안 관련 멱등 기록(생성·삭제 외 operation)을
--    지운다. 권한 검사는 지울 행이 없어도 문장 단위로 하므로, DELETE가 없으면 대화가 없는
--    캐릭터 삭제도 permission denied(500)로 실패한다.
GRANT SELECT, INSERT, UPDATE, DELETE ON persona_minimal.idempotency_records TO persona_runtime;

-- 3-1. 초안과 그 자료(0002_persona_draft). **여기에만 DELETE를 준다.**
--      초안 폐기와 자료 제거는 행을 지운다. 참조만 끊으면 본문이 그대로 남아 원문 quota가
--      회수되지 않는다. DELETE 범위를 이 두 테이블로 한정해 위 세 테이블의 원칙은 그대로 둔다.
GRANT SELECT, INSERT, UPDATE, DELETE ON persona_minimal.material_versions TO persona_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON persona_minimal.material_sources  TO persona_runtime;

-- 3-2. 색인 조각(0003_material_chunks). UPDATE는 주지 않는다 — 재색인은 값을 고치는 게
--      아니라 DELETE 후 INSERT로 통째로 다시 만든다(같은 version_id 조각을 지우고 새로
--      넣음). UPDATE 권한이 없으면 그 경로를 우회해 행 하나만 몰래 고치는 코드를 못 짠다.
GRANT SELECT, INSERT, DELETE ON persona_minimal.material_chunks TO persona_runtime;

-- 3-3. 대화(0004_chat). DELETE는 캐릭터 삭제 때문에만 준다.
--      대화 하나를 지우거나 응답을 편집하는 API는 여전히 없다(계약 3절). 캐릭터 삭제는
--      그 캐릭터의 대화·질문·생성 기록과 대화 멱등 기록을 한 트랜잭션에서 지운다 —
--      캐릭터가 없어진 뒤에도 원문에서 나온 대화 본문이 DB에 남지 않게 하려는 것이다.
--      이 권한이 없으면 대화가 있는 캐릭터 삭제가 permission denied(500)로 실패한다.
--      TRUNCATE는 주지 않는다.
--      UPDATE가 필요한 이유는 표마다 다르다:
--        conversations — updated_at 갱신(마지막 활동 시각)
--        generations   — 상태 전이(queued→running→terminal)와 heartbeat·본문 누적
--      user_messages는 한 번 쓰면 바뀌지 않지만, 표 사이 권한을 들쭉날쭉하게 두면
--      다음 사람이 규칙을 못 읽는다. 여기서는 "대화 3표는 같은 조합"으로 맞추고
--      불변성은 코드와 CHECK 제약이 지킨다.
GRANT SELECT, INSERT, UPDATE, DELETE ON persona_minimal.conversations  TO persona_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON persona_minimal.user_messages  TO persona_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON persona_minimal.generations    TO persona_runtime;
--      멱등 키 기록은 한 번 쓰고 읽기만 한다 — 접수 시점에 result_id까지 한 번에 INSERT하고
--      그 뒤로는 같은 키 재전송에 같은 결과를 돌려주기 위해 읽기만 한다. UPDATE를 빼서
--      "이미 접수한 키의 결과를 나중에 바꾸는" 경로 자체를 막는다. DELETE는 캐릭터 삭제가
--      지운 대화·생성을 가리키던 기록을 함께 지우기 위해서만 준다.
GRANT SELECT, INSERT, DELETE ON persona_minimal.chat_idempotency_records TO persona_runtime;

-- 4. migration 상태는 읽기만. readiness가 required revision을 확인할 때 필요하다.
GRANT SELECT ON persona_minimal.alembic_version TO persona_runtime;
-- 앞선 운영이나 복원으로 쓰기 권한이 붙어 있을 수 있으므로 명시적으로 회수한다.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON persona_minimal.alembic_version FROM persona_runtime;

-- 5. 시퀀스 권한은 주지 않는다. 0001·0002에는 시퀀스가 없다.
--    id는 앱이 만든 uuid이고 시각은 now() 기본값이다. 시퀀스가 생기면 이 주석도 고친다.
