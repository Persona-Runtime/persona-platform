-- mafest 적재 뒤 기존 객체 GRANT 보정(문서 35 §역할 순서의 마지막 단계). 멱등이다.
--
-- 누가·어디서: stage·graph Job이 끝난 뒤 owner(mafest_owner)로 실행한다(runbooks/mafest-data, A7).
--   적재기(mafest.deploy.load)는 MAFEST_RUNTIME_ROLE이 있으면 같은 보정(mafest sql/grants/runtime_select.sql)을
--   이미 한다. 이 파일은 그 결과를 플랫폼 쪽에서 한 번 더 맞추고 확인하는 용도다 — 정본은 mafest 쪽 파일이다.
--   기본 권한(mafest_roles.sql)이 생기기 전에 만들어진 객체도 여기서 맞춘다.
--
-- 주는 것은 USAGE·SELECT뿐이다. 쓰기 권한은 주지 않는다.
\set ON_ERROR_STOP on

DO $grants$
DECLARE
    app_schema text;
BEGIN
    -- public: 정본 표·뷰. mafest_kg: 서빙 그래프(AGE). 그래프 적재 전이면 mafest_kg가 없을 수 있다.
    FOREACH app_schema IN ARRAY ARRAY['public', 'mafest_kg'] LOOP
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = app_schema) THEN
            EXECUTE format('GRANT USAGE ON SCHEMA %I TO mafest_runtime', app_schema);
            EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO mafest_runtime', app_schema);
        ELSE
            RAISE NOTICE 'schema % 없음 — 그래프 적재 전이면 정상이다', app_schema;
        END IF;
    END LOOP;
END
$grants$;
