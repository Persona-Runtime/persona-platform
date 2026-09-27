#!/bin/sh
# NetworkPolicy 선언의 복사본에 Gateway ↔ vLLM·Prometheus → vLLM 계약 위반을 하나씩 넣어
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
APP = "kustomize/base/networkpolicy/persona-app/network-policy.yaml"
INF = "kustomize/base/networkpolicy/persona-inference/network-policy.yaml"

def ns_peer(name)
  { "namespaceSelector" => { "matchLabels" => { "kubernetes.io/metadata.name" => name } } }
end

def pod_peer(labels)
  { "podSelector" => { "matchLabels" => labels } }
end

VLLM = { "app.kubernetes.io/name" => "persona-vllm" }
GATEWAY = { "app.kubernetes.io/name" => "persona-gateway" }
PROMETHEUS = { "app.kubernetes.io/name" => "prometheus", "app.kubernetes.io/instance" => "monitoring-stack-kube-prom-prometheus" }

# Gateway egress 중 vLLM 규칙(persona-inference를 가리키는 것)을 찾는다.
gateway_vllm_rule = lambda do |policy|
  policy.dig("spec", "egress").find { |rule| rule["to"].any? { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") == "persona-inference" } }
end

# [파일, 정책 이름, 복사본을 바꾸는 함수, 기대 오류 문구]
cases = [
  # Gateway → vLLM egress (persona-app allow-gateway)
  [APP, "allow-gateway", ->(p) { gateway_vllm_rule.call(p)["to"] = [ns_peer("persona-inference")] },
   "allow-gateway → vLLM egress: persona-inference namespace AND"],
  [APP, "allow-gateway", ->(p) { gateway_vllm_rule.call(p)["to"] = [pod_peer(VLLM)] },
   "allow-gateway → vLLM egress: persona-inference namespace AND"],
  [APP, "allow-gateway", ->(p) { gateway_vllm_rule.call(p)["to"] = [ns_peer("persona-inference"), pod_peer(VLLM)] },
   "allow-gateway → vLLM egress: peer가 정확히 1개가 아니다"],
  [APP, "allow-gateway", ->(p) { gateway_vllm_rule.call(p)["ports"] = [{ "protocol" => "TCP", "port" => 8001 }] },
   "vLLM egress 포트가 TCP 8000 하나가 아니다"],
  [APP, "allow-gateway", ->(p) { gateway_vllm_rule.call(p)["ports"] << { "protocol" => "TCP", "port" => 443 } },
   "vLLM egress 포트가 TCP 8000 하나가 아니다"],
  [APP, "allow-gateway", ->(p) { gateway_vllm_rule.call(p)["to"] << { "ipBlock" => { "cidr" => "0.0.0.0/0" } } },
   "allow-gateway → vLLM egress: peer가 정확히 1개가 아니다"],
  [APP, "allow-gateway", ->(p) { p.dig("spec", "egress").delete(gateway_vllm_rule.call(p)) },
   "DB·embedding·DNS·vLLM 4개여야 한다"],
  # 기존 Gateway egress 보존
  [APP, "allow-gateway", ->(p) { p.dig("spec", "egress", 0, "ports", 0)["port"] = 5433 },
   "기존 egress 규칙이 바뀌었다"],
  [APP, "allow-gateway", ->(p) { p.dig("spec", "egress", 2)["ports"].pop },
   "기존 egress 규칙이 바뀌었다"],
  [APP, "allow-gateway", ->(p) { p.dig("spec", "egress").delete_at(2) },
   "DB·embedding·DNS·vLLM 4개여야 한다"],
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
