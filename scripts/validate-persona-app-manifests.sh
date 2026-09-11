#!/bin/sh

set -eu

# Gateway·Web·DB·migration 선언이 합의한 계약을 지키는지 로컬에서만 검사한다.
# 홈 API를 호출하지 않는다. kubectl kustomize로 렌더한 결과만 본다.
#
# 검사는 두 부류다. 실패 메시지도 그에 맞춰 다르게 읽어야 한다.
# 어느 쪽이든 "검사 개수"는 완료 조건이 아니다. 무엇을 왜 지키는지가 기준이다.
#
#   [기준선] 지금 합의한 값을 그대로 유지하는지 본다. 자원 수치·replica·probe 값·PVC 크기처럼
#            실측이나 실험으로 **바꿀 수 있는** 것들이다. 바꿀 때는 근거를 남기고 이 검사도
#            함께 고친다. 실패 메시지는 "현재 기준선과 다르다"로 적는다.
#            영원히 바꾸면 안 되는 규칙이 아니다.
#
#   [안전]   두 가지를 함께 담는다. 태그는 하나지만 성격이 조금 다르다.
#
#            (1) 안전 — 어긴 채로 배포하면 되돌리기 어렵거나 비밀·데이터가 걸린다.
#                digest 고정, 외부 노출 금지, 자격증명 분리, 권한 경계, 수동 Sync 유지,
#                superuser 비활성, DB prune·삭제 차단.
#
#            (2) 연결 계약 — 다른 구성요소와 맞물려 있어 한쪽만 바꾸면 연결이 끊긴다.
#                컨테이너 포트 8080(이미지가 정한 값), probe 경로(/healthz와 /readyz의 구분이
#                "DB 장애로 재시작하지 않는다"의 핵심), gatewayClassName과 entryPoint 8000,
#                /v1·/ 라우팅 규칙, namespace 소유권.
#
#            둘 다 이 파일만 고쳐서 끝낼 일이 아니다. 상대편 선언이나 이미지·환경까지
#            함께 봐야 한다. 실패 메시지는 단정형으로 적는다.

# 검사 도구가 없으면 검사가 조용히 건너뛰어진다. 먼저 확인하고 멈춘다.
for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
db_file=$(mktemp "${TMPDIR:-/tmp}/persona-db.XXXXXX.yaml")
migrate_file=$(mktemp "${TMPDIR:-/tmp}/persona-migrate.XXXXXX.yaml")
app_file=$(mktemp "${TMPDIR:-/tmp}/persona-app.XXXXXX.yaml")
trap 'rm -f "$db_file" "$migrate_file" "$app_file"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-db"      > "$db_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-migrate" > "$migrate_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-app"     > "$app_file"

ruby -ryaml - \
  "$db_file" "$migrate_file" "$app_file" \
  "$repo_dir/argocd/persona-db.yaml" \
  "$repo_dir/argocd/persona-migrate.yaml" \
  "$repo_dir/argocd/persona-app.yaml" \
  "$repo_dir/bootstrap/namespaces/persona-data.yaml" \
  "$repo_dir/bootstrap/namespaces/persona-app.yaml" \
  "$repo_dir/db/grants/persona_minimal.sql" \
  "$repo_dir/bootstrap/traefik/values.yaml" <<'RUBY'
db_path, migrate_path, app_path,
  app_db, app_migrate, app_apps,
  ns_data_path, ns_app_path, grants_path, traefik_values_path = ARGV

GATEWAY_IMAGE = "ghcr.io/persona-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6"
WEB_IMAGE     = "ghcr.io/persona-runtime/persona-web@sha256:26e6f0ed439ee02374be3b726bb34ee1a8fccbbeace60219084d9acbd3caf968"
HOME_WORKERS  = ["k8s-worker1", "k8s-worker2"]

def load(path)
  YAML.load_stream(File.read(path)).compact
end

def resource(resources, kind, name)
  resources.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("missing #{kind}/#{name}")
end

def node_values(pod_spec)
  pod_spec.dig("affinity", "nodeAffinity",
               "requiredDuringSchedulingIgnoredDuringExecution",
               "nodeSelectorTerms", 0, "matchExpressions", 0, "values")
end

# 비루트·read-only·권한 최소화는 세 워크로드가 모두 같은 기준을 지켜야 한다.
def check_hardened_container(container, label, uid)
  security = container.fetch("securityContext")
  raise "[안전] #{label}: 비루트로 실행해야 한다" unless security["runAsNonRoot"] == true
  raise "[안전] #{label}: runAsUser가 #{uid}여야 한다" unless security["runAsUser"] == uid
  raise "[안전] #{label}: privilege escalation을 막아야 한다" unless security["allowPrivilegeEscalation"] == false
  raise "[안전] #{label}: 모든 capability를 제거해야 한다" unless security.dig("capabilities", "drop") == ["ALL"]
  raise "[안전] #{label}: root filesystem이 read-only여야 한다" unless security["readOnlyRootFilesystem"] == true

  mounts = container["volumeMounts"] || []
  raise "[안전] #{label}: read-only에서 쓰기용 /tmp 마운트가 필요하다" unless mounts.any? { |m| m["mountPath"] == "/tmp" }

  resources = container.fetch("resources")
  raise "[기준선] #{label}: requests를 선언한다" if (resources["requests"] || {}).empty?
  raise "[기준선] #{label}: limits를 선언한다" if (resources["limits"] || {}).empty?
end

def check_hardened_pod(pod_spec, label, pull_secret)
  raise "[안전] #{label}: ServiceAccount 토큰 자동 마운트를 꺼야 한다" unless pod_spec["automountServiceAccountToken"] == false
  raise "[안전] #{label}: RuntimeDefault seccomp이 필요하다" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
  raise "[안전] #{label}: GHCR pull Secret이 필요하다" unless pod_spec["imagePullSecrets"] == [{ "name" => pull_secret }]
  raise "[안전] #{label}: 홈 워커에만 배치해야 한다" unless node_values(pod_spec) == HOME_WORKERS
  raise "[안전] #{label}: /tmp emptyDir이 필요하다" unless (pod_spec["volumes"] || []).any? { |v| v["name"] == "tmp" && v.key?("emptyDir") }
end

# --- DB -------------------------------------------------------------------
db = load(db_path)
raise "[안전] DB overlay가 Namespace를 관리하면 안 된다" if db.any? { |i| i["kind"] == "Namespace" }

cluster = resource(db, "Cluster", "persona-db")
raise "[안전] DB는 persona-data namespace여야 한다" unless cluster.dig("metadata", "namespace") == "persona-data"
sync_options = cluster.dig("metadata", "annotations", "argocd.argoproj.io/sync-options").to_s
raise "[안전] DB는 prune 대상이 되면 안 된다" unless sync_options.include?("Prune=false")
raise "[안전] DB는 Argo 삭제 대상이 되면 안 된다" unless sync_options.include?("Delete=false")

cspec = cluster.fetch("spec")
raise "[기준선] Postgres 인스턴스 수가 기준선(1)과 다르다" unless cspec["instances"] == 1
raise "[안전] superuser 접근을 켜면 안 된다" unless cspec["enableSuperuserAccess"] == false
raise "[안전] Postgres 이미지는 16 계열 digest로 고정해야 한다" unless cspec["imageName"].to_s.start_with?("ghcr.io/cloudnative-pg/postgresql:16.") &&
  cspec["imageName"].to_s.include?("@sha256:")
raise "[기준선] PVC 크기가 기준선(20Gi)과 다르다 — local-path는 나중에 확장할 수 없으니 근거를 남기고 바꾼다" unless cspec.dig("storage", "size") == "20Gi"
raise "[안전] StorageClass는 local-path다" unless cspec.dig("storage", "storageClass") == "local-path"
raise "[안전] DB는 worker1에 고정한다" unless cspec.dig("affinity", "nodeSelector", "kubernetes.io/hostname") == "k8s-worker1"
raise "[기준선] DB 자원 requests/limits를 선언한다" if (cspec.dig("resources", "requests") || {}).empty? || (cspec.dig("resources", "limits") || {}).empty?
# CPU limit을 일부러 두지 않는다. DB에 CPU 상한을 걸면 throttling이 질의 지연으로 나타난다.
# 그래서 이 파드는 Guaranteed가 아니라 Burstable이다. "등급을 맞추자"며 limit을 붙이면 여기서 잡는다.
raise "[기준선] DB에 CPU limit이 생겼다 — 현재 기준선은 CPU 상한 없음(Burstable)이다. throttling이 질의 지연으로 나타나는 것을 피하려는 선택이며, 실측 근거가 있으면 바꿀 수 있다" if cspec.dig("resources", "limits", "cpu")
raise "[기준선] DB 메모리 requests와 limits가 다르다 — 현재 기준선은 같은 값(OOM·축출 경계를 예측 가능하게)이다" unless cspec.dig("resources", "requests", "memory") == cspec.dig("resources", "limits", "memory")

initdb = cspec.dig("bootstrap", "initdb") || raise("bootstrap.initdb가 필요하다")
raise "[안전] DB 이름은 persona_app이다" unless initdb["database"] == "persona_app"
raise "[안전] DB 소유자는 persona_migrator다" unless initdb["owner"] == "persona_migrator"
raise "[안전] initdb Secret 이름 계약이 다르다" unless initdb.dig("secret", "name") == "persona-db-migrator"

# --- migration Job --------------------------------------------------------
migrate = load(migrate_path)
raise "[안전] migration overlay가 Namespace를 관리하면 안 된다" if migrate.any? { |i| i["kind"] == "Namespace" }

job = resource(migrate, "Job", "persona-migrate-0001-persona-minimal")
raise "[안전] migration Job은 persona-app namespace다" unless job.dig("metadata", "namespace") == "persona-app"
jspec = job.fetch("spec")
raise "[기준선] migration Job backoffLimit이 0이 아니다 — 실패를 재시도로 덮지 않는 것이 현재 기준선이다" unless jspec["backoffLimit"] == 0
raise "[기준선] migration Job에 유한한 실행 제한이 없다" unless jspec["activeDeadlineSeconds"].is_a?(Integer) && jspec["activeDeadlineSeconds"] > 0
raise "[안전] 완료된 Job과 로그를 자동 삭제하면 안 된다" if jspec.key?("ttlSecondsAfterFinished")

jpod = jspec.dig("template", "spec")
raise "[안전] migration Job은 재시작하지 않는다" unless jpod["restartPolicy"] == "Never"
check_hardened_pod(jpod, "migration Job", "persona-app-ghcr")

jcontainer = jpod.fetch("containers").fetch(0)
raise "[안전] migration은 Gateway와 같은 이미지여야 한다" unless jcontainer["image"] == GATEWAY_IMAGE
raise "[안전] migration command가 alembic이 아니다" unless jcontainer["command"] == ["/app/.venv/bin/alembic"]
raise "[안전] migration args가 upgrade head가 아니다" unless jcontainer["args"] == ["upgrade", "head"]
check_hardened_container(jcontainer, "migration Job", 10_001)

job_secrets = (jcontainer["env"] || []).map { |e| e.dig("valueFrom", "secretKeyRef", "name") }.compact
job_secrets += (jcontainer["envFrom"] || []).map { |e| e.dig("secretRef", "name") }.compact
raise "[안전] migration Job은 migrator Secret만 참조해야 한다" unless job_secrets.uniq == ["persona-gateway-migrator"]
raise "[안전] migration Job에 probe를 붙이지 않는다" if jcontainer.key?("readinessProbe") || jcontainer.key?("livenessProbe")

# --- Gateway / Web --------------------------------------------------------
app = load(app_path)
raise "[안전] 앱 overlay가 Namespace를 관리하면 안 된다" if app.any? { |i| i["kind"] == "Namespace" }
raise "[안전] 앱 overlay에 migration Job을 넣지 않는다" if app.any? { |i| i["kind"] == "Job" }

gateway = resource(app, "Deployment", "persona-gateway")
gspec = gateway.fetch("spec")
raise "[기준선] Gateway replica가 기준선(1)과 다르다" unless gspec["replicas"] == 1
raise "[기준선] Gateway는 RollingUpdate로 교체한다" unless gspec.dig("strategy", "type") == "RollingUpdate"
raise "[기준선] Gateway maxSurge는 1이다" unless gspec.dig("strategy", "rollingUpdate", "maxSurge") == 1
raise "[기준선] Gateway maxUnavailable은 0이다" unless gspec.dig("strategy", "rollingUpdate", "maxUnavailable") == 0
gpod = gspec.dig("template", "spec")
check_hardened_pod(gpod, "Gateway", "persona-app-ghcr")
raise "[기준선] Gateway 종료 유예가 기준선(30초)과 다르다 — Uvicorn graceful 25초보다 길어야 한다" unless gpod["terminationGracePeriodSeconds"] == 30

gcontainer = gpod.fetch("containers").fetch(0)
raise "[안전] Gateway 이미지가 검증된 amd64 child digest가 아니다" unless gcontainer["image"] == GATEWAY_IMAGE
raise "[안전] Gateway 포트는 8080이다" unless gcontainer.dig("ports", 0, "containerPort") == 8080
check_hardened_container(gcontainer, "Gateway", 10_001)

gateway_secrets = (gcontainer["envFrom"] || []).map { |e| e.dig("secretRef", "name") }.compact
gateway_secrets += (gcontainer["env"] || []).map { |e| e.dig("valueFrom", "secretKeyRef", "name") }.compact
raise "[안전] Gateway는 runtime Secret만 참조해야 한다" unless gateway_secrets.uniq == ["persona-gateway-runtime"]
raise "[안전] Gateway에 migrator 자격증명을 주면 안 된다" if gateway_secrets.include?("persona-gateway-migrator")
raise "[안전] DB timeout 예산을 명시해야 한다" unless (gcontainer["env"] || []).any? { |e| e["name"] == "PERSONA_DB_TIMEOUT_SECONDS" && e["value"] == "2" }

# DB 장애로 재시작되면 안 되므로 startup·liveness는 /healthz여야 한다.
raise "[안전] Gateway startup probe는 /healthz다" unless gcontainer.dig("startupProbe", "httpGet", "path") == "/healthz"
raise "[안전] Gateway liveness probe는 /healthz다" unless gcontainer.dig("livenessProbe", "httpGet", "path") == "/healthz"
raise "[기준선] Gateway liveness timeout이 기준선(1초)과 다르다" unless gcontainer.dig("livenessProbe", "timeoutSeconds") == 1
raise "[기준선] Gateway liveness period가 기준선(10초)과 다르다" unless gcontainer.dig("livenessProbe", "periodSeconds") == 10
raise "[기준선] Gateway liveness failureThreshold가 기준선(3)과 다르다" unless gcontainer.dig("livenessProbe", "failureThreshold") == 3
raise "[안전] Gateway readiness probe는 /readyz다" unless gcontainer.dig("readinessProbe", "httpGet", "path") == "/readyz"
raise "[기준선] Gateway readiness timeout이 기준선(3초)과 다르다" unless gcontainer.dig("readinessProbe", "timeoutSeconds") == 3
raise "[기준선] Gateway readiness period가 기준선(5초)과 다르다" unless gcontainer.dig("readinessProbe", "periodSeconds") == 5
raise "[기준선] Gateway readiness failureThreshold가 기준선(1)과 다르다" unless gcontainer.dig("readinessProbe", "failureThreshold") == 1

web = resource(app, "Deployment", "persona-web")
wspec = web.fetch("spec")
raise "[기준선] Web replica가 기준선(2)과 다르다" unless wspec["replicas"] == 2
wpod = wspec.dig("template", "spec")
check_hardened_pod(wpod, "Web", "persona-app-ghcr")
anti = wpod.dig("affinity", "podAntiAffinity", "preferredDuringSchedulingIgnoredDuringExecution")
raise "[기준선] Web은 노드 분산을 선호해야 한다" unless anti.is_a?(Array) && anti.length == 1
raise "[기준선] Web anti-affinity는 hostname 기준이다" unless anti.dig(0, "podAffinityTerm", "topologyKey") == "kubernetes.io/hostname"
raise "[안전] 워커가 2대뿐이므로 anti-affinity를 강제하면 안 된다" if wpod.dig("affinity", "podAntiAffinity", "requiredDuringSchedulingIgnoredDuringExecution")

wcontainer = wpod.fetch("containers").fetch(0)
raise "[안전] Web 이미지가 검증된 amd64 child digest가 아니다" unless wcontainer["image"] == WEB_IMAGE
raise "[안전] Web 포트는 8080이다" unless wcontainer.dig("ports", 0, "containerPort") == 8080
check_hardened_container(wcontainer, "Web", 101)
raise "[안전] Web에는 Secret을 주입하지 않는다" unless (wcontainer["envFrom"] || []).empty?
["startupProbe", "livenessProbe", "readinessProbe"].each do |probe|
  raise "[안전] Web #{probe}는 /healthz다" unless wcontainer.dig(probe, "httpGet", "path") == "/healthz"
end

# --- Service / 외부 노출 --------------------------------------------------
["persona-gateway", "persona-web"].each do |name|
  service = resource(app, "Service", name)
  raise "[안전] #{name} Service는 ClusterIP다" unless service.dig("spec", "type") == "ClusterIP"
  raise "[안전] #{name} Service 포트는 8080이다" unless service.dig("spec", "ports", 0, "port") == 8080
end
(db + migrate + app).each do |item|
  next unless item["kind"] == "Service"
  type = item.dig("spec", "type")
  raise "[안전] 공개 노출 타입을 추가하면 안 된다: #{type}" if ["NodePort", "LoadBalancer"].include?(type)
  raise "[안전] nodePort를 지정하면 안 된다" if (item.dig("spec", "ports") || []).any? { |p| p.key?("nodePort") }
end

# --- Traefik 라우팅 -------------------------------------------------------
gw = resource(app, "Gateway", "persona-app")
raise "[안전] Gateway는 Traefik이 처리한다" unless gw.dig("spec", "gatewayClassName") == "traefik"
listener = gw.dig("spec", "listeners", 0)
raise "[안전] listener는 Traefik HTTP entryPoint 8000이다" unless listener["name"] == "http" && listener["protocol"] == "HTTP" && listener["port"] == 8000
raise "[안전] 확정되지 않은 접속 주소를 넣지 않는다" if listener.key?("hostname")

route = resource(app, "HTTPRoute", "persona-app")
rules = route.dig("spec", "rules")
raise "[안전] 규칙은 /v1과 / 두 개다" unless rules.length == 2

api_rule = rules.find { |r| r.dig("matches", 0, "path", "value") == "/v1" } || raise("/v1 규칙이 없다")
raise "[안전] /v1은 PathPrefix다" unless api_rule.dig("matches", 0, "path", "type") == "PathPrefix"
raise "[안전] /v1은 Gateway로 간다" unless api_rule.dig("backendRefs", 0, "name") == "persona-gateway" && api_rule.dig("backendRefs", 0, "port") == 8080

web_rule = rules.find { |r| r.dig("matches", 0, "path", "value") == "/" } || raise("/ 규칙이 없다")
raise "[안전] /는 PathPrefix다" unless web_rule.dig("matches", 0, "path", "type") == "PathPrefix"
raise "[안전] /는 Web으로 간다" unless web_rule.dig("backendRefs", 0, "name") == "persona-web" && web_rule.dig("backendRefs", 0, "port") == 8080

# Python API가 실제로 /v1/... 을 받는다. 접두사를 떼면 404가 된다.
rules.each do |rule|
  (rule["filters"] || []).each do |filter|
    raise "[안전] 경로를 다시 쓰면 안 된다 — Python API가 /v1/...을 그대로 받는다: #{filter["type"]}" if filter["type"] == "URLRewrite"
  end
end

# --- Argo Application -----------------------------------------------------
{
  app_db      => ["persona-db", "kustomize/overlays/prod/persona-db", "persona-data"],
  app_migrate => ["persona-migrate", "kustomize/overlays/prod/persona-migrate", "persona-app"],
  app_apps    => ["persona-app", "kustomize/overlays/prod/persona-app", "persona-app"],
}.each do |path, (name, source_path, namespace)|
  application = YAML.load_file(path)
  raise "[안전] #{name}: Application kind가 아니다" unless application["kind"] == "Application"
  raise "[안전] #{name}: 이름이 다르다" unless application.dig("metadata", "name") == name
  spec = application.fetch("spec")
  raise "[안전] #{name}: develop 브랜치를 봐야 한다" unless spec.dig("source", "targetRevision") == "develop"
  raise "[안전] #{name}: source path가 다르다" unless spec.dig("source", "path") == source_path
  raise "[안전] #{name}: 대상 namespace가 다르다" unless spec.dig("destination", "namespace") == namespace
  # 순서는 사람이 단계별로 Sync해서 만든다. 자동 Sync를 켜면 그 순서가 사라진다.
  raise "[안전] #{name}: 자동 Sync를 켜면 안 된다" if spec.key?("syncPolicy")
end

# --- PriorityClass --------------------------------------------------------
# 기본 구성에서 병목을 관찰한 뒤 우선순위 실험을 추가한다. 시스템 클래스나 기존 클러스터는
# 변경하지 않으며, 여기서는 이번 서비스 선언과 Traefik values에 참조가 다시 들어오는지만 막는다.
traefik_values = YAML.load_file(traefik_values_path)
{ "DB" => cspec, "migration Job" => jpod, "Gateway" => gpod,
  "Web" => wpod, "Traefik" => traefik_values }.each do |label, spec|
  raise "[기준선] #{label}: 커스텀 PriorityClass 적용은 보류한다" unless spec["priorityClassName"].to_s.empty?
end

# --- bootstrap namespace --------------------------------------------------
{ ns_data_path => "persona-data", ns_app_path => "persona-app" }.each do |path, name|
  namespace = YAML.load_file(path)
  raise "[안전] #{name}: Namespace kind가 아니다" unless namespace["kind"] == "Namespace"
  raise "[안전] #{name}: 이름이 다르다" unless namespace.dig("metadata", "name") == name
end

# --- grant 계약 -----------------------------------------------------------
# runtime이 migration 상태를 바꿀 수 있게 되는 경로를 문법 수준에서 막는다.
# 주석에는 "이렇게 쓰지 않는다"는 설명이 들어 있다. 실제 문장만 검사한다.
grants = File.read(grants_path).lines.map { |line| line.sub(/--.*$/, "") }.join
raise "[안전] grant에 ALL TABLES IN SCHEMA를 쓰면 alembic_version에도 권한이 붙는다" if grants =~ /ALL TABLES IN SCHEMA/i
raise "[안전] 기본 권한으로 UPDATE를 주면 alembic_version에도 붙는다" if grants =~ /ALTER DEFAULT PRIVILEGES/i
raise "[안전] alembic_version은 SELECT만 줘야 한다" unless grants =~ /GRANT SELECT ON persona_minimal\.alembic_version/i
raise "[안전] alembic_version 쓰기 권한을 명시적으로 회수해야 한다" unless grants =~ /REVOKE[^;]*ON persona_minimal\.alembic_version/im
raise "[안전] platform이 테이블 정의를 복제하면 안 된다" if grants =~ /CREATE TABLE/i

puts "persona-app 렌더와 매니페스트 정책 검사 통과"
RUBY
