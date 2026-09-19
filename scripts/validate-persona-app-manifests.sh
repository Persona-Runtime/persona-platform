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
ingress_file=$(mktemp "${TMPDIR:-/tmp}/persona-app-ingress.XXXXXX.yaml")
trap 'rm -f "$db_file" "$migrate_file" "$app_file" "$ingress_file"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-db"            > "$db_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-migrate"       > "$migrate_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-app"           > "$app_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-app-ingress"   > "$ingress_file"

# persona-embedding은 이미지 push 전이라 overlay에서 빠져 있다(위 app_file 렌더에는
# 안 나온다) — base 자체가 여전히 유효하게 렌더되는지는 이 단독 빌드로만 확인한다.
kubectl kustomize "$repo_dir/kustomize/base/persona-embedding" > /dev/null

ruby -ryaml - \
  "$db_file" "$migrate_file" "$app_file" "$ingress_file" \
  "$repo_dir/argocd/persona-db.yaml" \
  "$repo_dir/argocd/persona-app.yaml" \
  "$repo_dir/argocd/persona-app-ingress.yaml" \
  "$repo_dir/argocd/persona-app-netpol.yaml" \
  "$repo_dir/argocd/persona-db-netpol.yaml" \
  "$repo_dir/bootstrap/namespaces/persona-data.yaml" \
  "$repo_dir/bootstrap/namespaces/persona-app.yaml" \
  "$repo_dir/db/grants/persona_minimal.sql" \
  "$repo_dir/bootstrap/traefik/values.yaml" \
  "$repo_dir/kustomize/base/persona-migrate/kustomization.yaml" <<'RUBY'
# encoding: utf-8
#
# 로케일이 UTF-8이 아닌 환경(cron, 다른 셸 설정 등)에서 실행하면 Ruby가 이 heredoc 소스를
# 기본 US-ASCII로 읽어 한글 주석에서 "invalid multibyte char"로 즉시 실패한다. 매직 코멘트는
# 이 스크립트 자체의 소스 인코딩만 고정할 뿐, File.read가 여는 grants_path 같은 외부 파일의
# 기본 인코딩(Encoding.default_external)에는 영향을 주지 않으므로 별도로 UTF-8로 고정한다.
Encoding.default_external = Encoding::UTF_8

db_path, migrate_path, app_path, ingress_path,
  app_db, app_apps, app_ingress, app_app_netpol, app_db_netpol,
  ns_data_path, ns_app_path, grants_path, traefik_values_path,
  migrate_base_path = ARGV

GATEWAY_IMAGE = "ghcr.io/persona-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6"

# migration Job의 승인 이미지는 revision별로 따로 적는다.
#
# Gateway digest와 항상 같아야 한다는 조건은 틀렸다. 이미 만들어진 Job의 pod 템플릿은
# 바꿀 수 없어서 과거 Job은 과거 digest를 그대로 유지해야 하는데, Gateway 하나에 묶으면
# 다음 이미지를 올리는 순간 보존 중인 과거 Job이 검증에서 걸려 배포가 막힌다.
#
# 기준은 각 이미지가 담고 있는 DB revision이다. Gateway 이미지는 자신이 허용하는
# revision을, migration Job 이미지는 그 Job이 적용하려는 revision을 담는다.
# 새 revision Job을 연결할 때 여기에 항목을 추가한다. 맵에 없으면 검증이 거부한다.
MIGRATION_IMAGES = {
  "0001-persona-minimal" => "ghcr.io/persona-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6",
}
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
raise "[기준선] Postgres 인스턴스 수가 기준선(2)과 다르다" unless cspec["instances"] == 2
raise "[안전] superuser 접근을 켜면 안 된다" unless cspec["enableSuperuserAccess"] == false
raise "[안전] Postgres 이미지는 16 계열 digest로 고정해야 한다" unless cspec["imageName"].to_s.start_with?("ghcr.io/cloudnative-pg/postgresql:16.") &&
  cspec["imageName"].to_s.include?("@sha256:")
raise "[기준선] PVC 크기가 기준선(20Gi)과 다르다 — local-path는 나중에 확장할 수 없으니 근거를 남기고 바꾼다" unless cspec.dig("storage", "size") == "20Gi"
raise "[안전] StorageClass는 local-path다" unless cspec.dig("storage", "storageClass") == "local-path"
raise "[안전] DB affinity에 옛 worker1 전용 nodeSelector가 남아 있다 — Gate 4 이후로는 nodeAffinity로만 배치를 제한한다" if cspec.dig("affinity", "nodeSelector")
raise "[안전] 필수 anti-affinity를 켜야 한다" unless cspec.dig("affinity", "enablePodAntiAffinity") == true
raise "[안전] anti-affinity가 preferred로 약화됐다 — required가 아니면 두 인스턴스가 같은 노드에 몰릴 수 있다" unless cspec.dig("affinity", "podAntiAffinityType") == "required"
raise "[안전] anti-affinity topologyKey가 다르다" unless cspec.dig("affinity", "topologyKey") == "kubernetes.io/hostname"
# nodeSelectorTerms 중 일부 필드만 비교하면(예: values만) matchExpressions를 추가하거나
# operator를 바꿔도 통과한다. 전체 구조를 통째로 비교해 CP/GPU 노드 추가나 worker1 단독
# 축소를 한 번에 차단한다.
raise "[안전] DB는 두 홈 워커(k8s-worker1, k8s-worker2)만 노드 후보여야 한다 — CP/GPU 노드 추가나 worker1 단독 축소를 허용하면 안 된다" unless cspec.dig("affinity", "nodeAffinity") == {
  "requiredDuringSchedulingIgnoredDuringExecution" => {
    "nodeSelectorTerms" => [
      { "matchExpressions" => [
        { "key" => "kubernetes.io/hostname", "operator" => "In", "values" => ["k8s-worker1", "k8s-worker2"] }
      ] }
    ]
  }
}
raise "[기준선] DB 자원 requests/limits를 선언한다" if (cspec.dig("resources", "requests") || {}).empty? || (cspec.dig("resources", "limits") || {}).empty?
# CPU limit을 일부러 두지 않는다. DB에 CPU 상한을 걸면 throttling이 질의 지연으로 나타난다.
# 그래서 이 파드는 Guaranteed가 아니라 Burstable이다. "등급을 맞추자"며 limit을 붙이면 여기서 잡는다.
raise "[기준선] DB에 CPU limit이 생겼다 — 현재 기준선은 CPU 상한 없음(Burstable)이다. throttling이 질의 지연으로 나타나는 것을 피하려는 선택이며, 실측 근거가 있으면 바꿀 수 있다" if cspec.dig("resources", "limits", "cpu")
raise "[기준선] DB 메모리 requests와 limits가 다르다 — 현재 기준선은 같은 값(OOM·축출 경계를 예측 가능하게)이다" unless cspec.dig("resources", "requests", "memory") == cspec.dig("resources", "limits", "memory")

initdb = cspec.dig("bootstrap", "initdb") || raise("bootstrap.initdb가 필요하다")
raise "[안전] DB 이름은 persona_app이다" unless initdb["database"] == "persona_app"
raise "[안전] DB 소유자는 persona_migrator다" unless initdb["owner"] == "persona_migrator"
raise "[안전] initdb Secret 이름 계약이 다르다" unless initdb.dig("secret", "name") == "persona-db-migrator"

# CNPG의 enablePodMonitor(deprecated)로 자동 생성되는 PodMonitor와 이 파일이 검사하는
# 독립 선언이 겹치면 어느 쪽이 유효한지 불명확해진다. Cluster가 그 필드를 켜지 않았는지와
# PodMonitor가 정확히 하나인지를 함께 봐야 중복을 놓치지 않는다.
raise "[안전] CNPG 자동 PodMonitor 생성을 켜면 안 된다 — 독립 PodMonitor 선언과 중복된다" if cspec.dig("monitoring", "enablePodMonitor")
pod_monitors = db.select { |item| item["kind"] == "PodMonitor" }
raise "[안전] persona-db PodMonitor가 정확히 1개여야 한다: #{pod_monitors.length}개" unless pod_monitors.length == 1
pod_monitor = pod_monitors.fetch(0)
raise "[안전] PodMonitor는 persona-data namespace여야 한다" unless pod_monitor.dig("metadata", "namespace") == "persona-data"
raise "[안전] PodMonitor에 release=monitoring-stack 라벨이 있어야 Prometheus가 대상으로 인식한다" unless pod_monitor.dig("metadata", "labels", "release") == "monitoring-stack"
raise "[안전] PodMonitor namespaceSelector가 persona-data만 가리켜야 한다" unless pod_monitor.dig("spec", "namespaceSelector", "matchNames") == ["persona-data"]
# matchLabels만 비교하면 matchExpressions를 몰래 추가해 role을 좁혀도(예: cnpg.io/instanceRole
# In [primary]) 통과한다. selector 전체를 비교해 그런 추가 조건 자체를 거부한다.
raise "[안전] PodMonitor selector는 cnpg.io/cluster=persona-db만 써야 한다 — matchExpressions로 role을 제한하면 안 된다(향후 replica가 수집에서 빠진다)" unless pod_monitor.dig("spec", "selector") == { "matchLabels" => { "cnpg.io/cluster" => "persona-db" } }
endpoints = pod_monitor.dig("spec", "podMetricsEndpoints") || raise("[안전] PodMonitor에 podMetricsEndpoints가 없다")
raise "[안전] PodMonitor podMetricsEndpoints가 정확히 1개여야 한다: #{endpoints.length}개 — 의도하지 않은 추가 수집 대상을 막는다" unless endpoints.length == 1
endpoint = endpoints.fetch(0)
raise "[안전] PodMonitor 포트는 숫자가 아니라 이름(metrics)이어야 한다" unless endpoint["port"] == "metrics"
raise "[안전] PodMonitor 경로는 /metrics여야 한다" unless endpoint["path"] == "/metrics"
raise "[안전] PodMonitor scheme은 http여야 한다 — 홈 클러스터 내부 통신은 TLS를 전제하지 않는다" unless endpoint["scheme"] == "http"
raise "[기준선] PodMonitor scrape interval이 기준선(30s)과 다르다" unless endpoint["interval"] == "30s"
raise "[기준선] PodMonitor scrapeTimeout이 기준선(10s)과 다르다" unless endpoint["scrapeTimeout"] == "10s"

# --- migration Job --------------------------------------------------------
migrate = load(migrate_path)
raise "[안전] migration overlay가 Namespace를 관리하면 안 된다" if migrate.any? { |i| i["kind"] == "Namespace" }

# Job을 이름으로 하나만 찾으면, 새 revision Job을 추가했을 때 그 Job은 아무 검사도
# 받지 않는다. 이미지 digest·hardening·Secret 경계가 전부 비게 되므로 전부 순회한다.
jobs = migrate.select { |item| item["kind"] == "Job" }

# 활성 렌더에는 **이번에 적용할 Job 하나만** 둔다.
#
# 여럿을 함께 Sync하면 적용 순서가 보장되지 않고, 이미 클러스터에서 지운 과거 Job이
# 구형 이미지로 다시 만들어진다. 구형 이미지가 upgrade head를 돌면 새 revision을 몰라
# 실패한다. "완료된 Job은 다시 Sync해도 재실행되지 않는다"는 그 Job이 클러스터에 남아
# 있을 때만 참이고, 0001 Job은 이미 삭제했다(runbooks/test-resource-cleanup.md).
#
# 0개는 오류가 아니다 — 적용할 migration이 없는 평시 상태다. 과거 선언은
# kustomize/base/persona-migrate/history/에 이력으로 남기고 렌더하지 않는다.
raise "[안전] 활성 렌더에 migration Job이 둘 이상이다 — 이번 배포 대상만 남기고 나머지는 history/로 옮겨라: #{jobs.map { |j| j.dig("metadata", "name") }.join(", ")}" if jobs.length > 1

# 이력 파일을 다시 연결하면 Job 수가 1이라 위 검사를 통과해 버린다. 경로로 한 번 더 막는다.
migrate_base = YAML.load_file(migrate_base_path)
(migrate_base["resources"] || []).each do |entry|
  raise "[안전] history/의 과거 선언을 활성 렌더에 연결했다: #{entry}" if entry.to_s.include?("history/")
end

# 뒤의 PriorityClass 검사도 Job 전부를 봐야 하므로 pod spec을 모아 둔다.
job_pods = {}

jobs.each do |job|
  jname = job.dig("metadata", "name").to_s
  raise "[안전] migration Job 이름에 revision이 없다: #{jname}" unless jname.match?(/\Apersona-migrate-\d{4}-[a-z0-9-]+\z/)
  raise "[안전] migration Job은 persona-app namespace다: #{jname}" unless job.dig("metadata", "namespace") == "persona-app"
  jspec = job.fetch("spec")
  raise "[기준선] migration Job backoffLimit이 0이 아니다 — 실패를 재시도로 덮지 않는 것이 현재 기준선이다: #{jname}" unless jspec["backoffLimit"] == 0
  raise "[기준선] migration Job에 유한한 실행 제한이 없다: #{jname}" unless jspec["activeDeadlineSeconds"].is_a?(Integer) && jspec["activeDeadlineSeconds"] > 0
  raise "[안전] 완료된 Job과 로그를 자동 삭제하면 안 된다: #{jname}" if jspec.key?("ttlSecondsAfterFinished")

  jpod = jspec.dig("template", "spec")
  raise "[안전] migration Job은 재시작하지 않는다: #{jname}" unless jpod["restartPolicy"] == "Never"
  check_hardened_pod(jpod, "migration Job #{jname}", "persona-app-ghcr")

  jcontainer = jpod.fetch("containers").fetch(0)
  revision = jname.sub(/\Apersona-migrate-/, "")
  approved = MIGRATION_IMAGES[revision]
  raise "[안전] 승인 이미지가 등록되지 않은 migration Job이다 — MIGRATION_IMAGES에 추가하라: #{jname}" if approved.nil?
  raise "[안전] migration Job 이미지가 그 revision의 승인 이미지가 아니다: #{jname}" unless jcontainer["image"] == approved
  raise "[안전] migration command가 alembic이 아니다: #{jname}" unless jcontainer["command"] == ["/app/.venv/bin/alembic"]
  raise "[안전] migration args가 upgrade head가 아니다: #{jname}" unless jcontainer["args"] == ["upgrade", "head"]
  check_hardened_container(jcontainer, "migration Job #{jname}", 10_001)

  job_secrets = (jcontainer["env"] || []).map { |e| e.dig("valueFrom", "secretKeyRef", "name") }.compact
  job_secrets += (jcontainer["envFrom"] || []).map { |e| e.dig("secretRef", "name") }.compact
  raise "[안전] migration Job은 migrator Secret만 참조해야 한다: #{jname}" unless job_secrets.uniq == ["persona-gateway-migrator"]
  raise "[안전] migration Job에 probe를 붙이지 않는다: #{jname}" if jcontainer.key?("readinessProbe") || jcontainer.key?("livenessProbe")

  job_pods["migration Job #{jname}"] = jpod
end

# --- Gateway / Web --------------------------------------------------------
app = load(app_path)
raise "[안전] 앱 overlay가 Namespace를 관리하면 안 된다" if app.any? { |i| i["kind"] == "Namespace" }
raise "[안전] 앱 overlay에 migration Job을 넣지 않는다" if app.any? { |i| i["kind"] == "Job" }

# persona-app-ingress(인터넷 진입 전용, Sync 분리 2026-09-19) — 별도 렌더.
ingress = load(ingress_path)
raise "[안전] ingress overlay가 Namespace를 관리하면 안 된다" if ingress.any? { |i| i["kind"] == "Namespace" }

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
(db + migrate + app + ingress).each do |item|
  next unless item["kind"] == "Service"
  type = item.dig("spec", "type")
  raise "[안전] 공개 노출 타입을 추가하면 안 된다: #{type}" if ["NodePort", "LoadBalancer"].include?(type)
  raise "[안전] nodePort를 지정하면 안 된다" if (item.dig("spec", "ports") || []).any? { |p| p.key?("nodePort") }
end

# --- Traefik 라우팅 -------------------------------------------------------
gw = resource(app, "Gateway", "persona-app")
raise "[안전] Gateway는 Traefik이 처리한다" unless gw.dig("spec", "gatewayClassName") == "traefik"
listeners = gw.dig("spec", "listeners") || []
raise "[안전] Gateway listener는 http·https 두 개여야 한다: #{listeners.length}개" unless listeners.length == 2

listener = listeners[0]
raise "[안전] listener[0]은 Traefik HTTP entryPoint 8000이다" unless listener["name"] == "http" && listener["protocol"] == "HTTP" && listener["port"] == 8000
raise "[안전] http listener에 확정되지 않은 접속 주소를 넣지 않는다" if listener.key?("hostname")

https_listener = listeners[1]
raise "[안전] listener[1]은 https여야 한다" unless https_listener["name"] == "https" && https_listener["protocol"] == "HTTPS" && https_listener["port"] == 8443
raise "[안전] https listener hostname이 공개 진입 도메인과 다르다" unless https_listener["hostname"] == "app.personaruntime.xyz"
raise "[안전] https listener는 TLS를 종료해야 한다" unless https_listener.dig("tls", "mode") == "Terminate"
raise "[안전] https listener certificateRef가 persona-app-tls가 아니다" unless https_listener.dig("tls", "certificateRefs", 0) == { "kind" => "Secret", "name" => "persona-app-tls" }

# extension_filters(name => 순서대로 적용될 Middleware 이름 배열)를 넘기면 /v1·/ 규칙의
# filters가 정확히 그 순서(= 적용 순서)의 ExtensionRef인지도 검사한다. Gate 4부터
# 공개 HTTPRoute는 /oauth2 규칙이 하나 더 있어 길이를 2로 고정할 수 없다 — /v1과 /가
# 있는지만 보고 정확한 개수는 호출부에서 규칙별로 따로 확인한다.
def check_v1_and_root_rules(rules, context, extension_filters: {})
  raise "[안전] #{context}: 규칙이 비어 있다" if rules.empty?

  api_rule = rules.find { |r| r.dig("matches", 0, "path", "value") == "/v1" } || raise("#{context}: /v1 규칙이 없다")
  raise "[안전] #{context}: /v1은 PathPrefix다" unless api_rule.dig("matches", 0, "path", "type") == "PathPrefix"
  raise "[안전] #{context}: /v1은 Gateway로 간다" unless api_rule.dig("backendRefs", 0, "name") == "persona-gateway" && api_rule.dig("backendRefs", 0, "port") == 8080

  web_rule = rules.find { |r| r.dig("matches", 0, "path", "value") == "/" } || raise("#{context}: / 규칙이 없다")
  raise "[안전] #{context}: /는 PathPrefix다" unless web_rule.dig("matches", 0, "path", "type") == "PathPrefix"
  raise "[안전] #{context}: /는 Web으로 간다" unless web_rule.dig("backendRefs", 0, "name") == "persona-web" && web_rule.dig("backendRefs", 0, "port") == 8080

  # Python API가 실제로 /v1/... 을 받는다. 접두사를 떼면 404가 된다.
  rules.each do |rule|
    (rule["filters"] || []).each do |filter|
      raise "[안전] #{context}: 경로를 다시 쓰면 안 된다 — Python API가 /v1/...을 그대로 받는다: #{filter["type"]}" if filter["type"] == "URLRewrite"
    end
  end

  { "/v1" => api_rule, "/" => web_rule }.each do |path, rule|
    expected = extension_filters[path]
    next if expected.nil?
    actual = (rule["filters"] || []).map do |filter|
      raise "[안전] #{context} #{path}: filters는 ExtensionRef만 허용한다: #{filter["type"]}" unless filter["type"] == "ExtensionRef"
      raise "[안전] #{context} #{path}: ExtensionRef group은 traefik.io다" unless filter.dig("extensionRef", "group") == "traefik.io"
      raise "[안전] #{context} #{path}: ExtensionRef kind는 Middleware다" unless filter.dig("extensionRef", "kind") == "Middleware"
      filter.dig("extensionRef", "name")
    end
    # 배열 순서 = Traefik 적용 순서(rate-limit이 oauth-forward보다 앞이어야 인증 전에 과호출을 끊는다).
    raise "[안전] #{context} #{path}: Middleware 필터 순서가 다르다 (기대 #{expected}, 실제 #{actual})" unless actual == expected
  end
end

route = resource(app, "HTTPRoute", "persona-app")
raise "[안전] 기존 HTTPRoute는 http listener에 붙어야 한다(Serve/IP 접근 유지)" unless route.dig("spec", "parentRefs", 0, "sectionName") == "http"
raise "[안전] 기존 HTTPRoute에 hostname을 넣으면 Serve가 끊긴다" if route.dig("spec", "hostnames")
raise "[안전] 기존 HTTPRoute: 규칙은 /v1과 / 두 개다" unless route.dig("spec", "rules")&.length == 2
check_v1_and_root_rules(
  route.dig("spec", "rules"), "persona-app HTTPRoute",
  # 이 경로는 oauth-forward를 안 거친다 — strip-auth-header만으로 위조 헤더를 지운다(2차 방어).
  extension_filters: { "/v1" => ["strip-auth-header"], "/" => ["strip-auth-header"] },
)

public_route = resource(ingress, "HTTPRoute", "persona-app-public")
raise "[안전] 공개 HTTPRoute는 https listener에 붙어야 한다" unless public_route.dig("spec", "parentRefs", 0, "sectionName") == "https"
raise "[안전] 공개 HTTPRoute hostname이 공개 진입 도메인과 다르다" unless public_route.dig("spec", "hostnames") == ["app.personaruntime.xyz"]
raise "[안전] 공개 HTTPRoute: 규칙은 /oauth2·/v1·/ 세 개다" unless public_route.dig("spec", "rules")&.length == 3
check_v1_and_root_rules(
  public_route.dig("spec", "rules"), "persona-app-public HTTPRoute",
  # rate-limit이 oauth-forward보다 앞 — 초당 요청이 많으면 GitHub 로그인 여부를 묻기 전에 429.
  extension_filters: {
    "/v1" => ["rate-limit", "oauth-forward", "body-limit", "security-headers"],
    "/" => ["rate-limit", "oauth-forward", "security-headers"],
  },
)

oauth_rule = public_route.dig("spec", "rules").find { |r| r.dig("matches", 0, "path", "value") == "/oauth2" } ||
  raise("[안전] 공개 HTTPRoute: /oauth2 규칙이 없다")
raise "[안전] /oauth2는 PathPrefix다" unless oauth_rule.dig("matches", 0, "path", "type") == "PathPrefix"
raise "[안전] /oauth2는 oauth2-proxy(persona-edge)로 간다" unless oauth_rule.dig("backendRefs", 0, "name") == "oauth2-proxy" &&
  oauth_rule.dig("backendRefs", 0, "namespace") == "persona-edge" && oauth_rule.dig("backendRefs", 0, "port") == 4180
# 콜백·정적 자산 경로 자체가 로그인 흐름이라 자기 자신을 인증할 수 없다 — oauth-forward를 안 붙인다.
oauth_filters = (oauth_rule["filters"] || []).map { |f| f.dig("extensionRef", "name") }
raise "[안전] /oauth2 필터는 security-headers만이어야 한다" unless oauth_filters == ["security-headers"]

# --- Traefik Middleware (Gate 4) -------------------------------------------
# 인터넷 진입용 4개는 persona-app-ingress 렌더에 있다(Sync 분리, 2026-09-19).
middleware = resource(ingress, "Middleware", "oauth-forward")
raise "[안전] oauth-forward: forwardAuth 주소가 다르다" unless middleware.dig("spec", "forwardAuth", "address") == "http://oauth2-proxy.persona-edge.svc:4180/"
raise "[안전] oauth-forward: trustForwardHeader가 꺼져 있으면 안 된다" unless middleware.dig("spec", "forwardAuth", "trustForwardHeader") == true
raise "[안전] oauth-forward: authResponseHeaders가 다르다" unless middleware.dig("spec", "forwardAuth", "authResponseHeaders") == ["X-Auth-Request-User", "X-Auth-Request-Email"]

middleware = resource(ingress, "Middleware", "rate-limit")
raise "[기준선] rate-limit: average/burst가 다르다" unless middleware.dig("spec", "rateLimit", "average") == 20 && middleware.dig("spec", "rateLimit", "burst") == 50
# depth 0 = X-Forwarded-For를 안 쓰고 연결 자체의 IP를 쓴다 — externalTrafficPolicy: Local 전제.
raise "[안전] rate-limit: sourceCriterion depth가 0이 아니다" unless middleware.dig("spec", "rateLimit", "sourceCriterion", "ipStrategy", "depth") == 0

middleware = resource(ingress, "Middleware", "security-headers")
headers = middleware.dig("spec", "headers")
raise "[기준선] security-headers: HSTS/nosniff/referrer 값이 다르다" unless headers["stsSeconds"] == 31_536_000 && headers["stsIncludeSubdomains"] == true &&
  headers["contentTypeNosniff"] == true && headers["referrerPolicy"] == "same-origin"

middleware = resource(ingress, "Middleware", "body-limit")
raise "[기준선] body-limit: maxRequestBodyBytes가 다르다" unless middleware.dig("spec", "buffering", "maxRequestBodyBytes") == 2_097_152

# strip-auth-header는 persona-app에 남아 있다 — 내부 httproute.yaml만 그것을 참조한다.
middleware = resource(app, "Middleware", "strip-auth-header")
raise "[안전] strip-auth-header: 위조 방지 헤더 목록이 다르다" unless middleware.dig("spec", "headers", "customRequestHeaders") == { "X-Auth-Request-User" => "", "X-Auth-Request-Email" => "" }
raise "[안전] persona-app 렌더에 인터넷 진입용 Middleware가 남아 있으면 안 된다(persona-app-ingress로 옮겼어야 한다)" if
  ["oauth-forward", "rate-limit", "security-headers", "body-limit"].any? { |n| app.any? { |i| i["kind"] == "Middleware" && i.dig("metadata", "name") == n } }
raise "[안전] persona-app-ingress 렌더에 strip-auth-header가 있으면 안 된다(persona-app에 남아야 한다)" if
  ingress.any? { |i| i["kind"] == "Middleware" && i.dig("metadata", "name") == "strip-auth-header" }

# NodePort/LoadBalancer 금지 검사(위)는 db+migrate+app+ingress 렌더만 순회한다. Traefik
# Service는 Helm(bootstrap/traefik/values.yaml)로 렌더되는 별도 경로라 이 배열에 없다 —
# 2026-09-17 결정으로 Traefik만 LoadBalancer가 됐지만, 그 값은 scripts/validate-edge-manifests.sh
# 가 아니라 이 스크립트가 다루는 범위 밖(helm template 검증)에서 확인한다.
#
# NetworkPolicy는 이 스크립트가 다루지 않는다 — persona-app-netpol·persona-db-netpol로
# Sync 분리(2026-09-19)돼 scripts/validate-networkpolicy-manifests.sh가 검사한다.

# --- Argo Application -----------------------------------------------------
# persona-migrate Application 선언은 2026-09-16에 저장소에서 뺐다. 완료된 Job은 같은 선언을
# 다시 Sync해도 재실행되지 않지만, Job을 지운 뒤 Sync하면 재생성되고 끝난 일회성 작업이
# 목록에 남으면 무엇이 상시 운영 대상인지 흐려진다. 아래 Job 계약 검사와 overlay 렌더 검사는
# 그대로 두어 다음 revision 선언을 계속 검증한다.
# 재등록 절차와 선언 원문은 runbooks/test-resource-cleanup.md에 있다.
{
  app_db          => ["persona-db", "kustomize/overlays/prod/persona-db", "persona-data"],
  app_apps        => ["persona-app", "kustomize/overlays/prod/persona-app", "persona-app"],
  app_ingress     => ["persona-app-ingress", "kustomize/overlays/prod/persona-app-ingress", "persona-app"],
  app_app_netpol  => ["persona-app-netpol", "kustomize/overlays/prod/persona-app-netpol", "persona-app"],
  app_db_netpol   => ["persona-db-netpol", "kustomize/overlays/prod/persona-db-netpol", "persona-data"],
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
({ "DB" => cspec, "Gateway" => gpod,
   "Web" => wpod, "Traefik" => traefik_values }.merge(job_pods)).each do |label, spec|
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
