#!/bin/sh
# vLLM 선언의 복사본에 계약 위반을 하나씩 넣어 validate-vllm-manifests.sh가 실패하는지 확인한다.
# 원본 선언·클러스터는 바꾸지 않는다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-vllm-test.XXXXXX")
# 이 실행이 만든 복사본만 제거한다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-vllm-manifests.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-vllm-manifests.sh"

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
root = ARGV.fetch(0)
DELETE_KEY = :delete_key
B = "kustomize/base/persona-vllm"
DEP = "#{B}/deployment.yaml"
SVC = "#{B}/service.yaml"
PM = "#{B}/podmonitor.yaml"
POD = ["spec", "template", "spec"]
C = POD + ["containers", 0]
INIT = POD + ["initContainers", 0]
MODEL_DIR = "/models/Qwen/Qwen3-4B-Instruct-2507/cdbee75f17c01a7cc42f958dc650907174af0554"
BASE_ARGS = ["--host", "0.0.0.0", "--port", "8000", "--served-model-name", "Qwen/Qwen3-4B-Instruct-2507",
             "--max-model-len", "8192", "--gpu-memory-utilization", "0.85", "--no-enable-log-requests"]

# [파일, 키 경로, 값, 기대 오류 문구]. 키 경로의 Hash는 배열에서 필드가 같은 원소를 고른다.
cases = [
  # GPU·배치
  [DEP, POD + ["runtimeClassName"], DELETE_KEY, "RuntimeClass nvidia"],
  [DEP, C + ["resources", "limits", "nvidia.com/gpu"], 2, "GPU 1장"],
  [DEP, C + ["resources", "requests", "nvidia.com/gpu"], DELETE_KEY, "GPU 1장"],
  [DEP, POD + ["nodeSelector"], DELETE_KEY, "GPU 노드 node-pool selector"],
  [DEP, POD + ["tolerations"], DELETE_KEY, "GPU 전용 taint toleration"],
  [DEP, ["spec", "replicas"], 2, "replicas는 1이다"],
  [DEP, ["spec", "strategy"], { "type" => "RollingUpdate" }, "strategy는 Recreate다"],
  # 모델 cache
  [DEP, C + ["volumeMounts", { "name" => "model-cache" }, "readOnly"], false, "/models는 readOnly로 mount한다"],
  [DEP, POD + ["volumes", { "name" => "model-cache" }, "persistentVolumeClaim", "readOnly"], DELETE_KEY, "/models PVC는 readOnly다"],
  [DEP, POD + ["volumes", { "name" => "model-cache" }, "persistentVolumeClaim", "claimName"], "other-cache", "persona-vllm-model-cache PVC다"],
  [DEP, C + ["command"], ["vllm", "serve", "Qwen/Qwen3-4B-Instruct-2507"], "로컬 절대 모델 경로"],
  # initContainer
  [DEP, POD + ["initContainers"], DELETE_KEY, "initContainer는 verify-model-cache 하나다"],
  [DEP, INIT + ["command"], ["/bin/sh", "-c", "test -s #{MODEL_DIR}/model.safetensors.index.json || exit 1"], "initContainer가 .persona-seed-complete.json을 확인하지 않는다"],
  [DEP, INIT + ["env"], DELETE_KEY, "NVIDIA_VISIBLE_DEVICES=void"],
  [DEP, INIT + ["resources", "limits", "nvidia.com/gpu"], 1, "initContainer는 GPU를 요청하지 않는다"],
  # 인자·env
  [DEP, C + ["args"], BASE_ARGS - ["--no-enable-log-requests"] + ["--disable-log-requests"], "--disable-log-requests는 vLLM v0.29.0에 없는 인자다"],
  [DEP, C + ["args"], BASE_ARGS - ["--no-enable-log-requests"] + ["--enable-log-requests"], "--enable-log-requests 금지"],
  [DEP, C + ["args"], BASE_ARGS.map { |a| a == "8192" ? "262144" : a }, "--max-model-len은 8192"],
  # 이전 기준선(4096)으로 되돌린 선언도 승인 값이 아니므로 검증기가 막아야 한다.
  [DEP, C + ["args"], BASE_ARGS.map { |a| a == "8192" ? "4096" : a }, "--max-model-len은 8192"],
  [DEP, C + ["env", { "name" => "HF_HUB_OFFLINE" }], DELETE_KEY, "HF_HUB_OFFLINE=1"],
  [DEP, C + ["env", { "name" => "VLLM_NO_USAGE_STATS" }, "value"], "0", "VLLM_NO_USAGE_STATS=1"],
  # 보안·볼륨
  [DEP, C + ["securityContext", "readOnlyRootFilesystem"], false, "root filesystem은 read-only다"],
  [DEP, POD + ["securityContext", "runAsUser"], 0, "non-root 10001/10001"],
  [DEP, POD + ["volumes", { "name" => "dshm" }, "emptyDir"], {}, "/dev/shm은 Memory emptyDir다"],
  [DEP, C + ["image"], "vllm/vllm-openai:v0.29.0-cu129-ubuntu2404", "검증한 vLLM digest"],
  [DEP, C + ["startupProbe", "failureThreshold"], 6, "startupProbe 허용 시간"],
  [DEP, C + ["readinessProbe"], DELETE_KEY, "readinessProbe가 없다"],
  # Service·PodMonitor 일치
  [SVC, ["spec", "selector"], { "app.kubernetes.io/name" => "persona-gateway" }, "Service selector는 Pod label과 같다"],
  [SVC, ["spec", "ports", 0, "port"], 8080, "Service는 http 8000"],
  [SVC, ["spec", "type"], "NodePort", "Service는 ClusterIP다"],
  [PM, ["metadata", "labels", "release"], DELETE_KEY, "release=monitoring-stack"],
  [PM, ["spec", "podMetricsEndpoints", 0, "port"], "metrics", "PodMonitor는 http 포트 /metrics"],
  [PM, ["spec", "selector", "matchLabels", "app.kubernetes.io/name"], "persona-vllm-model-seed", "PodMonitor selector는 Pod label과 같다"],
  # 경계
  ["argocd/persona-app.yaml", ["spec", "source", "path"], "kustomize/overlays/prod/persona-vllm", "persona-vllm overlay를 참조한다"],
  ["kustomize/base/persona-gateway/deployment.yaml", C + ["env", { "name" => "PERSONA_CHAT_INFERENCE_MODE" }, "value"], "mock", "Gateway PERSONA_CHAT_INFERENCE_MODE는 llm이다"],
  ["kustomize/base/persona-gateway/deployment.yaml", C + ["env", { "name" => "PERSONA_VLLM_BASE_URL" }, "value"], "http://persona-vllm.persona-inference.svc.cluster.local:8080", "Gateway PERSONA_VLLM_BASE_URL이 vLLM Service와 다르다"],
  ["kustomize/base/persona-gateway/deployment.yaml", C + ["env", { "name" => "PERSONA_VLLM_MODEL" }, "value"], "qwen3-4b", "Gateway PERSONA_VLLM_MODEL이 vLLM --served-model-name"],
]

lookup = lambda do |node, key|
  next node.fetch(key) unless key.is_a?(Hash)
  node.find { |item| key.all? { |field, expected| item[field] == expected } } ||
    raise("사례 경로의 배열 원소를 찾지 못했다: #{key}")
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
    else
      parent[keys.last] = value
    end
    File.write(path, YAML.dump(document))
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-vllm-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end
puts "vLLM 음성 테스트 #{cases.length}건 통과"
RUBY
