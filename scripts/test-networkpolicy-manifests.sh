#!/bin/sh
# NetworkPolicy 선언의 복사본에 준비 중 페이지·Gateway → vLLM·Prometheus → vLLM 계약 위반을 하나씩 넣어
# validate-networkpolicy-manifests.sh가 실패하는지 확인한다. 원본 선언·클러스터는 바꾸지 않는다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-netpol-test.XXXXXX")
# 이 실행이 만든 복사본만 제거한다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-networkpolicy-manifests.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-networkpolicy-manifests.sh"

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
root = ARGV.fetch(0)
# persona-app namespace에는 준비 중 페이지 정책만 남았다(persona 폐기, 2026-10-07).
MNT = "kustomize/overlays/prod/maintenance-page/network-policy.yaml"
MFD = "kustomize/base/networkpolicy/mafest-data/network-policy.yaml"
TRAEFIK = "kustomize/base/networkpolicy/traefik/network-policy.yaml"
INF = "kustomize/base/networkpolicy/persona-inference/network-policy.yaml"

def ns_peer(name)
  { "namespaceSelector" => { "matchLabels" => { "kubernetes.io/metadata.name" => name } } }
end

def pod_peer(labels)
  { "podSelector" => { "matchLabels" => labels } }
end

GATEWAY = { "app.kubernetes.io/name" => "persona-gateway" }
PROMETHEUS = { "app.kubernetes.io/name" => "prometheus", "app.kubernetes.io/instance" => "monitoring-stack-kube-prom-prometheus" }

# [파일, 정책 이름, 복사본을 바꾸는 함수, 기대 오류 문구]
cases = [
  # mafest-data — API·loader는 같은 peer AND, Prometheus만 9187, 복제 5432·8000, deny는 마지막 wave
  [MFD, "mafest-allow-db-ingress", ->(p) { p.dig("spec", "ingress", 0)["from"] = [ns_peer("mafest-app"), pod_peer({ "app.kubernetes.io/name" => "mafest-api" })] },
   "mafest-db 5432는 mafest-app의 mafest-api·mafest-loader Pod"],
  [MFD, "mafest-allow-db-ingress", ->(p) { p.dig("spec", "ingress", 2)["from"] = [ns_peer("monitoring")] },
   "Prometheus → mafest-db exporter"],
  [MFD, "mafest-allow-db-replication", ->(p) { p.dig("spec", "ingress", 0)["ports"].pop },
   "복제 ingress 포트는 5432(WAL)·8000"],
  [MFD, "mafest-default-deny", ->(p) { p.dig("metadata", "annotations")["argocd.argoproj.io/sync-wave"] = "0" },
   "mafest-default-deny: sync-wave가 1"],
  # traefik — 정리한 persona-mock-sse로 다시 나가지 않는다
  [TRAEFIK, "allow-egress-backends", ->(p) { p.dig("spec", "egress", 0, "to") << ns_peer("persona-mock-sse") },
   "traefik egress 대상이 다르다"],
  # 준비 중 페이지(persona-app) — traefik 8080만 들어오고, 나가는 길은 없다
  [MNT, "maintenance-allow-traefik", ->(p) { p.dig("spec", "ingress", 0)["from"] = [ns_peer("monitoring")] },
   "준비 중 페이지는 traefik에서만 인입해야 한다"],
  [MNT, "maintenance-allow-traefik", ->(p) { p.dig("spec", "ingress", 0)["ports"] = [{ "protocol" => "TCP", "port" => 8081 }] },
   "준비 중 페이지 인입 포트가 8080이 아니다"],
  [MNT, "maintenance-allow-traefik", ->(p) { p["spec"]["egress"] = [{ "to" => [ns_peer("kube-system")], "ports" => [{ "protocol" => "UDP", "port" => 53 }] }] },
   "egress 허용을 두지 않는다"],
  [MNT, "maintenance-default-deny", ->(p) { p["spec"]["podSelector"] = { "matchLabels" => { "app.kubernetes.io/name" => "maintenance-page" } } },
   "default-deny: podSelector가 네임스페이스 전체"],
  # vLLM ingress from Gateway (persona-inference allow-vllm-gateway)
  [INF, "allow-vllm-gateway", ->(p) { p.dig("spec", "ingress", 0)["from"] = [ns_peer("persona-app")] },
   "Gateway → vLLM ingress: persona-app namespace AND"],
  [INF, "allow-vllm-gateway", ->(p) { p.dig("spec", "ingress", 0)["from"] = [ns_peer("persona-app"), pod_peer(GATEWAY)] },
   "Gateway → vLLM ingress: peer가 정확히 1개가 아니다"],
  # vLLM ingress from Prometheus (persona-inference allow-vllm-metrics)
  [INF, "allow-vllm-metrics", ->(p) { p.dig("spec", "ingress", 0)["from"] = [ns_peer("monitoring")] },
   "Prometheus → vLLM metrics ingress: monitoring namespace AND"],
  [INF, "allow-vllm-metrics", ->(p) { p.dig("spec", "ingress", 0)["from"] = [ns_peer("monitoring"), pod_peer(PROMETHEUS)] },
   "Prometheus → vLLM metrics ingress: peer가 정확히 1개가 아니다"],
  [INF, "allow-vllm-metrics", ->(p) { p.dig("spec", "ingress", 0, "from", 0, "podSelector", "matchLabels").delete("app.kubernetes.io/instance") },
   "Prometheus → vLLM metrics ingress: monitoring namespace AND"],
  [INF, "allow-vllm-metrics", ->(p) { p.dig("spec", "ingress", 0, "from", 0, "podSelector", "matchLabels")["app.kubernetes.io/name"] = "grafana" },
   "Prometheus → vLLM metrics ingress: monitoring namespace AND"],
  # vLLM egress는 DNS뿐
  [INF, "allow-vllm-dns", ->(p) { p.dig("spec", "egress") << { "to" => [ns_peer("persona-app")], "ports" => [{ "protocol" => "TCP", "port" => 443 }] } },
   "vLLM 운영 Pod의 egress는 DNS 하나여야 한다"],
  [INF, "allow-model-seed-dns", ->(p) { p.dig("spec", "egress") << { "to" => [{ "ipBlock" => { "cidr" => "0.0.0.0/0" } }], "ports" => [{ "protocol" => "TCP", "port" => 443 }] } },
   "persona-inference에 443 egress가 생겼다"],
  [INF, "allow-model-seed-dns", ->(p) { p.dig("spec", "egress") << { "ports" => [{ "protocol" => "TCP", "port" => 8443 }] } },
   "egress 규칙에 대상(to)이 없다"],
  [INF, "allow-model-seed-dns", ->(p) { p.dig("spec", "egress") << { "to" => [ns_peer("persona-app")] } },
   "egress 규칙에 포트가 없다"],
  # 수동 적용 순서 label
  [INF, "default-deny", ->(p) { p.dig("metadata", "labels")["persona.runtime/apply-phase"] = "allow" },
   "default-deny: apply-phase label이 deny가 아니다"],
  [INF, "allow-vllm-metrics", ->(p) { p.dig("metadata", "labels").delete("persona.runtime/apply-phase") },
   "allow-vllm-metrics: apply-phase label이 allow가 아니다"],
]

cases.each do |relative_path, policy_name, mutate, message|
  path = File.join(root, relative_path)
  original = File.read(path)
  begin
    # 한 파일에 NetworkPolicy가 여럿이다. 이름으로 대상 문서 하나만 골라 바꾸고 전체를 다시 쓴다.
    documents = YAML.load_stream(original).compact
    target = documents.find { |doc| doc.dig("metadata", "name") == policy_name } ||
             raise("사례의 정책을 찾지 못했다: #{policy_name}")
    mutate.call(target)
    File.write(path, documents.map { |doc| YAML.dump(doc) }.join)
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-networkpolicy-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end
puts "NetworkPolicy 음성 테스트 #{cases.length}건 통과"
RUBY
