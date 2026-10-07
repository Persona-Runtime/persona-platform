#!/bin/sh

set -eu

# 공개 진입(Gateway persona-app/persona-app)·준비 중 페이지·Argo Application 공통 규칙을
# 로컬에서만 검사한다. 홈 API를 호출하지 않는다. kubectl kustomize로 렌더한 결과만 본다.
#
# persona 앱을 폐기하면서(2026-10-07) persona 검사 스크립트(validate-persona-app-manifests.sh)를
# 지웠다. 그 안에 있던 Gateway 안전 검사는 persona와 무관하게 계속 지켜야 하므로 여기로 옮겼다.
# Gateway가 지워지면 cert-manager gateway-shim이 만든 Certificate·TLS Secret도 ownerReference로
# 함께 지워진다 — 공개 진입을 되살리려면 인증서 재발급까지 다시 해야 한다.
#
# 메시지 태그는 다른 검사와 같다.
#   [안전]   어긴 채로 배포하면 되돌리기 어렵거나(Gateway·인증서 삭제, 공개 노출) 연결이 끊긴다.
#   [기준선] 지금 합의한 값이다. 근거를 남기고 바꿀 수 있다.

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
public_gateway_file=$(mktemp "${TMPDIR:-/tmp}/public-gateway.XXXXXX.yaml")
maintenance_file=$(mktemp "${TMPDIR:-/tmp}/maintenance-page.XXXXXX.yaml")
edge_file=$(mktemp "${TMPDIR:-/tmp}/persona-edge.XXXXXX.yaml")
trap 'rm -f "$public_gateway_file" "$maintenance_file" "$edge_file"' EXIT HUP INT TERM

# 렌더 실패는 그대로 멈춘다(set -e). 빈 렌더를 "선언 없음"으로 읽지 않는다.
kubectl kustomize "$repo_dir/kustomize/overlays/prod/public-gateway"   > "$public_gateway_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/maintenance-page" > "$maintenance_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-edge"     > "$edge_file"

ruby -ryaml - \
  "$public_gateway_file" "$maintenance_file" "$edge_file" \
  "$repo_dir/argocd" \
  "$repo_dir/kustomize/overlays/prod" \
  "$repo_dir/bootstrap/namespaces/persona-app.yaml" <<'RUBY'
# encoding: utf-8
#
# 매직 코멘트는 이 heredoc 소스의 인코딩(로케일이 UTF-8이 아니어도 한글 메시지가 깨지지 않게),
# 아래 대입은 File.read로 여는 외부 매니페스트의 인코딩을 고정한다.
Encoding.default_external = Encoding::UTF_8

require "json"
require "digest"

public_gateway_path, maintenance_path, edge_path, argocd_dir, prod_overlays_dir, ns_app_path = ARGV

def load(path)
  YAML.load_stream(File.read(path)).compact
end

def resource(resources, kind, name)
  resources.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("[안전] #{kind}/#{name} 선언이 없다")
end

PUBLIC_HOST = "app.personaruntime.xyz"

# --- 공개 Gateway 단일 소유 ------------------------------------------------------
# Gateway persona-app/persona-app은 public-gateway Application 하나만 선언한다. 두 Application이
# 같은 객체를 선언하면 Argo가 번갈아 덮어쓰고, 한쪽에서 prune하면 Gateway가 삭제된다. 그래서
# overlay 하나만 보지 않고 prod overlay 전체를 렌더해 선언 개수를 센다. 0개도 실패다.
gateway_declarations = []
Dir.glob(File.join(prod_overlays_dir, "*", "kustomization.yaml")).sort.each do |kustomization|
  overlay_dir = File.dirname(kustomization)
  rendered = IO.popen(["kubectl", "kustomize", overlay_dir], err: [:child, :out], &:read)
  # 렌더 실패를 "Gateway 0개"로 읽으면 중복 선언을 놓친다. 실패는 그대로 멈춘다.
  raise "prod overlay 렌더 실패: #{overlay_dir}\n#{rendered}" unless $?.success?
  YAML.load_stream(rendered).compact.each do |item|
    next unless item["kind"] == "Gateway" && item.dig("metadata", "name") == "persona-app"
    gateway_declarations << "#{File.basename(overlay_dir)}(namespace=#{item.dig("metadata", "namespace") || "없음"})"
  end
end
unless gateway_declarations == ["public-gateway(namespace=persona-app)"]
  raise "[안전] prod overlay 전체에서 Gateway persona-app/persona-app 선언은 public-gateway 하나여야 한다: #{gateway_declarations.inspect}"
end

public_gateway = load(public_gateway_path)
# Certificate·Secret persona-app-tls는 gateway-shim이 만든 live 객체를 그대로 둔다. 이 overlay가
# 그것을 선언하면 Argo가 새로 추적·patch하게 되어 재발급이나 값 덮어쓰기 위험이 생긴다.
unless public_gateway.map { |item| item["kind"] } == ["Gateway"]
  raise "[안전] public-gateway 렌더는 Gateway 하나만 담아야 한다(Certificate·Secret 선언 금지): #{public_gateway.map { |i| "#{i["kind"]}/#{i.dig("metadata", "name")}" }}"
end

# 이관 전(origin/develop ccc014c의 persona-app overlay) Gateway spec 지문. 키를 정렬한 JSON의
# SHA-256이다. spec이 바뀌면 listener·TLS 변경이 함께 반영되므로 막는다. 아래 listener별 검사는
# 이유를 설명하는 메시지를 주고, 이 지문은 그 검사가 보지 않는 필드까지 잡는 최종 안전망이다.
# spec 변경이 정말 필요하면 별도 변경으로 나누고, 그때 이 값을 근거와 함께 바꾼다.
GATEWAY_SPEC_SHA256 = "3439425fbe0dbc41ee5462b38f6207ea972917ef0dc73d15426bce1f4e769891"
canonical = lambda do |value|
  case value
  when Hash then value.keys.sort.map { |key| [key, canonical.call(value[key])] }.to_h
  when Array then value.map { |element| canonical.call(element) }
  else value
  end
end
gw = resource(public_gateway, "Gateway", "persona-app")
raise "[안전] Gateway는 persona-app namespace여야 한다" unless gw.dig("metadata", "namespace") == "persona-app"
# issuer annotation이 바뀌면 gateway-shim이 Certificate를 다른 issuer로 다시 발급한다.
cert_manager_annotations = (gw.dig("metadata", "annotations") || {}).select { |key, _| key.start_with?("cert-manager.io/") }
unless cert_manager_annotations == { "cert-manager.io/cluster-issuer" => "letsencrypt-prod" }
  raise "[안전] Gateway cert-manager annotation이 다르다(cluster-issuer=letsencrypt-prod만 허용): #{cert_manager_annotations}"
end
# 리소스 annotation의 sync-options는 Application syncPolicy와 별개로 적용된다. Replace=true·Force=true는
# Gateway를 지우고 다시 만들 수 있다(UID 변경 → Certificate cascade 삭제).
gateway_sync_options = gw.dig("metadata", "annotations", "argocd.argoproj.io/sync-options").to_s.split(",").map(&:strip)
forbidden_sync_options = gateway_sync_options & ["Replace=true", "Force=true"]
unless forbidden_sync_options.empty?
  raise "[안전] Gateway persona-app에 삭제·재생성을 일으키는 sync-options가 있다: #{forbidden_sync_options}"
end

raise "[안전] Gateway는 Traefik이 처리한다" unless gw.dig("spec", "gatewayClassName") == "traefik"
listeners = gw.dig("spec", "listeners") || []
raise "[안전] Gateway listener는 http·https 두 개여야 한다: #{listeners.length}개" unless listeners.length == 2
http_listener, https_listener = listeners
raise "[안전] listener[0]은 Traefik HTTP entryPoint 8000이다" unless http_listener["name"] == "http" && http_listener["protocol"] == "HTTP" && http_listener["port"] == 8000
raise "[안전] http listener에 확정되지 않은 접속 주소를 넣지 않는다" if http_listener.key?("hostname")
raise "[안전] listener[1]은 https여야 한다" unless https_listener["name"] == "https" && https_listener["protocol"] == "HTTPS" && https_listener["port"] == 8443
raise "[안전] https listener hostname이 공개 진입 도메인과 다르다" unless https_listener["hostname"] == PUBLIC_HOST
raise "[안전] https listener는 TLS를 종료해야 한다" unless https_listener.dig("tls", "mode") == "Terminate"
raise "[안전] https listener certificateRef가 persona-app-tls가 아니다" unless https_listener.dig("tls", "certificateRefs", 0) == { "kind" => "Secret", "name" => "persona-app-tls" }
listeners.each do |listener|
  # 다른 namespace의 Route가 붙으면 공개 주소를 그 namespace가 가져갈 수 있다.
  raise "[안전] #{listener["name"]} listener allowedRoutes는 Same이어야 한다" unless listener.dig("allowedRoutes", "namespaces", "from") == "Same"
end

# spec 지문은 위 listener별 검사가 보지 않는 필드까지 잡는 최종 안전망이라 마지막에 본다.
gateway_spec_json = JSON.generate(canonical.call(gw.fetch("spec")))
unless Digest::SHA256.hexdigest(gateway_spec_json) == GATEWAY_SPEC_SHA256
  raise "[안전] Gateway spec이 이관 전(origin/develop ccc014c)과 다르다 — spec 변경은 별도로 다룬다. 현재 spec: #{gateway_spec_json}"
end

# --- 준비 중 페이지 ----------------------------------------------------------------
maintenance = load(maintenance_path)
raise "[안전] maintenance-page 렌더에 Gateway가 있으면 안 된다 — public-gateway가 소유한다" if maintenance.any? { |i| i["kind"] == "Gateway" }
maintenance.each do |item|
  raise "[안전] maintenance-page 리소스는 persona-app namespace여야 한다: #{item["kind"]}/#{item.dig("metadata", "name")}" unless item.dig("metadata", "namespace") == "persona-app"
  raise "[안전] maintenance-page에 Namespace를 넣지 않는다 — bootstrap이 소유한다" if item["kind"] == "Namespace"
  # persona 리소스와 이름이 겹치면 정리 순서 동안 두 Application이 같은 객체를 추적한다.
  name = item.dig("metadata", "name").to_s
  raise "[안전] maintenance-page 리소스 이름은 maintenance-/-maintenance를 붙인다: #{item["kind"]}/#{name}" unless name.include?("maintenance")
  if item["kind"] == "Service"
    raise "[안전] maintenance-page Service는 ClusterIP여야 한다" unless (item.dig("spec", "type") || "ClusterIP") == "ClusterIP"
  end
end

public_route = resource(maintenance, "HTTPRoute", "public-maintenance")
raise "[안전] public-maintenance는 Gateway persona-app https listener에 붙어야 한다" unless public_route.dig("spec", "parentRefs") == [{ "name" => "persona-app", "sectionName" => "https" }]
raise "[안전] public-maintenance hostname이 공개 진입 도메인과 다르다" unless public_route.dig("spec", "hostnames") == [PUBLIC_HOST]
internal_route = resource(maintenance, "HTTPRoute", "internal-maintenance")
raise "[안전] internal-maintenance는 Gateway persona-app http listener에 붙어야 한다" unless internal_route.dig("spec", "parentRefs") == [{ "name" => "persona-app", "sectionName" => "http" }]
raise "[안전] internal-maintenance에 hostname을 넣으면 Serve·IP 접근이 끊긴다" if internal_route.dig("spec", "hostnames")
[public_route, internal_route].each do |route|
  route.dig("spec", "rules").each do |rule|
    raise "[안전] #{route.dig("metadata", "name")}: backend는 maintenance-page:8080 하나여야 한다" unless rule["backendRefs"] == [{ "name" => "maintenance-page", "port" => 8080 }]
  end
end
public_filters = public_route.dig("spec", "rules").flat_map { |rule| (rule["filters"] || []).map { |f| f.dig("extensionRef", "name") } }
raise "[기준선] public-maintenance는 maintenance-security-headers를 거친다" unless public_filters == ["maintenance-security-headers"]

deployment = resource(maintenance, "Deployment", "maintenance-page")
pod = deployment.dig("spec", "template", "spec")
container = pod.fetch("containers").fetch(0)
raise "[안전] maintenance-page 이미지는 digest로 고정한다(태그 금지)" unless container["image"] =~ /\Adocker\.io\/nginxinc\/nginx-unprivileged@sha256:[0-9a-f]{64}\z/
security = container["securityContext"] || {}
raise "[안전] maintenance-page는 root가 아닌 사용자로 돈다" unless security["runAsNonRoot"] == true
raise "[안전] maintenance-page 루트 파일시스템은 읽기 전용이다" unless security["readOnlyRootFilesystem"] == true
raise "[안전] maintenance-page는 권한 상승을 막는다" unless security["allowPrivilegeEscalation"] == false
raise "[안전] maintenance-page capability는 모두 버린다" unless security.dig("capabilities", "drop") == ["ALL"]
raise "[안전] maintenance-page에 ServiceAccount 토큰을 마운트하지 않는다" unless pod["automountServiceAccountToken"] == false
raise "[기준선] maintenance-page 자원 limits가 없다" unless container.dig("resources", "limits", "memory")

deny = resource(maintenance, "NetworkPolicy", "maintenance-default-deny")
raise "[안전] maintenance-default-deny는 namespace 전체 Ingress·Egress를 막아야 한다" unless deny.dig("spec", "podSelector") == {} && deny.dig("spec", "policyTypes")&.sort == %w[Egress Ingress]
allow = resource(maintenance, "NetworkPolicy", "maintenance-allow-traefik")
allow_from = allow.dig("spec", "ingress").flat_map { |rule| (rule["from"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }
raise "[안전] maintenance-page는 traefik에서만 들어온다" unless allow_from == ["traefik"]
raise "[안전] maintenance-allow-traefik에 Egress를 열지 않는다" if (allow.dig("spec", "policyTypes") || []).include?("Egress")

# --- 지킬 대상: persona-edge(DDNS) -----------------------------------------------------
# persona 폐기와 함께 지워지면 안 된다. DDNS가 멈추면 공개 주소가 엉뚱한 IP를 가리킨다.
edge = load(edge_path)
resource(edge, "CronJob", "ddns-update")
raise "[안전] persona-edge 렌더는 persona-edge namespace여야 한다" unless edge.all? { |item| item.dig("metadata", "namespace") == "persona-edge" }

# --- 지킬 대상: namespace -------------------------------------------------------------
# Gateway와 TLS Secret이 이 namespace에 있다. 선언이 빠지면 namespace 정리로 번질 수 있다.
namespace = YAML.load_file(ns_app_path)
raise "[안전] bootstrap persona-app Namespace 선언이 다르다" unless namespace["kind"] == "Namespace" && namespace.dig("metadata", "name") == "persona-app"

# --- Argo Application ------------------------------------------------------------------
{
  "public-gateway" => ["kustomize/overlays/prod/public-gateway", "persona-app"],
  "maintenance-page" => ["kustomize/overlays/prod/maintenance-page", "persona-app"],
  "persona-edge" => ["kustomize/overlays/prod/persona-edge", "persona-edge"],
}.each do |name, (source_path, target_namespace)|
  path = File.join(argocd_dir, "#{name}.yaml")
  raise "[안전] #{name} Application 선언(#{path})이 없다" unless File.exist?(path)
  application = YAML.load_file(path)
  raise "[안전] #{name}: Application kind가 아니다" unless application["kind"] == "Application"
  raise "[안전] #{name}: 이름이 다르다" unless application.dig("metadata", "name") == name
  spec = application.fetch("spec")
  raise "[안전] #{name}: develop 브랜치를 봐야 한다" unless spec.dig("source", "targetRevision") == "develop"
  raise "[안전] #{name}: source path가 다르다" unless spec.dig("source", "path") == source_path
  raise "[안전] #{name}: 대상 namespace가 다르다" unless spec.dig("destination", "namespace") == target_namespace
  raise "[안전] #{name}: 자동 Sync를 켜면 안 된다" if spec.key?("syncPolicy")
  # Application 삭제가 관리 리소스 삭제로 이어지는 finalizer를 두지 않는다(Gateway → Certificate 연쇄 삭제).
  raise "[안전] #{name} Application에 finalizers를 두지 않는다 — Application 삭제가 리소스 삭제로 번진다" unless application.dig("metadata", "finalizers").nil?
end

# 이름을 아는 Application만 보면 새 Application을 빠뜨린다. argocd/ 전체에서 자동 Sync만 좁혀 막는다.
Dir.glob(File.join(argocd_dir, "*.yaml")).sort.each do |path|
  application = YAML.load_file(path)
  next unless application.is_a?(Hash) && application["kind"] == "Application"
  name = application.dig("metadata", "name") || File.basename(path, ".yaml")
  raise "[안전] #{name}(#{path}): syncPolicy.automated를 켜면 안 된다(자동 Sync·prune 금지)" unless application.dig("spec", "syncPolicy", "automated").nil?
end

puts "공개 Gateway·준비 중 페이지·persona-edge·Argo Application 렌더와 정책 검사 통과"
RUBY
