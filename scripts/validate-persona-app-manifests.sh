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
  "$repo_dir/kustomize/base/persona-migrate/kustomization.yaml" \
  "$repo_dir/argocd" <<'RUBY'
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
  migrate_base_path, argocd_dir = ARGV

# 0005 전용 최종 Gateway 이미지(persona-gateway PR #20 머지 뒤 게시, SUPPORTED=0005). 0005
# migration은 적용·Complete됐다(Job은 history/). 바꿀 때는 kustomize/base/persona-gateway/
# deployment.yaml의 image를 함께 바꾼다.
# 아래 MIGRATION_IMAGES["0004-chat"]은 이 값과 다르지만 그게 맞다 — 그쪽은 이미 만들어진
# Job이 쓴 이미지라 바꿀 수 없다(다음 주석 참고).
GATEWAY_IMAGE = "ghcr.io/persona-runtime/persona-minimal-api@sha256:5438d8a80acf414704242901a428c7ef3154bb5496709d3d2d7bea1e9e63f436"

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
  "0003-material-chunks" => "ghcr.io/persona-runtime/persona-minimal-api@sha256:404b270a3095e496db5050c8fca05f4dbaf2e7da75bbb5cd0a8f74c89ce9a041",
  # 0004 Job은 아직 kustomization의 resources에 없어 렌더되지 않는다 — 그래도 승인
  # 이미지를 먼저 등록해 둔다. 이 항목이 없으면 Job을 연결하는 커밋(백업 뒤 5단계)에서
  # "승인 이미지가 등록되지 않은 migration Job"으로 막힌다.
  "0004-chat" => "ghcr.io/persona-runtime/persona-minimal-api@sha256:ce380717fcf1d2db0ffd22e9d4726914a82006472f4ea725e4a2d889b2d032da",
  # 0005 Job은 운영 Gateway와 같은 bridge 이미지(gateway 6fe5200)를 썼다 — 0004·0005를 둘 다
  # 허용하므로 migration 앞뒤로 같은 이미지가 Ready이고, migration 코드와 앱 코드가 갈라지지 않는다.
  # 적용·Complete 뒤 history/로 옮겼지만 이력으로 남긴다(0001·0003·0004와 같은 정책).
  "0005-generation-lease" => "ghcr.io/persona-runtime/persona-minimal-api@sha256:26dcf9e0f2b64aa49c7683bab37ba6a937027b92b0ba2fa1f1f6ed21f53d311e",
}
WEB_IMAGE     = "ghcr.io/persona-runtime/persona-web@sha256:a8232f5a2541e044f4db0d7efa94003a880f0cf48bf390edce4f07540689a9ed"
EMBEDDING_IMAGE = "ghcr.io/persona-runtime/persona-embedding-service@sha256:a0165c1c16c96c7525f36af013aee1fa635501aad9b7f2aab05cfee31be1e887"
HOME_WORKERS  = ["k8s-worker1", "k8s-worker2"]

# 게시 전 Job·Deployment 선언은 digest 자리에 0으로 채운 자리표시자를 쓴다(예:
# job-0004-chat.yaml). 그 값이 승인 이미지 목록에 그대로 등록되면 "승인된 digest와
# 일치한다"는 검사가 자리표시자끼리 맞춰져 통과해 버린다 — 실제로 존재하지 않는
# 이미지를 승인한 셈이다. 상수 쪽에서 먼저 막는다.
{ "GATEWAY_IMAGE" => GATEWAY_IMAGE, "WEB_IMAGE" => WEB_IMAGE, "EMBEDDING_IMAGE" => EMBEDDING_IMAGE }
  .merge(MIGRATION_IMAGES.transform_keys { |rev| "MIGRATION_IMAGES[#{rev}]" })
  .each do |label, image|
    raise "[안전] #{label}에 자리표시자 digest가 남아 있다 — 게시한 이미지의 digest로 바꿔라" if image =~ /sha256:0+\z/
  end

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
  # target revision은 Job 이름에서 파생한 revision이어야 한다(0005-generation-lease →
  # 0005_generation_lease). `upgrade head`는 이미지가 담은 마지막 revision까지 조용히 올라가므로
  # 더는 허용하지 않는다 — 다른 revision을 담은 이미지로 잘못 연결돼도 의도한 revision에서 멈추게
  # 하려는 것이다. head를 썼던 0001·0003·0004 Job은 history/라 렌더되지 않아 이 검사를 받지 않는다.
  target_revision = revision.tr("-", "_")
  unless jcontainer["args"] == ["upgrade", target_revision]
    raise "[안전] migration args가 Job 이름의 revision(upgrade #{target_revision})이 아니다: #{jname}"
  end
  unless job.dig("metadata", "labels", "persona.runtime/alembic-revision") == revision
    raise "[안전] migration Job의 alembic-revision label이 Job 이름의 revision과 다르다: #{jname}"
  end
  # migrator는 Kubernetes API 권한이 필요 없다 — 별도 ServiceAccount로 권한을 얹지 않는다.
  unless [nil, "default"].include?(jpod["serviceAccountName"])
    raise "[안전] migration Job에 별도 ServiceAccount를 붙이지 않는다: #{jname}"
  end
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
# G-1 generation 소유권 lease(운영 DB 0005) 이후의 기준선이다. 그 전에는 새 Pod 기동이 다른
# Pod의 진행 중 SSE를 끊었으므로 1이었다. 아래 PDB(minAvailable 1)는 replica 2를 전제한다 —
# replica 1에서는 drain을 영원히 막는다.
raise "[기준선] Gateway replica가 기준선(2)과 다르다 — PDB minAvailable 1과 hostname 분산이 2대를 전제한다" unless gspec["replicas"] == 2
raise "[기준선] Gateway는 RollingUpdate로 교체한다" unless gspec.dig("strategy", "type") == "RollingUpdate"
raise "[기준선] Gateway maxSurge는 1이다" unless gspec.dig("strategy", "rollingUpdate", "maxSurge") == 1
raise "[기준선] Gateway maxUnavailable은 0이다" unless gspec.dig("strategy", "rollingUpdate", "maxUnavailable") == 0
gpod = gspec.dig("template", "spec")
check_hardened_pod(gpod, "Gateway", "persona-app-ghcr")
raise "[기준선] Gateway 종료 유예가 기준선(30초)과 다르다 — Uvicorn graceful 25초보다 길어야 한다" unless gpod["terminationGracePeriodSeconds"] == 30

# 정상 시 두 replica를 서로 다른 홈 워커에 둔다. 정확히 하나의 제약만 허용하고 값을 고정한다.
# - ScheduleAnyway로 바꾸면 두 워커가 멀쩡해도 두 Pod가 한 워커에 몰릴 수 있어, 워커 하나 장애가
#   두 Pod를 함께 잃는다.
# - selector가 비었거나 part-of처럼 넓으면 다른 앱 Pod까지 셈에 들어가 분산이 틀어진다.
# - nodeTaintsPolicy Honor: 빠지거나 Ignore면 cordon·NotReady 노드가 계산에 남아 두 번째 Pod가
#   Pending이 된다. 워커 하나만 남았을 때는 그 워커에 함께 배치하는 것이 의도다.
# - minDomains는 두지 않는다. 2 이상이면 워커 하나만 남았을 때 항상 Pending이다.
# - matchLabelKeys는 pod-template-hash 하나다. 빠지면 롤아웃 중 이전 revision Pod까지 셈에 들어가
#   롤아웃이 끝난 뒤 새 Pod 둘이 한 워커에 남을 수 있다. 다른 label을 쓰면 revision을 가르지 못한다.
GATEWAY_POD_SELECTOR = { "matchLabels" => { "app.kubernetes.io/name" => "persona-gateway" } }
spreads = gpod["topologySpreadConstraints"] || []
raise "[안전] Gateway topologySpreadConstraints가 정확히 1개여야 한다: #{spreads.length}개" unless spreads.length == 1
spread = spreads.first
raise "[안전] Gateway topology spread key는 kubernetes.io/hostname이다" unless spread["topologyKey"] == "kubernetes.io/hostname"
raise "[안전] Gateway topology spread maxSkew는 1이다" unless spread["maxSkew"] == 1
raise "[안전] Gateway topology spread는 DoNotSchedule이다 — ScheduleAnyway는 한 워커 몰림을 허용한다" unless spread["whenUnsatisfiable"] == "DoNotSchedule"
raise "[안전] Gateway topology spread nodeTaintsPolicy는 Honor다 — Ignore면 cordon·NotReady 워커가 계산에 남아 두 번째 Pod가 Pending이 된다" unless spread["nodeTaintsPolicy"] == "Honor"
raise "[안전] Gateway topology spread에 minDomains를 두지 않는다 — 워커 하나만 남으면 두 번째 Pod가 항상 Pending이다" if spread.key?("minDomains")
raise "[안전] Gateway topology spread matchLabelKeys는 [pod-template-hash]다 — 없으면 롤아웃 뒤 새 Pod 둘이 한 워커에 남을 수 있다" unless spread["matchLabelKeys"] == ["pod-template-hash"]
raise "[안전] Gateway topology spread labelSelector는 app.kubernetes.io/name=persona-gateway 하나여야 한다 — 비거나 넓은 selector는 다른 Pod를 셈에 넣는다" unless spread["labelSelector"] == GATEWAY_POD_SELECTOR
# 분산이 셈하는 label이 실제 Gateway Pod label과 어긋나면 제약이 아무 Pod도 세지 않는다.
raise "[안전] Gateway Pod label이 topology spread selector와 맞지 않는다" unless gspec.dig("template", "metadata", "labels", "app.kubernetes.io/name") == "persona-gateway"

gcontainer = gpod.fetch("containers").fetch(0)
raise "[안전] Gateway 이미지가 검증된 amd64 child digest가 아니다" unless gcontainer["image"] == GATEWAY_IMAGE
raise "[안전] Gateway 포트는 8080이다" unless gcontainer.dig("ports", 0, "containerPort") == 8080
check_hardened_container(gcontainer, "Gateway", 10_001)

gateway_secrets = (gcontainer["envFrom"] || []).map { |e| e.dig("secretRef", "name") }.compact
gateway_secrets += (gcontainer["env"] || []).map { |e| e.dig("valueFrom", "secretKeyRef", "name") }.compact
raise "[안전] Gateway는 runtime Secret만 참조해야 한다" unless gateway_secrets.uniq == ["persona-gateway-runtime"]
raise "[안전] Gateway에 migrator 자격증명을 주면 안 된다" if gateway_secrets.include?("persona-gateway-migrator")
raise "[안전] DB timeout 예산을 명시해야 한다" unless (gcontainer["env"] || []).any? { |e| e["name"] == "PERSONA_DB_TIMEOUT_SECONDS" && e["value"] == "2" }
# 이 값이 켜져 있어야 공개 경로에서 GitHub 로그인만으로 쓸 수 있다. 꺼지거나 사라지면
# 조용히 정적 토큰 요구로 돌아가 사용자에게 토큰 입력창이 다시 뜬다 — 그 회귀를 막는다.
# 켜도 안전한 근거(헤더 덮어쓰기·헤더 제거)는 deployment.yaml 주석에 있다.
raise "[안전] ForwardAuth가 꺼지면 공개 경로가 정적 토큰 요구로 돌아간다" unless (gcontainer["env"] || []).any? { |e| e["name"] == "PERSONA_FORWARD_AUTH_ENABLED" && e["value"] == "true" }

# 채팅 추론 모드와 mock profile은 **함께** 선언한다(ROLL-01B Hard Node Failure 실험 설정).
# - profile만 있고 mode가 없으면 기본값·Secret에 따라 모드가 정해져 선언만 보고 동작을 알 수 없다.
# - mode가 llm이면 profile은 읽히지 않는다 — 실험이 짧은 응답이나 GPU 경로로 조용히 바뀐다.
# - 같은 이름이 두 번 있으면 뒤의 값이 이기므로 선언이 모호하다.
gateway_env_names = (gcontainer["env"] || []).map { |e| e["name"] }
duplicated_env = gateway_env_names.select { |name| gateway_env_names.count(name) > 1 }.uniq
raise "[안전] Gateway env 이름이 중복됐다: #{duplicated_env.join(", ")}" unless duplicated_env.empty?
gateway_env = (gcontainer["env"] || []).to_h { |e| [e["name"], e["value"]] }
raise "[안전] Gateway PERSONA_CHAT_INFERENCE_MODE는 mock으로 명시해야 한다 — 없거나 llm이면 mock profile이 적용되지 않는다" unless gateway_env["PERSONA_CHAT_INFERENCE_MODE"] == "mock"
raise "[기준선] Gateway PERSONA_CHAT_MOCK_PROFILE은 long이어야 한다(ROLL-01B 실험 설정)" unless gateway_env["PERSONA_CHAT_MOCK_PROFILE"] == "long"

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

# Gateway PodMonitor — 수집 대상이 조용히 넓어지거나 사라지는 것을 막는다.
#
# 이 선언만으로는 수집되지 않는다. persona-app의 default-deny를 뚫는
# allow-gateway-metrics가 함께 있어야 하고, 그쪽은 scripts/validate-networkpolicy-
# manifests.sh가 검사한다(NetworkPolicy는 Sync가 분리돼 이 스크립트가 다루지 않는다).
gateway_monitors = app.select { |item| item["kind"] == "PodMonitor" }
raise "[안전] Gateway PodMonitor가 정확히 1개여야 한다: #{gateway_monitors.length}개" unless gateway_monitors.length == 1
gateway_monitor = gateway_monitors.fetch(0)
raise "[안전] Gateway PodMonitor 이름은 persona-gateway다" unless gateway_monitor.dig("metadata", "name") == "persona-gateway"
raise "[안전] Gateway PodMonitor는 persona-app namespace여야 한다" unless gateway_monitor.dig("metadata", "namespace") == "persona-app"
raise "[안전] Gateway PodMonitor에 release=monitoring-stack 라벨이 있어야 Prometheus가 대상으로 인식한다" unless gateway_monitor.dig("metadata", "labels", "release") == "monitoring-stack"
raise "[안전] Gateway PodMonitor namespaceSelector가 persona-app만 가리켜야 한다" unless gateway_monitor.dig("spec", "namespaceSelector", "matchNames") == ["persona-app"]
# selector를 통째로 비교한다. matchLabels만 보면 matchExpressions를 덧붙여 Web·
# Embedding·migration Job까지 긁게 만드는 우회를 놓친다 — 그 Pod들에는 /metrics가
# 없어 타깃이 down으로 남는다.
raise "[안전] Gateway PodMonitor selector는 app.kubernetes.io/name=persona-gateway 하나여야 한다 — matchExpressions로 대상을 넓히지 않는다" unless gateway_monitor.dig("spec", "selector") == { "matchLabels" => { "app.kubernetes.io/name" => "persona-gateway" } }
gateway_endpoints = gateway_monitor.dig("spec", "podMetricsEndpoints") || raise("[안전] Gateway PodMonitor에 podMetricsEndpoints가 없다")
raise "[안전] Gateway PodMonitor podMetricsEndpoints가 정확히 1개여야 한다: #{gateway_endpoints.length}개" unless gateway_endpoints.length == 1
gateway_endpoint = gateway_endpoints.fetch(0)
# Gateway는 API와 /metrics를 같은 8080에서 제공하므로 전용 metrics 포트가 없다.
# 숫자가 아니라 Deployment가 선언한 이름(http)을 써야 포트 번호가 바뀌어도 깨지지 않는다.
raise "[안전] Gateway PodMonitor 포트는 숫자가 아니라 이름(http)이어야 한다" unless gateway_endpoint["port"] == "http"
raise "[안전] Gateway PodMonitor 경로는 /metrics여야 한다" unless gateway_endpoint["path"] == "/metrics"
raise "[안전] Gateway PodMonitor scheme은 http여야 한다 — 홈 클러스터 내부 통신은 TLS를 전제하지 않는다" unless gateway_endpoint["scheme"] == "http"
raise "[기준선] Gateway PodMonitor scrape interval이 기준선(30s)과 다르다" unless gateway_endpoint["interval"] == "30s"
raise "[기준선] Gateway PodMonitor scrapeTimeout이 기준선(10s)과 다르다" unless gateway_endpoint["scrapeTimeout"] == "10s"

# Gateway PDB — 자발적 중단(drain·eviction) 중에도 한 대는 남긴다. 노드 장애나 진행 중 SSE
# 지속은 PDB가 보장하지 않는다(pdb.yaml 주석).
#
# persona-app 렌더 전체에서 PDB가 정확히 하나인지 본다. 두 번째 PDB가 같은 Pod를 겹쳐 고르면
# eviction이 둘 다 만족해야 해서 drain이 예상과 다르게 막힐 수 있다.
# - minAvailable은 정수 1만 허용한다: 2면 replica 2에서 drain이 영원히 막히고, "50%" 같은
#   비율은 replica 수에 따라 뜻이 바뀐다. maxUnavailable과 함께 쓰는 것도 막는다.
# - selector는 Gateway Pod만 고른다. part-of·빈 selector는 Web 등 다른 Pod까지 묶는다.
pdbs = app.select { |item| item["kind"] == "PodDisruptionBudget" }
raise "[안전] persona-app PDB가 정확히 1개(Gateway)여야 한다: #{pdbs.length}개" unless pdbs.length == 1
gateway_pdb = pdbs.first
raise "[안전] Gateway PDB 이름은 persona-gateway다" unless gateway_pdb.dig("metadata", "name") == "persona-gateway"
raise "[안전] Gateway PDB는 persona-app namespace여야 한다" unless gateway_pdb.dig("metadata", "namespace") == "persona-app"
pdb_spec = gateway_pdb.fetch("spec")
raise "[안전] Gateway PDB minAvailable은 정수 1이다 — 2는 replica 2에서 drain을 막고, 비율은 replica 수에 따라 뜻이 바뀐다" unless pdb_spec["minAvailable"] == 1
raise "[안전] Gateway PDB에 maxUnavailable을 함께 쓰지 않는다" if pdb_spec.key?("maxUnavailable")
raise "[안전] Gateway PDB selector는 app.kubernetes.io/name=persona-gateway 하나여야 한다 — 넓은 selector는 다른 앱 Pod를 묶는다" unless pdb_spec["selector"] == GATEWAY_POD_SELECTOR

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

embedding = resource(app, "Deployment", "persona-embedding")
espec = embedding.fetch("spec")
raise "[기준선] Embedding replica가 기준선(1)과 다르다 — 모델이 프로세스 메모리에 있어 여러 대면 중복 로딩된다" unless espec["replicas"] == 1
epod = espec.dig("template", "spec")
check_hardened_pod(epod, "Embedding", "persona-app-ghcr")

econtainer = epod.fetch("containers").fetch(0)
raise "[안전] Embedding 이미지가 검증된 amd64 child digest가 아니다" unless econtainer["image"] == EMBEDDING_IMAGE
raise "[안전] Embedding 포트는 8081이다" unless econtainer.dig("ports", 0, "containerPort") == 8081
check_hardened_container(econtainer, "Embedding", 10_001)

# 모델 로딩이 끝나기 전에도 healthz는 응답한다 — liveness가 로딩 시간 동안 파드를
# 죽이면 복구 안 되는 재시작 루프에 빠진다. 로딩 대기는 startupProbe가 맡는다.
raise "[안전] Embedding startup probe는 /healthz다" unless econtainer.dig("startupProbe", "httpGet", "path") == "/healthz"
raise "[안전] Embedding liveness probe는 /healthz다" unless econtainer.dig("livenessProbe", "httpGet", "path") == "/healthz"
raise "[안전] Embedding readiness probe는 /readyz다" unless econtainer.dig("readinessProbe", "httpGet", "path") == "/readyz"
# CPU 추론 모델 로딩 예상 30초~2분(persona-gateway docs/ghcr-publication-2026-09-22-
# embedding.md) — 상한에 여유를 두어 3분(periodSeconds 3 * failureThreshold 60)으로 둔다.
raise "[기준선] Embedding startup period가 기준선(3초)과 다르다" unless econtainer.dig("startupProbe", "periodSeconds") == 3
raise "[기준선] Embedding startup failureThreshold가 기준선(60, 최대 180초)과 다르다" unless econtainer.dig("startupProbe", "failureThreshold") == 60

# --- Service / 외부 노출 --------------------------------------------------
["persona-gateway", "persona-web"].each do |name|
  service = resource(app, "Service", name)
  raise "[안전] #{name} Service는 ClusterIP다" unless service.dig("spec", "type") == "ClusterIP"
  raise "[안전] #{name} Service 포트는 8080이다" unless service.dig("spec", "ports", 0, "port") == 8080
end
embedding_service = resource(app, "Service", "persona-embedding")
raise "[안전] Embedding Service는 ClusterIP다" unless embedding_service.dig("spec", "type") == "ClusterIP"
raise "[안전] Embedding Service 포트는 8081이다" unless embedding_service.dig("spec", "ports", 0, "port") == 8081
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
    # 배열 순서 = Traefik 적용 순서. 요청은 이 순서대로 통과하고 응답은 역순으로 돌아오므로,
    # 앞쪽 필터일수록 뒤쪽 필터의 조기 반환(리다이렉트·429 등) 응답까지 감싸 적용된다 —
    # 호출부(persona-app-public HTTPRoute 검사)의 extension_filters 주석 참고.
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
  # security-headers가 맨 앞 — Traefik 체인은 앞선 미들웨어일수록 뒤 미들웨어의 응답까지
  # 감싸므로, oauth-forward가 미인증 302를 돌려줘도(그 뒤 미들웨어는 실행 안 됨) 이 302가
  # security-headers를 거쳐 나간다(2026-09-20 LTE 실측: 이전 순서에서 302에
  # strict-transport-security가 없었다). rate-limit이 그다음 — 초당 요청이 많으면 GitHub
  # 로그인 여부를 묻기 전에 429. oauth-forward가 맨 뒤 — 인증은 다른 필터를 다 거친 뒤.
  extension_filters: {
    "/v1" => ["security-headers", "rate-limit", "body-limit", "oauth-forward"],
    "/" => ["security-headers", "rate-limit", "oauth-forward"],
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

# 위 루프는 이름을 아는 Application만 본다. 여기서는 argocd/ 아래 파일 전부를 훑어
# syncPolicy.automated만 좁혀 확인한다 — csi-driver-nfs·monitoring-stack·
# persona-nfs-storage처럼 이 스크립트가 이름으로 다루지 않는 Application도 걸리고,
# 이름 목록에 새 Application을 추가하는 걸 잊어도 이 검사만은 계속 걸린다는 안전망이다.
# syncPolicy 키 자체(syncOptions 등)는 여기서 막지 않는다 — automated(자동 Sync·prune)만
# 금지 대상이다.
Dir.glob(File.join(argocd_dir, "*.yaml")).sort.each do |path|
  application = YAML.load_file(path)
  next unless application.is_a?(Hash) && application["kind"] == "Application"

  name = application.dig("metadata", "name") || File.basename(path, ".yaml")
  automated = application.dig("spec", "syncPolicy", "automated")
  raise "[안전] #{name}(#{path}): syncPolicy.automated를 켜면 안 된다(자동 Sync·prune 금지)" unless automated.nil?
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
