#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 결함을 넣어 validate-public-gateway-manifests.sh가 실패하는지 확인한다.
# persona 폐기(2026-10-07) 뒤에도 공개 Gateway·TLS·persona-edge가 남아 있어야 한다는 것을 지키는 음성 테스트다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/public-gateway-test.XXXXXX")
# 이 실행이 만든 복사본만 제거하며 원본·클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$repo_dir/bootstrap" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-public-gateway-manifests.sh" "$test_dir/scripts/"
# 깨끗한 복사본은 먼저 통과해야 한다. 아니면 아래 실패가 결함 때문인지 알 수 없다.
sh "$test_dir/scripts/validate-public-gateway-manifests.sh" > /dev/null

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
#
# 매직 코멘트는 이 heredoc 소스의 인코딩, 아래 대입은 한글이 든 매니페스트를 File.read·File.write로
# 다룰 때의 외부 인코딩을 고정한다(로케일이 UTF-8이 아닌 환경 대비).
Encoding.default_external = Encoding::UTF_8

root = ARGV.fetch(0)
DELETE_KEY = :delete_key
DELETE_FILE = :delete_file
GATEWAY = "kustomize/overlays/prod/public-gateway/gateway.yaml"
MAINTENANCE_ROUTE = "kustomize/overlays/prod/maintenance-page/httproute.yaml"
MAINTENANCE_DEPLOYMENT = "kustomize/base/maintenance-page/deployment.yaml"
MAINTENANCE_NETPOL = "kustomize/overlays/prod/maintenance-page/network-policy.yaml"
PUBLIC = { "kind" => "HTTPRoute", "name" => "public-maintenance" }
INTERNAL = { "kind" => "HTTPRoute", "name" => "internal-maintenance" }

# [파일, 문서 선택(kind·name, 단일 문서면 nil), 키 경로, 값(DELETE_KEY·DELETE_FILE 포함), 기대 메시지 일부]
cases = [
  # 지킬 대상이 사라지는 경우 — Gateway·TLS·edge
  ["argocd/public-gateway.yaml", nil, nil, DELETE_FILE, "public-gateway Application 선언"],
  [GATEWAY, nil, nil, DELETE_FILE, "kustomize"],
  [GATEWAY, nil, ["metadata", "name"], "persona-app-v2", "Gateway persona-app/persona-app 선언은 public-gateway 하나여야 한다"],
  [GATEWAY, nil, ["spec", "listeners", 1], DELETE_KEY, "listener는 http·https 두 개"],
  [GATEWAY, nil, ["spec", "listeners", 1, "tls", "certificateRefs"], DELETE_KEY, "certificateRef가 persona-app-tls가 아니다"],
  [GATEWAY, nil, ["metadata", "annotations", "cert-manager.io/cluster-issuer"], DELETE_KEY, "cert-manager annotation이 다르다"],
  [GATEWAY, nil, ["metadata", "annotations", "argocd.argoproj.io/sync-options"], "Replace=true", "삭제·재생성을 일으키는 sync-options"],
  [GATEWAY, nil, ["spec", "listeners", 0, "allowedRoutes", "namespaces", "from"], "All", "allowedRoutes는 Same"],
  # 개별 검사가 보지 않는 필드(허용 Route 종류)는 spec 지문이 잡는다.
  [GATEWAY, nil, ["spec", "listeners", 1, "allowedRoutes", "kinds"], [{ "kind" => "TLSRoute" }], "Gateway spec이 이관 전"],
  ["argocd/public-gateway.yaml", nil, ["metadata", "finalizers"], ["resources-finalizer.argocd.argoproj.io"], "finalizers를 두지 않는다"],
  ["argocd/public-gateway.yaml", nil, ["spec", "syncPolicy"], { "automated" => { "prune" => true } }, "자동 Sync"],
  ["bootstrap/namespaces/persona-app.yaml", nil, nil, DELETE_FILE, "persona-app.yaml"],
  ["argocd/persona-edge.yaml", nil, nil, DELETE_FILE, "persona-edge Application 선언"],
  ["kustomize/base/ddns/cronjob.yaml", nil, ["metadata", "name"], "ddns-renamed", "CronJob/ddns-update 선언이 없다"],
  # 준비 중 페이지가 공개 주소에 제대로 붙지 않는 경우
  ["argocd/maintenance-page.yaml", nil, nil, DELETE_FILE, "maintenance-page Application 선언"],
  [MAINTENANCE_ROUTE, PUBLIC, ["spec", "parentRefs", 0, "sectionName"], "http", "https listener에 붙어야 한다"],
  [MAINTENANCE_ROUTE, PUBLIC, ["spec", "hostnames"], ["example.invalid"], "hostname이 공개 진입 도메인과 다르다"],
  [MAINTENANCE_ROUTE, INTERNAL, ["spec", "hostnames"], ["app.personaruntime.xyz"], "Serve·IP 접근이 끊긴다"],
  [MAINTENANCE_ROUTE, INTERNAL, ["spec", "rules", 0, "backendRefs", 0, "name"], "persona-web", "maintenance-page:8080 하나"],
  # 공개 Route(mafest) — 허용 외 backend·필터, 스트림 buffering, 허용 외 경로, 중복 Route
  [MAINTENANCE_ROUTE, PUBLIC, ["spec", "rules", 0, "backendRefs", 0, "name"], "persona-web", "mafest-app의 mafest-api:8000 하나"],
  [MAINTENANCE_ROUTE, PUBLIC, ["spec", "rules", 0, "filters", 1, "extensionRef", "name"], "oauth-forward", "승인된 mafest Middleware만"],
  [MAINTENANCE_ROUTE, PUBLIC, ["spec", "rules", 0, "filters", 1, "extensionRef", "name"], "mafest-body-limit", "승인된 mafest Middleware만"],
  [MAINTENANCE_ROUTE, PUBLIC, ["spec", "rules", 0, "matches", 0, "path", "value"], "/metrics", "POST PathPrefix /v1/search 한 규칙"],
  ["kustomize/overlays/prod/maintenance-page/middlewares.yaml", { "kind" => "Middleware", "name" => "mafest-search-rate-limit" },
   ["spec", "rateLimit", "sourceCriterion", "ipStrategy"], { "depth" => 1 }, "접속 IP(ipStrategy depth 0)"],
  ["kustomize/overlays/prod/maintenance-page/middlewares.yaml", { "kind" => "Middleware", "name" => "mafest-search-rate-limit" },
   ["spec", "rateLimit", "average"], 60, "승인 계약은 평균 6/1m"],
  ["kustomize/base/mafest-app/referencegrant-public.yaml", nil, ["spec", "to"],
   [{ "group" => "", "kind" => "Service", "name" => "mafest-api" }, { "group" => "", "kind" => "Service", "name" => "mafest-web" }, { "group" => "", "kind" => "Service", "name" => "mafest-db" }], "Service mafest-api·mafest-web 두 개뿐"],
  [MAINTENANCE_DEPLOYMENT, nil, ["spec", "template", "spec", "containers", 0, "image"], "docker.io/nginxinc/nginx-unprivileged:latest", "digest로 고정"],
  [MAINTENANCE_DEPLOYMENT, nil, ["spec", "template", "spec", "containers", 0, "securityContext", "readOnlyRootFilesystem"], false, "읽기 전용"],
  [MAINTENANCE_NETPOL, { "kind" => "NetworkPolicy", "name" => "maintenance-allow-traefik" },
   ["spec", "ingress", 0, "from", 0, "namespaceSelector", "matchLabels", "kubernetes.io/metadata.name"], "monitoring", "traefik에서만"],
]

def select_document(documents, selector)
  return documents.fetch(0) if selector.nil?
  documents.find { |doc| doc["kind"] == selector["kind"] && doc.dig("metadata", "name") == selector["name"] } ||
    raise("사례 문서를 찾지 못했다: #{selector}")
end

cases.each do |relative_path, selector, keys, value, message|
  path = File.join(root, relative_path)
  raise "사례 파일이 없다: #{relative_path}" unless File.exist?(path)
  original = File.read(path)
  begin
    if value == DELETE_FILE
      File.delete(path)
    else
      documents = YAML.load_stream(original).compact
      document = select_document(documents, selector)
      parent = keys[0...-1].reduce(document) { |node, key| node.fetch(key) }
      if value == DELETE_KEY
        parent.is_a?(Array) ? parent.delete_at(keys.last) : parent.delete(keys.last)
      else
        parent[keys.last] = value
      end
      File.write(path, documents.map { |doc| YAML.dump(doc) }.join)
    end
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-public-gateway-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end
puts "공개 Gateway 음성 테스트 #{cases.length}건 통과"
RUBY
