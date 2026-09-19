#!/bin/sh

set -eu

# 공개 진입 Gate 3~4의 kustomize 경로(MetalLB 설정·cert-manager ClusterIssuer·DDNS·
# oauth2-proxy)가 렌더되고 핵심 계약을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
# scripts/validate-persona-app-manifests.sh와 같은 패턴([안전] 태그, kubectl kustomize 렌더 +
# ruby 검사)을 쓰되, 이 파일은 persona-app 렌더를 다루지 않는다(그건 위 스크립트의 범위다).

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
metallb_file=$(mktemp "${TMPDIR:-/tmp}/metallb-config.XXXXXX.yaml")
issuers_file=$(mktemp "${TMPDIR:-/tmp}/cert-manager-issuers.XXXXXX.yaml")
edge_file=$(mktemp "${TMPDIR:-/tmp}/persona-edge.XXXXXX.yaml")
trap 'rm -f "$metallb_file" "$issuers_file" "$edge_file"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/metallb-config"         > "$metallb_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/cert-manager-issuers"   > "$issuers_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-edge"           > "$edge_file"

ruby -ryaml - \
  "$metallb_file" "$issuers_file" "$edge_file" \
  "$repo_dir/bootstrap/namespaces/metallb-system.yaml" \
  "$repo_dir/bootstrap/namespaces/cert-manager.yaml" \
  "$repo_dir/bootstrap/namespaces/persona-edge.yaml" \
  "$repo_dir/argocd/metallb.yaml" \
  "$repo_dir/argocd/metallb-config.yaml" \
  "$repo_dir/argocd/cert-manager.yaml" \
  "$repo_dir/argocd/cert-manager-issuers.yaml" \
  "$repo_dir/argocd/persona-edge.yaml" <<'RUBY'
Encoding.default_external = Encoding::UTF_8

metallb_path, issuers_path, edge_path,
  ns_metallb_path, ns_cert_manager_path, ns_edge_path,
  app_metallb_path, app_metallb_config_path, app_cert_manager_path, app_cert_manager_issuers_path, app_edge_path = ARGV

def load(path)
  YAML.load_stream(File.read(path)).compact
end

def resource(resources, kind, name)
  resources.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("missing #{kind}/#{name}")
end

# --- MetalLB config ---------------------------------------------------------
metallb = load(metallb_path)
pool = resource(metallb, "IPAddressPool", "traefik-pool")
raise "[안전] IPAddressPool namespace가 metallb-system이 아니다" unless pool.dig("metadata", "namespace") == "metallb-system"
raise "[안전] IPAddressPool 주소가 VIP(192.168.50.240/32)와 다르다" unless pool.dig("spec", "addresses") == ["192.168.50.240/32"]
raise "[안전] autoAssign을 켜면 의도치 않은 Service가 VIP를 가져갈 수 있다" unless pool.dig("spec", "autoAssign") == false

l2 = resource(metallb, "L2Advertisement", "traefik-l2")
raise "[안전] L2Advertisement가 traefik-pool을 가리키지 않는다" unless l2.dig("spec", "ipAddressPools") == ["traefik-pool"]
selectors = l2.dig("spec", "nodeSelectors") || []
raise "[안전] L2Advertisement는 두 홈 워커만 광고 노드여야 한다" unless selectors.map { |s| s.dig("matchLabels", "kubernetes.io/hostname") }.sort == ["k8s-worker1", "k8s-worker2"]

# --- cert-manager ClusterIssuer ---------------------------------------------
issuers = load(issuers_path)
{
  "letsencrypt-staging" => "https://acme-staging-v02.api.letsencrypt.org/directory",
  "letsencrypt-prod"    => "https://acme-v02.api.letsencrypt.org/directory",
}.each do |name, server|
  issuer = resource(issuers, "ClusterIssuer", name)
  acme = issuer.dig("spec", "acme") || raise("[안전] #{name}: acme 설정이 없다")
  raise "[안전] #{name}: ACME 서버가 다르다" unless acme["server"] == server
  # CP가 자리표시자를 실제 이메일로 바꿔 커밋하는 것은 정상 흐름이다(a7eccee) — 특정
  # 문자열과의 완전 일치가 아니라 이메일 형식(@ 포함)만 확인한다.
  raise "[안전] #{name}: email이 비어 있거나 @를 포함하지 않는다" unless acme["email"].to_s.include?("@")
  solver = acme.dig("solvers", 0, "dns01", "cloudflare") || raise("[안전] #{name}: Cloudflare DNS-01 solver가 없다")
  raise "[안전] #{name}: Cloudflare 토큰 Secret 참조가 다르다" unless solver.dig("apiTokenSecretRef") == { "name" => "cloudflare-dns-token", "key" => "api-token" }
end

# --- DDNS CronJob ------------------------------------------------------------
edge = load(edge_path)
raise "[안전] edge overlay가 Namespace를 관리하면 안 된다" if edge.any? { |i| i["kind"] == "Namespace" }

cronjob = resource(edge, "CronJob", "ddns-update")
cspec = cronjob.fetch("spec")
raise "[기준선] DDNS schedule이 기준선(*/5 * * * *)과 다르다" unless cspec["schedule"] == "*/5 * * * *"
raise "[안전] DDNS concurrencyPolicy는 Forbid여야 한다 — 겹친 실행이 같은 레코드를 동시에 PATCH하면 안 된다" unless cspec["concurrencyPolicy"] == "Forbid"
raise "[기준선] DDNS successfulJobsHistoryLimit이 1이 아니다" unless cspec["successfulJobsHistoryLimit"] == 1
raise "[기준선] DDNS failedJobsHistoryLimit이 1이 아니다" unless cspec["failedJobsHistoryLimit"] == 1

pod_spec = cspec.dig("jobTemplate", "spec", "template", "spec")
raise "[안전] DDNS는 재시작하지 않는다" unless pod_spec["restartPolicy"] == "Never"
raise "[안전] DDNS ServiceAccount 토큰 자동 마운트를 꺼야 한다" unless pod_spec["automountServiceAccountToken"] == false
raise "[안전] DDNS RuntimeDefault seccomp이 필요하다" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
nodes = pod_spec.dig("affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values")
raise "[안전] DDNS는 두 홈 워커에만 배치해야 한다" unless nodes == ["k8s-worker1", "k8s-worker2"]

container = pod_spec.fetch("containers").find { |c| c["name"] == "ddns-update" } || raise("ddns-update 컨테이너가 없다")
expected_image = "curlimages/curl@sha256:43366cd60f226c7655181a0f7e85c468a41d182fdd2dc2c1c3b872a2b9d05d7a"
raise "[안전] DDNS 이미지는 검증된 linux/amd64 child manifest digest여야 한다(tag 금지)" unless container["image"] == expected_image
security = container.fetch("securityContext")
raise "[안전] DDNS 컨테이너는 비루트(10001)로 실행해야 한다" unless security["runAsNonRoot"] == true && security["runAsUser"] == 10_001
raise "[안전] DDNS privilege escalation을 막아야 한다" unless security["allowPrivilegeEscalation"] == false
raise "[안전] DDNS 모든 capability를 제거해야 한다" unless security.dig("capabilities", "drop") == ["ALL"]
raise "[안전] DDNS root filesystem이 read-only여야 한다" unless security["readOnlyRootFilesystem"] == true

env_names = (container["env"] || []).map { |e| e["name"] }
raise "[안전] DDNS env에 ZONE_ID·RECORD_NAME·CF_API_TOKEN이 모두 있어야 한다" unless %w[ZONE_ID RECORD_NAME CF_API_TOKEN].all? { |n| env_names.include?(n) }
token_env = (container["env"] || []).find { |e| e["name"] == "CF_API_TOKEN" }
raise "[안전] CF_API_TOKEN은 cloudflare-dns-token Secret의 api-token 키를 참조해야 한다" unless token_env.dig("valueFrom", "secretKeyRef") == { "name" => "cloudflare-dns-token", "key" => "api-token" }

configmap = resource(edge, "ConfigMap", "ddns-config")
# CP가 자리표시자를 실제 Zone ID로 바꿔 커밋하는 것은 정상 흐름이다(a7eccee, ACME
# email과 같은 커밋·같은 이유) — 특정 문자열과의 완전 일치가 아니라 Cloudflare Zone ID
# 형식(32자리 소문자 16진수)만 확인한다.
raise "[안전] ZONE_ID가 Cloudflare Zone ID 형식(32자리 소문자 16진수)이 아니다" unless configmap.dig("data", "ZONE_ID").to_s.match?(/\A[0-9a-f]{32}\z/)
raise "[안전] RECORD_NAME이 공개 진입 도메인과 다르다" unless configmap.dig("data", "RECORD_NAME") == "app.personaruntime.xyz"
script = configmap.dig("data", "update-dns.sh") || raise("[안전] update-dns.sh 스크립트가 ConfigMap에 없다")
raise "[안전] DDNS 스크립트에 토큰을 로그로 출력하는 것으로 보이는 echo가 있다 — 응답 전체를 출력하면 안 된다" if script =~ /echo\s+"\$(record_json|update_json)"/

# --- oauth2-proxy (Gate 4) ---------------------------------------------------
deployment = resource(edge, "Deployment", "oauth2-proxy")
dspec = deployment.fetch("spec")
raise "[기준선] oauth2-proxy replicas가 1이 아니다" unless dspec["replicas"] == 1
pod_spec = dspec.dig("template", "spec")
raise "[안전] oauth2-proxy RuntimeDefault seccomp이 필요하다" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
nodes = pod_spec.dig("affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values")
raise "[안전] oauth2-proxy는 두 홈 워커에만 배치해야 한다" unless nodes == ["k8s-worker1", "k8s-worker2"]

container = pod_spec.fetch("containers").find { |c| c["name"] == "oauth2-proxy" } || raise("oauth2-proxy 컨테이너가 없다")
expected_image = "quay.io/oauth2-proxy/oauth2-proxy@sha256:97038fe4354e6ace6612f2f88dc7b332ae6916bddf89da9aea4f2064ea0c2071"
raise "[안전] oauth2-proxy 이미지는 검증된 linux/amd64 child manifest digest여야 한다(tag 금지)" unless container["image"] == expected_image
security = container.fetch("securityContext")
raise "[안전] oauth2-proxy 컨테이너는 비루트(10001)로 실행해야 한다" unless security["runAsNonRoot"] == true && security["runAsUser"] == 10_001
raise "[안전] oauth2-proxy privilege escalation을 막아야 한다" unless security["allowPrivilegeEscalation"] == false
raise "[안전] oauth2-proxy 모든 capability를 제거해야 한다" unless security.dig("capabilities", "drop") == ["ALL"]
raise "[안전] oauth2-proxy root filesystem이 read-only여야 한다" unless security["readOnlyRootFilesystem"] == true
raise "[기준선] oauth2-proxy 리소스(requests 32Mi/limits 64Mi)가 다르다" unless container.dig("resources", "requests", "memory") == "32Mi" && container.dig("resources", "limits", "memory") == "64Mi"

expected_args = %w[
  --provider=github
  --github-user=$(GITHUB_ALLOWED_USERS)
  --upstream=static://202
  --http-address=0.0.0.0:4180
  --reverse-proxy=true
  --set-xauthrequest=true
  --cookie-secure=true
  --cookie-samesite=lax
  --cookie-expire=168h
  --cookie-refresh=1h
  --whitelist-domain=app.personaruntime.xyz
  --redirect-url=https://app.personaruntime.xyz/oauth2/callback
  --skip-provider-button=true
  --email-domain=*
  --trusted-proxy-ip=10.244.0.0/16
]
raise "[안전] oauth2-proxy args가 승인된 목록과 다르다" unless container["args"] == expected_args

env_names = (container["env"] || []).map { |e| e["name"] }
raise "[안전] oauth2-proxy env에 GITHUB_ALLOWED_USERS가 없다" unless env_names.include?("GITHUB_ALLOWED_USERS")
raise "[안전] oauth2-proxy Secret(client-id·secret·cookie-secret)은 envFrom.secretRef로만 와야 한다 — Git에 값이 없다" unless (container["envFrom"] || []).any? { |e| e.dig("secretRef", "name") == "oauth2-proxy" }

oauth_configmap = resource(edge, "ConfigMap", "oauth2-proxy-config")
# 위 ZONE_ID와 같은 이유 — CP가 실제 GitHub 계정명으로 바꿔 커밋하는 것이 정상 흐름이다.
# 비어 있지 않고 자리표시자 문자열 그대로도 아닌지만 확인한다.
github_allowed_users = oauth_configmap.dig("data", "GITHUB_ALLOWED_USERS").to_s
raise "[안전] GITHUB_ALLOWED_USERS가 비어 있거나 자리표시자 그대로다" if github_allowed_users.strip.empty? || github_allowed_users == "GITHUB_USERS_PLACEHOLDER"

service = resource(edge, "Service", "oauth2-proxy")
raise "[안전] oauth2-proxy Service는 ClusterIP여야 한다 — 외부에 직접 노출하지 않는다" unless service.dig("spec", "type") == "ClusterIP" || service.dig("spec", "type").nil?
raise "[안전] oauth2-proxy Service 포트가 4180이 아니다" unless service.dig("spec", "ports", 0, "port") == 4180

# persona-app 네임스페이스의 HTTPRoute가 크로스 네임스페이스로 이 Service를 backendRef할 수 있게
# 하는 허가다 — 없으면 HTTPRoute가 렌더는 되지만 Traefik이 참조를 거부한다.
grant = resource(edge, "ReferenceGrant", "persona-app-httproute-to-oauth2-proxy")
raise "[안전] ReferenceGrant from이 persona-app의 HTTPRoute가 아니다" unless grant.dig("spec", "from", 0) == { "group" => "gateway.networking.k8s.io", "kind" => "HTTPRoute", "namespace" => "persona-app" }
raise "[안전] ReferenceGrant to가 oauth2-proxy Service가 아니다" unless grant.dig("spec", "to", 0) == { "group" => "", "kind" => "Service", "name" => "oauth2-proxy" }

# --- bootstrap namespace -----------------------------------------------------
# 이 저장소는 Argo overlay/Application이 Namespace를 소유하지 않는다 — 전부 bootstrap 파일이
# 소유하고, CP 적용 순서(3-7)에서 Argo Sync보다 먼저 적용한다. metallb·cert-manager Argo
# Application에 CreateNamespace=true를 쓰지 않는 이유이기도 하다(아래 Argo 검사).
ns_metallb = YAML.load_file(ns_metallb_path)
raise "[안전] metallb-system: Namespace kind가 아니다" unless ns_metallb["kind"] == "Namespace"
raise "[안전] metallb-system: PSA privileged 예외 라벨이 없다 — speaker가 hostNetwork·NET_ADMIN을 쓴다" unless ns_metallb.dig("metadata", "labels", "pod-security.kubernetes.io/enforce") == "privileged"

ns_cert_manager = YAML.load_file(ns_cert_manager_path)
raise "[안전] cert-manager: Namespace kind가 아니다" unless ns_cert_manager["kind"] == "Namespace"
raise "[안전] cert-manager: 이름이 다르다" unless ns_cert_manager.dig("metadata", "name") == "cert-manager"

ns_edge = YAML.load_file(ns_edge_path)
raise "[안전] persona-edge: Namespace kind가 아니다" unless ns_edge["kind"] == "Namespace"
raise "[안전] persona-edge: PSA restricted가 아니다 — 이 namespace는 privileged 권한이 필요 없다" unless ns_edge.dig("metadata", "labels", "pod-security.kubernetes.io/enforce") == "restricted"

# --- Argo Application ---------------------------------------------------------
# 5개 전부 이 저장소 path를 가리키는 단일 source이거나(metallb-config·cert-manager-issuers·
# persona-edge) CRD 설치용 multi-source(metallb·cert-manager)지만, 어느 쪽도 CreateNamespace를
# 쓰지 않는다 — Namespace는 bootstrap 파일이 소유하고 Argo Sync보다 먼저 적용된다(3-7 2번).
# syncPolicy 자체가 없어야 한다(기존 persona-app·persona-db와 같은 원칙, 자동 Sync 금지 포함).
{
  app_metallb_path               => ["metallb", nil, "metallb-system"],
  app_metallb_config_path        => ["metallb-config", "kustomize/overlays/prod/metallb-config", "metallb-system"],
  app_cert_manager_path          => ["cert-manager", nil, "cert-manager"],
  app_cert_manager_issuers_path  => ["cert-manager-issuers", "kustomize/overlays/prod/cert-manager-issuers", "cert-manager"],
  app_edge_path                  => ["persona-edge", "kustomize/overlays/prod/persona-edge", "persona-edge"],
}.each do |path, (name, source_path, namespace)|
  application = YAML.load_file(path)
  raise "[안전] #{name}: Application kind가 아니다" unless application["kind"] == "Application"
  raise "[안전] #{name}: 이름이 다르다" unless application.dig("metadata", "name") == name
  spec = application.fetch("spec")
  raise "[안전] #{name}: 대상 namespace가 다르다" unless spec.dig("destination", "namespace") == namespace
  raise "[안전] #{name}: 자동 Sync를 켜면 안 된다(CreateNamespace 포함, Namespace는 bootstrap이 소유)" if spec.key?("syncPolicy")
  next if source_path.nil? # metallb·cert-manager는 multi-source라 source.path가 없다 — 아래에서 별도 확인

  raise "[안전] #{name}: develop 브랜치를 봐야 한다" unless spec.dig("source", "targetRevision") == "develop"
  raise "[안전] #{name}: source path가 다르다" unless spec.dig("source", "path") == source_path
end

# metallb·cert-manager는 multi-source(차트 + 이 저장소의 values 참조)다. 두 번째 source가
# develop을 보는지만 확인한다(차트 버전은 render 성공으로 helm template 검증이 대신한다).
{ app_metallb_path => "metallb", app_cert_manager_path => "cert-manager" }.each do |path, name|
  application = YAML.load_file(path)
  values_source = application.dig("spec", "sources", 1)
  raise "[안전] #{name}: values source가 이 저장소 develop을 봐야 한다" unless values_source && values_source["targetRevision"] == "develop" && values_source["ref"] == "values"
end

puts "edge(MetalLB 설정·cert-manager ClusterIssuer·DDNS·oauth2-proxy) 렌더와 매니페스트 정책 검사 통과"
RUBY
