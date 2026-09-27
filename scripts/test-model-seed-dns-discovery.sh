#!/bin/sh
# 임시 DNS discovery overlay의 복사본에 위반을 하나씩 넣어 validate-model-seed-dns-discovery.sh가
# 실패하는지 확인한다. 원본 선언·클러스터는 바꾸지 않는다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-seed-dns-discovery-test.XXXXXX")
# 이 실행이 만든 복사본만 제거한다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-model-seed-dns-discovery.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-model-seed-dns-discovery.sh"

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
root = ARGV.fetch(0)
DELETE_KEY = :delete_key
D = "kustomize/overlays/discovery/persona-model-seed-dns"
JOB = "#{D}/discovery-job.yaml"
POLICY = "#{D}/dns-discovery-policy.yaml"
POD = ["spec", "template", "spec"]
C = POD + ["containers", 0]
DNS_PORTS = ["spec", "egress", 0, "toPorts", 0]

# [파일, 키 경로, 값, 기대 오류 문구]. 키 경로의 Hash는 배열에서 필드가 같은 원소를 고른다.
cases = [
  # 정책 범위
  [POLICY, ["spec", "endpointSelector", "matchLabels", "k8s:persona.runtime/purpose"], DELETE_KEY, "discovery label을 모두 가진 Pod만 고른다"],
  [POLICY, ["spec", "endpointSelector", "matchLabels", "k8s:app.kubernetes.io/name"], "persona-vllm", "discovery label을 모두 가진 Pod만 고른다"],
  # Cilium identity label prefix 누락: Kubernetes 원본 key 그대로 쓰는 사례.
  [POLICY, ["spec", "endpointSelector", "matchLabels"], { "app.kubernetes.io/name" => "persona-vllm-model-seed", "persona.runtime/purpose" => "dns-discovery" }, "discovery label을 모두 가진 Pod만 고른다(k8s: prefix 포함)"],
  [POLICY, ["spec", "egress", 0, "toEndpoints"], [{ "matchLabels" => { "k8s:io.kubernetes.pod.namespace" => "kube-system", "k8s-app" => "kube-dns" } }], "kube-dns뿐이다(k8s: prefix 포함)"],
  [POLICY, ["spec", "ingress"], [{ "fromEntities" => ["cluster"] }], "ingress를 열지 않는다"],
  [POLICY, DNS_PORTS + ["ports"], [{ "port" => "53", "protocol" => "ANY" }], "UDP/TCP 53"],
  [POLICY, DNS_PORTS + ["rules", "dns"], [{ "matchPattern" => "*.huggingface.co" }], "matchPattern \"*\""],
  [POLICY, ["spec", "egress", 1, "toPorts", 0, "ports"], [{ "port" => "0", "protocol" => "ANY" }], "world 443/TCP만이다"],
  [POLICY, ["spec", "egress", 1, "toEntities"], ["all"], "world 443/TCP만이다"],
  [POLICY, ["spec", "egress", 1, "toFQDNs"], [{ "matchName" => "huggingface.co" }], "toFQDNs를 두지 않는다"],
  [POLICY, ["metadata", "annotations"], DELETE_KEY, "임시 정책임을 annotation"],
  # discovery Job: cache를 건드리지 않고 seed와 같은 흐름
  [JOB, POD + ["volumes", { "name" => "discovery" }], { "name" => "discovery", "persistentVolumeClaim" => { "claimName" => "persona-vllm-model-cache" } }, "PVC를 쓰지 않는다"],
  [JOB, C + ["env", { "name" => "TARGET_DIR" }, "value"], "/models", "TARGET_DIR은 /discovery다"],
  [JOB, C + ["image"], "vllm/vllm-openai:v0.29.0-cu129-ubuntu2404", "image가 seed Job과 다르다"],
  [JOB, C + ["env", { "name" => "MODEL_REVISION" }, "value"], "main", "MODEL_REVISION가 seed Job과 다르다"],
  [JOB, POD + ["securityContext", "fsGroup"], 0, "securityContext가 seed Job과 다르다"],
  [JOB, ["spec", "template", "metadata", "labels", "persona.runtime/purpose"], DELETE_KEY, "discovery label을 모두 가진다"],
  [JOB, ["spec", "backoffLimit"], 2, "backoffLimit은 0이다"],
  [JOB, C + ["resources", "limits", "nvidia.com/gpu"], 1, "GPU(nvidia.com/gpu)를 요청하지 않는다"],
  # 임시로 남는가
  ["argocd/persona-app.yaml", ["spec", "source", "path"], D, "임시 discovery overlay를 참조한다"],
]

lookup = lambda do |node, key|
  next node.fetch(key) unless key.is_a?(Hash)
  node.find { |item| key.all? { |field, expected| item[field] == expected } } ||
    raise("사례 경로의 배열 원소를 찾지 못했다: #{key}")
end

def run_validator(root)
  output_path = File.join(root, "result.log")
  success = system("sh", File.join(root, "scripts/validate-model-seed-dns-discovery.sh"), out: output_path, err: [:child, :out])
  [success, File.read(output_path)]
end

cases.each do |relative_path, keys, value, message|
  path = File.join(root, relative_path)
  original = File.read(path)
  begin
    document = YAML.load(original)
    parent = keys[0...-1].reduce(document) { |node, key| lookup.call(node, key) }
    if value == DELETE_KEY && keys.last.is_a?(Hash)
      parent.delete(lookup.call(parent, keys.last))
    elsif value == DELETE_KEY
      parent.delete(keys.last)
    elsif keys.last.is_a?(Hash)
      parent[parent.index(lookup.call(parent, keys.last))] = value
    else
      parent[keys.last] = value
    end
    File.write(path, YAML.dump(document))
    success, output = run_validator(root)
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}\n#{output}" unless output.include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end

# 파일 추가 사례: 임시 world 허용을 영구 정책 디렉터리로 옮기면 실패해야 한다.
promoted = File.join(root, "kustomize/base/networkpolicy/persona-inference/promoted-world.yaml")
File.write(promoted, "spec:\n  egress:\n    - toEntities:\n        - world\n")
begin
  success, output = run_validator(root)
  raise "회귀 검사가 결함을 놓쳤다: world 승격" if success
  raise "예상과 다른 검사 오류다: world 승격\n#{output}" unless output.include?("임시 허용을 승격하지 않는다")
  puts "검출: 임시 허용을 승격하지 않는다"
ensure
  File.delete(promoted)
end
puts "모델 seed DNS discovery 음성 테스트 #{cases.length + 1}건 통과"
RUBY
