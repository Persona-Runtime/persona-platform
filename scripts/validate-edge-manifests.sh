#!/bin/sh

set -eu

# 공개 진입 Gate 3의 새 kustomize 경로(MetalLB 설정·cert-manager ClusterIssuer·DDNS)가
# 렌더되고 핵심 계약을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
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
  "$repo_dir/bootstrap/namespaces/persona-edge.yaml" \
  "$repo_dir/argocd/metallb.yaml" \
  "$repo_dir/argocd/metallb-config.yaml" \
  "$repo_dir/argocd/cert-manager.yaml" \
  "$repo_dir/argocd/cert-manager-issuers.yaml" \
  "$repo_dir/argocd/persona-edge.yaml" <<'RUBY'
Encoding.default_external = Encoding::UTF_8

metallb_path, issuers_path, edge_path,
  ns_metallb_path, ns_edge_path,
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
  raise "[안전] #{name}: email을 실제 값으로 만들어내면 안 된다 — 자리표시자여야 한다" unless acme["email"] == "ACME_EMAIL_PLACEHOLDER"
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
raise "[안전] ZONE_ID는 실제 값을 만들어내면 안 된다 — 자리표시자여야 한다" unless configmap.dig("data", "ZONE_ID") == "ZONE_ID_PLACEHOLDER"
raise "[안전] RECORD_NAME이 공개 진입 도메인과 다르다" unless configmap.dig("data", "RECORD_NAME") == "app.personaruntime.xyz"
script = configmap.dig("data", "update-dns.sh") || raise("[안전] update-dns.sh 스크립트가 ConfigMap에 없다")
raise "[안전] DDNS 스크립트에 토큰을 로그로 출력하는 것으로 보이는 echo가 있다 — 응답 전체를 출력하면 안 된다" if script =~ /echo\s+"\$(record_json|update_json)"/

# --- bootstrap namespace -----------------------------------------------------
ns_metallb = YAML.load_file(ns_metallb_path)
raise "[안전] metallb-system: Namespace kind가 아니다" unless ns_metallb["kind"] == "Namespace"
raise "[안전] metallb-system: PSA privileged 예외 라벨이 없다 — speaker가 hostNetwork·NET_ADMIN을 쓴다" unless ns_metallb.dig("metadata", "labels", "pod-security.kubernetes.io/enforce") == "privileged"

ns_edge = YAML.load_file(ns_edge_path)
raise "[안전] persona-edge: Namespace kind가 아니다" unless ns_edge["kind"] == "Namespace"
raise "[안전] persona-edge: PSA restricted가 아니다 — 이 namespace는 privileged 권한이 필요 없다" unless ns_edge.dig("metadata", "labels", "pod-security.kubernetes.io/enforce") == "restricted"

# --- Argo Application ---------------------------------------------------------
# metallb·cert-manager는 CRD 설치용 multi-source Application이라 CreateNamespace만 허용한다.
{ app_metallb_path => "metallb", app_cert_manager_path => "cert-manager" }.each do |path, name|
  application = YAML.load_file(path)
  raise "[안전] #{name}: Application kind가 아니다" unless application["kind"] == "Application"
  spec = application.fetch("spec")
  raise "[안전] #{name}: CreateNamespace syncOption이 없다" unless spec.dig("syncPolicy", "syncOptions") == ["CreateNamespace=true"]
  raise "[안전] #{name}: 자동 Sync를 켜면 안 된다" if spec.dig("syncPolicy", "automated")
end

# metallb-config·cert-manager-issuers·persona-edge는 이 저장소 path를 가리키는 단일 source이고
# 수동 Sync만 한다(기존 persona-app·persona-db와 같은 원칙) — syncPolicy 자체가 없어야 한다.
{
  app_metallb_config_path        => ["metallb-config", "kustomize/overlays/prod/metallb-config", "metallb-system"],
  app_cert_manager_issuers_path  => ["cert-manager-issuers", "kustomize/overlays/prod/cert-manager-issuers", "cert-manager"],
  app_edge_path                  => ["persona-edge", "kustomize/overlays/prod/persona-edge", "persona-edge"],
}.each do |path, (name, source_path, namespace)|
  application = YAML.load_file(path)
  raise "[안전] #{name}: Application kind가 아니다" unless application["kind"] == "Application"
  raise "[안전] #{name}: 이름이 다르다" unless application.dig("metadata", "name") == name
  spec = application.fetch("spec")
  raise "[안전] #{name}: develop 브랜치를 봐야 한다" unless spec.dig("source", "targetRevision") == "develop"
  raise "[안전] #{name}: source path가 다르다" unless spec.dig("source", "path") == source_path
  raise "[안전] #{name}: 대상 namespace가 다르다" unless spec.dig("destination", "namespace") == namespace
  raise "[안전] #{name}: 자동 Sync를 켜면 안 된다" if spec.key?("syncPolicy")
end

puts "edge(MetalLB 설정·cert-manager ClusterIssuer·DDNS) 렌더와 매니페스트 정책 검사 통과"
RUBY
