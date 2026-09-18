#!/bin/sh

set -eu

# Gate 4 §3 NetworkPolicy(persona-app·persona-data·persona-edge·traefik) 선언이 합의한
# 계약을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
# scripts/validate-persona-app-manifests.sh와 같은 패턴([안전] 태그, kubectl kustomize
# 렌더 + ruby 검사)을 쓴다.
#
# 이 스크립트는 "네임스페이스마다 default-deny 정확히 1개 + policyTypes 둘 다"라는
# 안전 하한선과, 문서화한 허용 규칙의 모양(누가 누구에게 어느 포트로)을 확인한다.
# 클러스터가 없으므로 정책이 실제로 반영·시행되는지는 검사 범위 밖이다(런북에 별도 명시).

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
app_file=$(mktemp "${TMPDIR:-/tmp}/persona-app.XXXXXX.yaml")
data_file=$(mktemp "${TMPDIR:-/tmp}/persona-data.XXXXXX.yaml")
edge_file=$(mktemp "${TMPDIR:-/tmp}/persona-edge.XXXXXX.yaml")
traefik_file=$(mktemp "${TMPDIR:-/tmp}/traefik.XXXXXX.yaml")
trap 'rm -f "$app_file" "$data_file" "$edge_file" "$traefik_file"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-app"             > "$app_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-db"              > "$data_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-edge"            > "$edge_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/traefik-networkpolicy"   > "$traefik_file"

ruby -ryaml - "$app_file" "$data_file" "$edge_file" "$traefik_file" <<'RUBY'
Encoding.default_external = Encoding::UTF_8

app_path, data_path, edge_path, traefik_path = ARGV

def load(path)
  YAML.load_stream(File.read(path)).compact
end

def resources(all, kind, name)
  found = all.select { |item| item["kind"] == kind && item.dig("metadata", "name") == name }
  raise "missing #{kind}/#{name}" if found.empty?
  found
end

def resource(all, kind, name)
  resources(all, kind, name).first
end

def ns(name)
  { "kubernetes.io/metadata.name" => name }
end

# 네임스페이스마다 default-deny가 정확히 1개, podSelector가 전체({}), Ingress·Egress
# 둘 다 policyTypes에 있어야 한다 — 이게 이 검사 전체의 안전 하한선이다. 다른 개별 허용
# 규칙이 틀려도 이 하나가 지켜지면 "뚫린 채로 방치"는 아니다.
def check_default_deny(all, context)
  policy = resource(all, "NetworkPolicy", "default-deny")
  raise "[안전] #{context} default-deny: podSelector가 네임스페이스 전체(빈 값)가 아니다" unless policy.dig("spec", "podSelector") == {}
  raise "[안전] #{context} default-deny: policyTypes에 Ingress·Egress 둘 다 있어야 한다" unless policy.dig("spec", "policyTypes")&.sort == %w[Egress Ingress]
end

def rule_from_namespaces(rule)
  (rule["from"] || rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") }.compact
end

def rule_ports(rule)
  (rule["ports"] || []).map { |p| [p["protocol"], p["port"]] }
end

# --- persona-app -------------------------------------------------------------
app = load(app_path)
check_default_deny(app, "persona-app")

web = resource(app, "NetworkPolicy", "allow-web")
raise "[안전] allow-web: Egress policyType을 두면 안 된다 — 이 컴포넌트는 egress 없음" if web.dig("spec", "policyTypes")&.include?("Egress")
raise "[안전] allow-web: traefik에서만 인입해야 한다" unless rule_from_namespaces(web.dig("spec", "ingress", 0)) == ["traefik"]
raise "[안전] allow-web: 포트가 8080이 아니다" unless rule_ports(web.dig("spec", "ingress", 0)) == [["TCP", 8080]]

gw = resource(app, "NetworkPolicy", "allow-gateway")
raise "[안전] allow-gateway: traefik에서만 인입해야 한다" unless rule_from_namespaces(gw.dig("spec", "ingress", 0)) == ["traefik"]
gw_egress_targets = gw.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") || peer.dig("podSelector", "matchLabels", "app.kubernetes.io/name") } }
raise "[안전] allow-gateway egress 대상이 다르다(persona-data·persona-embedding·kube-system이어야 한다)" unless gw_egress_targets.sort == %w[kube-system persona-data persona-embedding].sort

migrate = resource(app, "NetworkPolicy", "allow-migrate")
raise "[안전] allow-migrate: Ingress policyType을 두면 안 된다 — Job은 인바운드를 받지 않는다" if migrate.dig("spec", "policyTypes")&.include?("Ingress")
migrate_egress_targets = migrate.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }
raise "[안전] allow-migrate egress 대상이 다르다(persona-data·kube-system이어야 한다)" unless migrate_egress_targets.sort == %w[kube-system persona-data]

# --- persona-data --------------------------------------------------------------
data = load(data_path)
check_default_deny(data, "persona-data")

db_in = resource(data, "NetworkPolicy", "allow-db-ingress")
db_in_sources = db_in.dig("spec", "ingress").flat_map { |rule| (rule["from"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }.uniq
raise "[안전] persona-db ingress 출처가 다르다(persona-app·cnpg-system·monitoring이어야 한다)" unless db_in_sources.sort == %w[cnpg-system monitoring persona-app].sort

db_egress = resource(data, "NetworkPolicy", "allow-db-egress")
db_egress_targets = db_egress.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }.uniq
raise "[안전] persona-db egress 대상이 다르다(kube-system·cnpg-system이어야 한다)" unless db_egress_targets.sort == %w[cnpg-system kube-system]

replication = resource(data, "NetworkPolicy", "allow-db-replication")
raise "[안전] 복제 정책은 Ingress·Egress 둘 다 있어야 한다(양방향 스트리밍 복제)" unless replication.dig("spec", "policyTypes")&.sort == %w[Egress Ingress]
raise "[안전] 복제 ingress가 같은 Cluster Pod(cnpg.io/cluster: persona-db)를 셀렉트하지 않는다" unless replication.dig("spec", "ingress", 0, "from", 0, "podSelector", "matchLabels") == { "cnpg.io/cluster" => "persona-db" }
raise "[안전] 복제 포트가 5432가 아니다" unless rule_ports(replication.dig("spec", "ingress", 0)) == [["TCP", 5432]]

# --- persona-edge ----------------------------------------------------------------
edge = load(edge_path)
check_default_deny(edge, "persona-edge")

oauth_in = resource(edge, "NetworkPolicy", "allow-oauth2-proxy-ingress")
raise "[안전] oauth2-proxy는 traefik에서만 인입해야 한다" unless rule_from_namespaces(oauth_in.dig("spec", "ingress", 0)) == ["traefik"]
raise "[안전] oauth2-proxy ingress 포트가 4180이 아니다" unless rule_ports(oauth_in.dig("spec", "ingress", 0)) == [["TCP", 4180]]

# CiliumNetworkPolicy(toFQDNs)만 도메인 이름 기반 egress를 표현할 수 있다 — 표준
# NetworkPolicy는 IP/CIDR만 다룬다(위 network-policy-fqdn.yaml 주석 참고).
oauth_fqdn = resource(edge, "CiliumNetworkPolicy", "allow-oauth2-proxy-fqdn")
oauth_domains = oauth_fqdn.dig("spec", "egress", 0, "toFQDNs").map { |f| f["matchName"] }
raise "[안전] oauth2-proxy FQDN 허용 목록이 다르다(github.com·api.github.com이어야 한다)" unless oauth_domains.sort == %w[api.github.com github.com]

ddns_fqdn = resource(edge, "CiliumNetworkPolicy", "allow-ddns-fqdn")
ddns_domains = ddns_fqdn.dig("spec", "egress", 0, "toFQDNs").map { |f| f["matchName"] }
raise "[안전] ddns FQDN 허용 목록이 다르다(api.cloudflare.com이어야 한다)" unless ddns_domains == ["api.cloudflare.com"]

ddns_ip = resource(edge, "NetworkPolicy", "allow-ddns-egress-public-ip-check")
raise "[안전] ddns 공인 IP 조회 대상이 1.1.1.1/32가 아니다" unless ddns_ip.dig("spec", "egress", 0, "to", 0, "ipBlock", "cidr") == "1.1.1.1/32"

# --- traefik ----------------------------------------------------------------------
traefik = load(traefik_path)
check_default_deny(traefik, "traefik")

world = resource(traefik, "NetworkPolicy", "allow-ingress-world")
raise "[안전] traefik 인입이 0.0.0.0/0(world)이 아니다" unless world.dig("spec", "ingress", 0, "from", 0, "ipBlock", "cidr") == "0.0.0.0/0"
raise "[안전] traefik 인입 포트가 8000·8443이 아니다(entrypoint 실제 포트, Service exposedPort 아님)" unless rule_ports(world.dig("spec", "ingress", 0)).sort == [["TCP", 8000], ["TCP", 8443]]

backend_egress = resource(traefik, "NetworkPolicy", "allow-egress-backends")
backend_targets = backend_egress.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }.uniq
raise "[안전] traefik egress 대상이 다르다(persona-app·persona-edge·persona-mock-sse·kube-system이어야 한다)" unless backend_targets.sort == %w[kube-system persona-app persona-edge persona-mock-sse].sort

apiserver = resource(traefik, "CiliumNetworkPolicy", "allow-egress-kube-apiserver")
raise "[안전] traefik의 kube-apiserver egress가 예약 엔티티 kube-apiserver를 쓰지 않는다(하드코딩 IP는 노드 교체 때 끊긴다)" unless apiserver.dig("spec", "egress", 0, "toEntities") == ["kube-apiserver"]
raise "[안전] kube-apiserver egress 포트가 6443이 아니다" unless apiserver.dig("spec", "egress", 0, "toPorts", 0, "ports", 0, "port") == "6443"

puts "networkpolicy(persona-app·persona-data·persona-edge·traefik) 렌더와 매니페스트 정책 검사 통과"
RUBY
