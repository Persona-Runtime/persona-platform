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

# persona-app·persona-db는 이제 NetworkPolicy를 안 갖는다 — Sync 분리(2026-09-19)로
# 각각 persona-app-netpol·persona-db-netpol이 관리한다(argocd/README.md 참고).
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-app-netpol"      > "$app_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-db-netpol"       > "$data_file"
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

# 내부 순서 고정(2026-09-19): allow-*(wave 0) → default-deny(wave 1). 허용 규칙이 먼저
# 들어가야 차단이 걸리는 순간에도 기존 통신이 안 끊긴다. persona-app·persona-data만
# 대상이다(persona-edge·traefik은 이번에 안 건드림).
def check_sync_wave(policy, expected, context)
  actual = policy.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave")
  raise "[안전] #{context}: sync-wave가 #{expected}가 아니다(실제: #{actual.inspect})" unless actual == expected
end

# --- persona-app -------------------------------------------------------------
app = load(app_path)
check_default_deny(app, "persona-app")
check_sync_wave(resource(app, "NetworkPolicy", "default-deny"), "1", "persona-app default-deny")

web = resource(app, "NetworkPolicy", "allow-web")
check_sync_wave(web, "0", "persona-app allow-web")
raise "[안전] allow-web: Egress policyType을 두면 안 된다 — 이 컴포넌트는 egress 없음" if web.dig("spec", "policyTypes")&.include?("Egress")
raise "[안전] allow-web: traefik에서만 인입해야 한다" unless rule_from_namespaces(web.dig("spec", "ingress", 0)) == ["traefik"]
raise "[안전] allow-web: 포트가 8080이 아니다" unless rule_ports(web.dig("spec", "ingress", 0)) == [["TCP", 8080]]

gw = resource(app, "NetworkPolicy", "allow-gateway")
check_sync_wave(gw, "0", "persona-app allow-gateway")
raise "[안전] allow-gateway: traefik에서만 인입해야 한다" unless rule_from_namespaces(gw.dig("spec", "ingress", 0)) == ["traefik"]
gw_egress_targets = gw.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") || peer.dig("podSelector", "matchLabels", "app.kubernetes.io/name") } }
raise "[안전] allow-gateway egress 대상이 다르다(persona-data·persona-embedding·kube-system이어야 한다)" unless gw_egress_targets.sort == %w[kube-system persona-data persona-embedding].sort

embedding = resource(app, "NetworkPolicy", "allow-embedding")
check_sync_wave(embedding, "0", "persona-app allow-embedding")
raise "[안전] allow-embedding: Egress policyType을 두면 안 된다 — 이 컴포넌트는 egress 없음(오프라인 모델)" if embedding.dig("spec", "policyTypes")&.include?("Egress")
embedding_sources = embedding.dig("spec", "ingress").flat_map { |rule| (rule["from"] || []).map { |peer| peer.dig("podSelector", "matchLabels", "app.kubernetes.io/name") } }.compact
raise "[안전] allow-embedding: persona-gateway Pod에서만 인입해야 한다" unless embedding_sources == ["persona-gateway"]
raise "[안전] allow-embedding: 포트가 8081이 아니다" unless rule_ports(embedding.dig("spec", "ingress", 0)) == [["TCP", 8081]]

migrate = resource(app, "NetworkPolicy", "allow-migrate")
check_sync_wave(migrate, "0", "persona-app allow-migrate")
raise "[안전] allow-migrate: Ingress policyType을 두면 안 된다 — Job은 인바운드를 받지 않는다" if migrate.dig("spec", "policyTypes")&.include?("Ingress")
migrate_egress_targets = migrate.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }
raise "[안전] allow-migrate egress 대상이 다르다(persona-data·kube-system이어야 한다)" unless migrate_egress_targets.sort == %w[kube-system persona-data]

# --- persona-data --------------------------------------------------------------
data = load(data_path)
check_default_deny(data, "persona-data")
check_sync_wave(resource(data, "NetworkPolicy", "default-deny"), "1", "persona-data default-deny")

db_in = resource(data, "NetworkPolicy", "allow-db-ingress")
check_sync_wave(db_in, "0", "persona-data allow-db-ingress")
db_in_sources = db_in.dig("spec", "ingress").flat_map { |rule| (rule["from"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }.uniq
raise "[안전] persona-db ingress 출처가 다르다(persona-app·cnpg-system·monitoring이어야 한다)" unless db_in_sources.sort == %w[cnpg-system monitoring persona-app].sort

db_egress = resource(data, "NetworkPolicy", "allow-db-egress")
check_sync_wave(db_egress, "0", "persona-data allow-db-egress")
db_egress_targets = db_egress.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }.uniq
raise "[안전] persona-db egress 대상이 다르다(kube-system·cnpg-system이어야 한다)" unless db_egress_targets.sort == %w[cnpg-system kube-system]

replication = resource(data, "NetworkPolicy", "allow-db-replication")
check_sync_wave(replication, "0", "persona-data allow-db-replication")
raise "[안전] 복제 정책은 Ingress·Egress 둘 다 있어야 한다(양방향 스트리밍 복제)" unless replication.dig("spec", "policyTypes")&.sort == %w[Egress Ingress]
raise "[안전] 복제 ingress가 같은 Cluster Pod(cnpg.io/cluster: persona-db)를 셀렉트하지 않는다" unless replication.dig("spec", "ingress", 0, "from", 0, "podSelector", "matchLabels") == { "cnpg.io/cluster" => "persona-db" }
# 5432=스트리밍 복제, 8000=CNPG instance manager 상태 조회(인스턴스↔인스턴스, 2026-09-20
# Hubble 실측 — 8000 없이는 Policy denied DROPPED가 반복됐다). ingress·egress 둘 다 확인해
# 한쪽만 고치고 다른 쪽을 빠뜨리는 것을 잡는다.
raise "[안전] 복제 ingress 포트가 5432·8000이 아니다" unless rule_ports(replication.dig("spec", "ingress", 0)).sort == [["TCP", 5432], ["TCP", 8000]]
raise "[안전] 복제 egress가 같은 Cluster Pod(cnpg.io/cluster: persona-db)를 셀렉트하지 않는다" unless replication.dig("spec", "egress", 0, "to", 0, "podSelector", "matchLabels") == { "cnpg.io/cluster" => "persona-db" }
raise "[안전] 복제 egress 포트가 5432·8000이 아니다" unless rule_ports(replication.dig("spec", "egress", 0)).sort == [["TCP", 5432], ["TCP", 8000]]

# CNPG instance manager가 Cluster status·Secret/ConfigMap·승격 판단·readiness에
# kube-apiserver를 직접 호출한다(cnpg-system:8000 — operator↔instance manager 상태
# 포트 — 와는 별개 경로다). 이게 없으면 지금 운영 중인 CNPG 2 인스턴스의 failover가
# 불가능해진다(리뷰 차단 사유).
db_apiserver = resource(data, "CiliumNetworkPolicy", "allow-egress-kube-apiserver")
check_sync_wave(db_apiserver, "0", "persona-data allow-egress-kube-apiserver")
raise "[안전] persona-db endpointSelector가 cnpg.io/cluster: persona-db가 아니다" unless db_apiserver.dig("spec", "endpointSelector", "matchLabels") == { "cnpg.io/cluster" => "persona-db" }
raise "[안전] persona-db의 kube-apiserver egress가 예약 엔티티 kube-apiserver를 쓰지 않는다(하드코딩 IP는 노드 교체 때 끊긴다)" unless db_apiserver.dig("spec", "egress", 0, "toEntities") == ["kube-apiserver"]
raise "[안전] persona-db의 kube-apiserver egress 포트가 6443이 아니다" unless db_apiserver.dig("spec", "egress", 0, "toPorts", 0, "ports", 0, "port") == "6443"

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

# allow-ingress-world(표준 NetworkPolicy, ipBlock 0.0.0.0/0)는 Cilium에서 world
# 아이덴티티만 매칭하고 클러스터 노드 자신에서 나온 트래픽(remote-node·host)은 안
# 걸린다(2026-09-20 실측 — CP curl 000, 맥 302) — 그 경로를 이 CiliumNetworkPolicy가
# 별도로 연다.
cluster_nodes = resource(traefik, "CiliumNetworkPolicy", "allow-ingress-cluster-nodes")
raise "[안전] traefik의 클러스터 노드 인입이 host·remote-node 엔티티를 쓰지 않는다" unless cluster_nodes.dig("spec", "ingress", 0, "fromEntities")&.sort == %w[host remote-node]
# rule_ports는 표준 NetworkPolicy의 flat ingress[].ports[] 모양만 본다 — Cilium은
# ingress[].toPorts[].ports[]로 한 단계 더 감싸고 port 값도 문자열이라(apiserver 검사와
# 같은 이유) 직접 파고든다.
cluster_nodes_ports = (cluster_nodes.dig("spec", "ingress", 0, "toPorts", 0, "ports") || []).map { |p| [p["protocol"], p["port"]] }
raise "[안전] traefik 클러스터 노드 인입 포트가 8000·8443이 아니다" unless cluster_nodes_ports.sort == [["TCP", "8000"], ["TCP", "8443"]]

# monitoring이 PodMonitor로 traefik metrics 포트(9100, Service엔 없고 Pod에만 있다)를
# 직접 스크레이프한다 — persona-data의 monitoring → postgres-exporter:9187과 같은 패턴
# (2026-09-20 실측: 이 허용 없이는 Prometheus 타깃 traefik/traefik이 down).
metrics = resource(traefik, "NetworkPolicy", "allow-ingress-metrics")
raise "[안전] traefik 메트릭 인입이 monitoring에서만 오지 않는다" unless rule_from_namespaces(metrics.dig("spec", "ingress", 0)) == ["monitoring"]
raise "[안전] traefik 메트릭 인입 포트가 9100이 아니다" unless rule_ports(metrics.dig("spec", "ingress", 0)) == [["TCP", 9100]]

puts "networkpolicy(persona-app·persona-data·persona-edge·traefik) 렌더와 매니페스트 정책 검사 통과"
RUBY
