-- runtime(mafest_runtime) 권한 경계 확인. runtime DSN으로 실행한다(문서 35 M5b "runtime 읽기 OK / 쓰기 거부").
--
--   psql "<runtime 접속>" -v ON_ERROR_STOP=1 -f db/grants/mafest_runtime_check.sql
--
-- 출력은 "ok <검사>" / "FAIL <검사>" NOTICE와 마지막 요약뿐이다. 행 값·DSN은 출력하지 않는다.
-- 혹시 쓰기가 허용되더라도 아무것도 남지 않게 전체를 트랜잭션으로 감싸고 ROLLBACK한다.
-- FAIL이 하나라도 있으면 마지막에 예외를 내서 psql이 0이 아닌 코드로 끝난다.
\set ON_ERROR_STOP on
BEGIN;

DO $check$
DECLARE
    failures int := 0;
    sample_table text;
    readable int;
BEGIN
    -- 1) 읽기: public 표가 있고 모두 SELECT 가능해야 한다.
    SELECT count(*) INTO readable FROM pg_tables WHERE schemaname = 'public';
    IF readable = 0 THEN
        RAISE NOTICE 'FAIL read: public 표가 없다(적재 전?)'; failures := failures + 1;
    ELSIF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public'
                  AND NOT has_table_privilege(format('%I.%I', schemaname, tablename), 'SELECT')) THEN
        RAISE NOTICE 'FAIL read: SELECT 권한이 없는 public 표가 있다'; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok read: public 표 % 개 SELECT 가능', readable;
    END IF;

    -- 2) 그래프 읽기: mafest_kg 스키마 USAGE.
    IF has_schema_privilege('mafest_kg', 'USAGE') THEN
        RAISE NOTICE 'ok graph-read: mafest_kg USAGE';
    ELSE
        RAISE NOTICE 'FAIL graph-read: mafest_kg USAGE 없음'; failures := failures + 1;
    END IF;

    -- 3) 쓰기 거부: 표 INSERT(아무 public 표 하나, 값 없이 기본값 행).
    SELECT format('%I.%I', schemaname, tablename) INTO sample_table
      FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename LIMIT 1;
    IF sample_table IS NOT NULL THEN
        BEGIN
            EXECUTE format('INSERT INTO %s DEFAULT VALUES', sample_table);
            RAISE NOTICE 'FAIL write-insert: INSERT가 허용됐다'; failures := failures + 1;
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'ok write-insert: 거부';
        WHEN OTHERS THEN
            -- 권한 검사를 통과한 뒤 다른 이유(제약 등)로 실패한 것이다 — 권한이 있다는 뜻이라 실패로 센다.
            RAISE NOTICE 'FAIL write-insert: 권한 오류가 아닌 % 로 실패(권한은 있음)', SQLSTATE; failures := failures + 1;
        END;
    END IF;

    -- 4) 쓰기 거부: 표 생성.
    BEGIN
        EXECUTE 'CREATE TABLE public.mafest_runtime_check_probe (x int)';
        RAISE NOTICE 'FAIL write-create: CREATE TABLE이 허용됐다'; failures := failures + 1;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'ok write-create: 거부';
    END;

    -- 5) 쓰기 거부: 그래프 변경(Cypher CREATE, 새 그래프 생성).
    BEGIN
        EXECUTE $q$SELECT * FROM ag_catalog.cypher('mafest_kg', $$ CREATE (:RuntimeCheck {x: 1}) $$) AS (a ag_catalog.agtype)$q$;
        RAISE NOTICE 'FAIL write-cypher: Cypher CREATE가 허용됐다'; failures := failures + 1;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'ok write-cypher: 거부';
    END;
    BEGIN
        EXECUTE $q$SELECT ag_catalog.create_graph('mafest_runtime_check_probe')$q$;
        RAISE NOTICE 'FAIL write-graph: create_graph가 허용됐다'; failures := failures + 1;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'ok write-graph: 거부';
    END;

    IF failures > 0 THEN
        RAISE EXCEPTION 'runtime 권한 검사 실패 %건', failures;
    END IF;
    RAISE NOTICE 'runtime 권한 검사 통과';
END
$check$;

ROLLBACK;
