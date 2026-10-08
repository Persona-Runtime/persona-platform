#!/bin/sh

set -eu

# mafest API·웹(M6 내부 배포) 선언이 문서 35·26D와 이 레포 규칙을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
#
# 워크로드 base(kustomize/base/mafest-app)는 이미지 digest·기준일이 아직 자리표시라 prod overlay가 가리키지 않는다.
# 그래서 두 가지를 함께 본다.
#   - base 렌더: 켜면 그대로 배포될 내용이다. replica·worker 1·배치·롤링·PDB·probe·보안·Secret·환경변수·DB 계정을 본다.
#   - prod 렌더·Argo: 자리표시 digest·UNCONFIRMED 값이 렌더에 없고, mafest-app Application이 초안(.draft)일 때
#     overlay가 비어 있어야 한다. 공개 진입(준비 중 페이지)으로 가는 선언은 여기서 만들지 않는다.
#
# 메시지 태그
#   [안전]   어긴 채로 배포하면 데이터·권한 경계가 무너지거나 서비스가 끊긴다.
#   [기준선] 지금 합의한 출발값이다. 실측 뒤 근거를 남기고 바꿀 수 있다.

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mafest-app.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/base/mafest-app"         > "$work/base.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-app" > "$work/prod.yaml"

ruby -ryaml - "$work" "$repo_dir" <<'RUBY'
# encoding: utf-8
#
# 매직 코멘트는 이 heredoc 소스의 인코딩, 아래 대입은 File.read로 읽는 매니페스트의 인코딩을 고정한다.
Encoding.default_external = Encoding::UTF_8

work, repo = ARGV
load_stream = ->(path) { YAML.load_stream(File.read(path)).compact }
base = load_stream.call(File.join(work, "base.yaml"))
prod = load_stream.call(File.join(work, "prod.yaml"))

PLACEHOLDER = /@sha256:0{64}\b/
HOME_WORKER_AFFINITY = {
  "requiredDuringSchedulingIgnoredDuringExecution" => {
    "nodeSelectorTerms" => [
      { "matchExpressions" => [{ "key" => "kubernetes.io/hostname", "operator" => "In", "values" => %w[k8s-worker1 k8s-worker2] }] },
    ],
  },
}.freeze

def find(all, kind, name)
  all.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } || raise("missing #{kind}/#{name}")
end

def env_map(container)
  (container["env"] || []).to_h { |e| [e["name"], e] }
end

def check_pod_security(spec, container, context, uid)
  raise "[안전] #{context}: ServiceAccount 토큰을 마운트하지 않는다" unless spec["automountServiceAccountToken"] == false
  raise "[안전] #{context}: seccomp RuntimeDefault가 아니다" unless spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
  sc = container["securityContext"] || {}
  raise "[안전] #{context}: nonroot(#{uid})로 돌아야 한다" unless sc["runAsNonRoot"] == true && sc["runAsUser"] == uid
  raise "[안전] #{context}: read-only rootfs여야 한다" unless sc["readOnlyRootFilesystem"] == true
  raise "[안전] #{context}: 권한 상승을 막아야 한다" unless sc["allowPrivilegeEscalation"] == false
  raise "[안전] #{context}: capability를 모두 버려야 한다" unless sc.dig("capabilities", "drop") == ["ALL"]
  tmp = (spec["volumes"] || []).find { |v| v["name"] == "tmp" }
  raise "[안전] #{context}: /tmp는 크기를 묶은 emptyDir이어야 한다" unless tmp && tmp.dig("emptyDir", "sizeLimit")
end

def check_pdb(all, name)
  pdb = find(all, "PodDisruptionBudget", name)
  raise "[안전] #{name} PDB는 minAvailable 1이어야 한다(replicas 2와 짝)" unless pdb.dig("spec", "minAvailable") == 1
  raise "[안전] #{name} PDB selector가 자기 Pod 이름 라벨 하나여야 한다" unless pdb.dig("spec", "selector", "matchLabels") == { "app.kubernetes.io/name" => name }
end

raise "[안전] mafest-app base에 Namespace를 넣지 않는다(bootstrap/namespaces가 소유)" if base.any? { |item| item["kind"] == "Namespace" }
raise "[안전] mafest-app base에 NetworkPolicy를 섞지 않는다(networkpolicy/mafest-app이 따로 관리)" if base.any? { |item| item["kind"].to_s.end_with?("NetworkPolicy") }
raise "[안전] mafest-app base에 Secret을 두지 않는다(사람이 Git 밖에서 만든다)" if base.any? { |item| item["kind"] == "Secret" }

# --- API --------------------------------------------------------------------------
api = find(base, "Deployment", "mafest-api")
api_spec = api.dig("spec", "template", "spec")
raise "[안전] API는 replicas 2다(Pod마다 Uvicorn worker 1)" unless api.dig("spec", "replicas") == 2
raise "[안전] API 롤링은 maxSurge 1·maxUnavailable 0이다(새 Pod Ready 뒤 교체)" unless api.dig("spec", "strategy", "rollingUpdate") == { "maxSurge" => 1, "maxUnavailable" => 0 }
raise "[안전] API Pod 라벨 app.kubernetes.io/name=mafest-api는 DB ingress 정책의 계약이다" unless api.dig("spec", "template", "metadata", "labels", "app.kubernetes.io/name") == "mafest-api"
raise "[안전] API는 두 홈 워커에만 둔다(required nodeAffinity)" unless api_spec.dig("affinity", "nodeAffinity") == HOME_WORKER_AFFINITY
raise "[안전] API에 required podAntiAffinity를 두지 않는다 — 워커 하나만 남으면 두 번째 Pod가 Pending이다" if api_spec.dig("affinity", "podAntiAffinity", "requiredDuringSchedulingIgnoredDuringExecution")
spread = api_spec["topologySpreadConstraints"] || []
raise "[안전] API 분산 제약은 하나여야 한다" unless spread.length == 1
s = spread.first
raise "[안전] API 분산: hostname·maxSkew 1·DoNotSchedule·nodeTaintsPolicy Honor여야 한다" unless s["topologyKey"] == "kubernetes.io/hostname" && s["maxSkew"] == 1 && s["whenUnsatisfiable"] == "DoNotSchedule" && s["nodeTaintsPolicy"] == "Honor"
raise "[안전] API 분산: matchLabelKeys pod-template-hash가 있어야 롤아웃 뒤 새 Pod끼리 나뉜다" unless s["matchLabelKeys"] == ["pod-template-hash"]
raise "[안전] API 분산: minDomains를 두지 않는다 — 워커 하나만 남으면 두 번째 Pod가 늘 Pending이다" if s.key?("minDomains")
raise "[안전] API 분산 selector가 API Pod만 골라야 한다" unless s.dig("labelSelector", "matchLabels") == { "app.kubernetes.io/name" => "mafest-api" }
raise "[안전] API 종료 유예는 전체 요청 30초보다 길어야 한다" unless api_spec["terminationGracePeriodSeconds"].to_i > 30
raise "[안전] API 이미지 pull Secret은 mafest-ghcr다" unless api_spec["imagePullSecrets"] == [{ "name" => "mafest-ghcr" }]

containers = api_spec["containers"] || []
raise "[안전] API Pod 컨테이너는 하나다" unless containers.length == 1
c = containers.first
raise "[안전] API 이미지는 mafest-app digest 고정이다(태그 금지)" unless c["image"].to_s =~ %r{\Aghcr\.io/persona-runtime/mafest-app@sha256:[0-9a-f]{64}\z}
raise "[안전] API 컨테이너 포트는 http 8000 하나다(이미지 CMD --port 8000)" unless c["ports"] == [{ "name" => "http", "containerPort" => 8000, "protocol" => "TCP" }]
raise "[안전] API에 command·args를 덮어쓰지 않는다 — Uvicorn --workers 1은 이미지 CMD가 정한다" if c.key?("command") || c.key?("args")
check_pod_security(api_spec, c, "API", 10001)

env = env_map(c)
expected_values = {
  "LLM_USE_MOCK" => "0",
  "MAFEST_ENABLE_VECTOR" => "0",
  "MAFEST_LLM_BASE_URL" => "http://persona-vllm.persona-inference.svc.cluster.local:8000",
  "MAFEST_LLM_MODEL" => "Qwen/Qwen3-4B-Instruct-2507",
  "MAFEST_LLM_TIMEOUT_S" => "20",
  "MAFEST_DB_POOL_MAX" => "4",
  "MAFEST_GRAPH_POOL_MAX" => "2",
}
expected_values.each do |name, value|
  raise "[안전] API 환경변수 #{name}는 #{value.inspect}여야 한다(실제 #{env.dig(name, "value").inspect})" unless env.dig(name, "value") == value
end
# mafest Settings.from_env()가 읽는 이름만 쓴다. 지어낸 이름은 조용히 무시돼 기본값으로 돈다.
allowed = expected_values.keys + %w[MAFEST_DATA_BASE_DATE PGURL]
unknown = env.keys - allowed
raise "[안전] API에 Settings가 읽지 않는 환경변수가 있다: #{unknown.join(", ")}" unless unknown.empty?
raise "[안전] API는 MAFEST_DATA_BASE_DATE를 명시한다(승인 기준일)" unless env.key?("MAFEST_DATA_BASE_DATE")
pgurl = env["PGURL"] || raise("[안전] API에 PGURL이 없다")
raise "[안전] API DSN은 mafest-app Secret mafest-api-db의 PGURL(runtime 계정)이다" unless pgurl.dig("valueFrom", "secretKeyRef") == { "name" => "mafest-api-db", "key" => "PGURL" }
raise "[안전] API에 owner용 mafest-migrator를 연결하지 않는다" if YAML.dump(api).include?("mafest-migrator")
raise "[안전] API에 envFrom을 쓰지 않는다 — 어떤 Secret 키가 들어가는지 선언에서 보이지 않는다" if c.key?("envFrom")

res = c["resources"] || {}
raise "[기준선] API 메모리 request 1Gi·limit 1536Mi(문서 35 출발 후보)가 아니다 — 바꿀 때 실측 근거를 남긴다" unless res.dig("requests", "memory") == "1Gi" && res.dig("limits", "memory") == "1536Mi"
raise "[안전] API에 CPU limit을 두지 않는다(근거 없는 상한은 생성 지연을 키운다)" if res.dig("limits", "cpu")

probe = ->(name) { c.dig(name, "httpGet", "path") }
raise "[안전] API startup·liveness는 /healthz다(DB·vLLM 장애로 재시작 루프를 만들지 않는다)" unless probe.call("startupProbe") == "/healthz" && probe.call("livenessProbe") == "/healthz"
raise "[안전] API readiness는 기본 /readyz다(진단용 deep readiness를 probe에 쓰지 않는다)" unless probe.call("readinessProbe") == "/readyz"
%w[startupProbe livenessProbe readinessProbe].each do |name|
  raise "[안전] API #{name}는 포트 이름 http를 쓴다" unless c.dig(name, "httpGet", "port") == "http"
end

svc = find(base, "Service", "mafest-api")
raise "[안전] API Service는 ClusterIP다(NodePort·LoadBalancer 금지)" unless svc.dig("spec", "type") == "ClusterIP"
raise "[안전] API Service는 8000 → http다" unless svc.dig("spec", "ports") == [{ "name" => "http", "port" => 8000, "targetPort" => "http", "protocol" => "TCP" }]
check_pdb(base, "mafest-api")

pm = find(base, "PodMonitor", "mafest-api")
raise "[안전] API PodMonitor는 release: monitoring-stack 라벨이 있어야 수집된다" unless pm.dig("metadata", "labels", "release") == "monitoring-stack"
raise "[안전] API PodMonitor는 mafest-app의 API Pod만 고른다" unless pm.dig("spec", "namespaceSelector", "matchNames") == ["mafest-app"] && pm.dig("spec", "selector", "matchLabels") == { "app.kubernetes.io/name" => "mafest-api" }
raise "[안전] API PodMonitor는 http 포트의 /metrics를 긁는다" unless pm.dig("spec", "podMetricsEndpoints", 0, "port") == "http" && pm.dig("spec", "podMetricsEndpoints", 0, "path") == "/metrics"

# --- 웹 ---------------------------------------------------------------------------
web = find(base, "Deployment", "mafest-web")
web_spec = web.dig("spec", "template", "spec")
raise "[안전] 웹은 replicas 2다" unless web.dig("spec", "replicas") == 2
raise "[안전] 웹 롤링은 maxSurge 0·maxUnavailable 1이다(문서 35)" unless web.dig("spec", "strategy", "rollingUpdate") == { "maxSurge" => 0, "maxUnavailable" => 1 }
raise "[안전] 웹은 두 홈 워커에만 둔다(required nodeAffinity)" unless web_spec.dig("affinity", "nodeAffinity") == HOME_WORKER_AFFINITY
raise "[안전] 웹 분산은 preferred podAntiAffinity다(required면 워커 하나일 때 재배치가 막힌다)" unless web_spec.dig("affinity", "podAntiAffinity", "preferredDuringSchedulingIgnoredDuringExecution") && !web_spec.dig("affinity", "podAntiAffinity", "requiredDuringSchedulingIgnoredDuringExecution")
wc = (web_spec["containers"] || []).first || raise("[안전] 웹 컨테이너가 없다")
raise "[안전] 웹 이미지는 mafest-web digest 고정이다 — persona-web 이미지를 재사용하지 않는다" unless wc["image"].to_s =~ %r{\Aghcr\.io/persona-runtime/mafest-web@sha256:[0-9a-f]{64}\z}
raise "[안전] 웹 컨테이너 포트는 http 8080 하나다(nginx-unprivileged)" unless wc["ports"] == [{ "name" => "http", "containerPort" => 8080, "protocol" => "TCP" }]
raise "[안전] 웹에 환경변수·Secret을 넣지 않는다 — API 주소는 빌드 때 상대 /v1로 고정된다" if wc.key?("env") || wc.key?("envFrom")
check_pod_security(web_spec, wc, "웹", 101)
web_svc = find(base, "Service", "mafest-web")
raise "[안전] 웹 Service는 ClusterIP 8080 → http다" unless web_svc.dig("spec", "type") == "ClusterIP" && web_svc.dig("spec", "ports") == [{ "name" => "http", "port" => 8080, "targetPort" => "http", "protocol" => "TCP" }]
check_pdb(base, "mafest-web")

# --- prod 렌더·Argo --------------------------------------------------------------
prod_text = YAML.dump(prod)
raise "[안전] mafest-app prod 렌더에 자리표시 digest(0×64)가 있다 — 승인된 digest만 연결한다" if prod_text =~ PLACEHOLDER
raise "[안전] mafest-app prod 렌더에 UNCONFIRMED 값이 있다 — 승인된 기준일을 넣고 연결한다" if prod_text.include?("UNCONFIRMED")
app_live = File.join(repo, "argocd/mafest-app.yaml")
app_draft = File.join(repo, "argocd/mafest-app.yaml.draft")
raise "[안전] mafest-app Application(초안 또는 활성)이 없다" unless File.exist?(app_live) || File.exist?(app_draft)
raise "[안전] mafest-app Application이 활성인데 prod 렌더가 비어 있다" if File.exist?(app_live) && prod.empty?
raise "[안전] mafest-app Application이 초안인데 prod overlay가 무언가를 렌더한다" if !File.exist?(app_live) && !prod.empty?
%w[argocd/mafest-app.yaml argocd/mafest-app.yaml.draft argocd/mafest-app-netpol.yaml argocd/mafest-app-netpol.yaml.draft].each do |path|
  full = File.join(repo, path)
  next unless File.exist?(full)
  app = YAML.load_file(full)
  raise "[안전] #{path}: 자동 Sync를 두지 않는다" if app.dig("spec", "syncPolicy")
  raise "[안전] #{path}: finalizer를 두지 않는다" if app.dig("metadata", "finalizers")
  raise "[안전] #{path}: targetRevision은 develop이다" unless app.dig("spec", "source", "targetRevision") == "develop"
  raise "[안전] #{path}: destination namespace는 mafest-app이다" unless app.dig("spec", "destination", "namespace") == "mafest-app"
end

# --- M8 공개 라우트 초안 ---------------------------------------------------------
# 초안은 어느 kustomization·Argo Application에도 연결되지 않아야 한다(공개 전환은 M8). 스트림 규칙에는 버퍼링
# Middleware(body-limit)·retry를 붙이지 않는다 — 문장 단위 이벤트가 모였다가 나가거나 조회·생성이 두 번 돈다.
route_draft = File.join(repo, "kustomize/base/mafest-public/route.yaml.draft")
raise "[안전] M8 공개 라우트 초안(kustomize/base/mafest-public/route.yaml.draft)이 없다" unless File.exist?(route_draft)
Dir.glob(File.join(repo, "kustomize/**/kustomization.yaml")).each do |path|
  refs = (YAML.load_file(path) || {}).values_at("resources", "components").flatten.compact
  raise "[안전] #{path.sub(repo + "/", "")}가 M8 공개 라우트 초안을 렌더에 넣는다 — M6에서 공개 경로를 바꾸지 않는다" if refs.any? { |ref| ref.to_s.include?("mafest-public") }
end
Dir.glob(File.join(repo, "argocd/*.yaml")).each do |path|
  raise "[안전] #{path.sub(repo + "/", "")}가 M8 공개 라우트 초안을 Sync 대상으로 둔다" if YAML.load_file(path).dig("spec", "source", "path").to_s.include?("mafest-public")
end
route_docs = YAML.load_stream(File.read(route_draft)).compact
middlewares = route_docs.select { |d| d["kind"] == "Middleware" }.to_h { |d| [d.dig("metadata", "name"), d["spec"]] }
raise "[안전] 공개 라우트 초안에 retry Middleware를 두지 않는다" if middlewares.values.any? { |spec| spec.key?("retry") }
route = route_docs.find { |d| d["kind"] == "HTTPRoute" } || raise("[안전] 공개 라우트 초안에 HTTPRoute가 없다")
stream_rule = (route.dig("spec", "rules") || []).find do |rule|
  (rule["matches"] || []).any? { |m| m.dig("path", "value") == "/v1/search/stream" }
end || raise("[안전] 공개 라우트 초안에 /v1/search/stream 규칙이 없다")
stream_mw = (stream_rule["filters"] || []).map { |f| f.dig("extensionRef", "name") }
raise "[안전] 스트림 규칙에 버퍼링 Middleware를 붙이지 않는다" if stream_mw.any? { |name| middlewares.dig(name)&.key?("buffering") }
raise "[안전] 스트림 규칙은 POST Exact /v1/search/stream 하나로 고정한다" unless stream_rule["matches"] == [{ "method" => "POST", "path" => { "type" => "Exact", "value" => "/v1/search/stream" } }]

puts "mafest-app(API·웹 선언 base·prod 렌더·Argo 초안·M8 라우트 초안) 검사 통과"
RUBY
