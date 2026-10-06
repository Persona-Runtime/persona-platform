#!/bin/sh
# 모델 cache 선언의 복사본에 계약 위반을 하나씩 넣어 validate-model-cache-manifests.sh가 실패하는지
# 확인한다. 원본 선언·클러스터는 바꾸지 않는다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-model-cache-test.XXXXXX")
# 이 실행이 만든 복사본만 제거한다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$repo_dir/bootstrap" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-model-cache-manifests.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-model-cache-manifests.sh"

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
root = ARGV.fetch(0)
DELETE_KEY = :delete_key
BASE = "kustomize/base/persona-model-cache"
JOB = "#{BASE}/model-seed-job.yaml"
PVC = "#{BASE}/model-cache-pvc.yaml"
POD = ["spec", "template", "spec"]
C = POD + ["containers", 0]

# [파일, 키 경로, 값, 기대 오류 문구]. 키 경로의 Hash는 배열에서 필드가 같은 원소를 고른다.
cases = [
  [JOB, ["spec", "backoffLimit"], 1, "backoffLimit은 0이다"],
  [JOB, POD + ["restartPolicy"], "OnFailure", "restartPolicy는 Never다"],
  [JOB, ["spec", "activeDeadlineSeconds"], DELETE_KEY, "activeDeadlineSeconds가 필요하다"],
  [JOB, ["spec", "ttlSecondsAfterFinished"], 60, "자동 삭제하지 않는다"],
  [JOB, C + ["resources", "limits", "nvidia.com/gpu"], 1, "GPU(nvidia.com/gpu)를 요청하지 않는다"],
  [JOB, POD + ["runtimeClassName"], "nvidia", "RuntimeClass(nvidia)를 쓰지 않는다"],
  [JOB, POD + ["nodeSelector"], DELETE_KEY, "GPU 노드 node-pool selector가 필요하다"],
  [JOB, C + ["image"], "vllm/vllm-openai:v0.29.0-cu129-ubuntu2404", "검증한 vLLM linux/amd64 digest다"],
  [JOB, C + ["env", { "name" => "MODEL_REVISION" }, "value"], "main", "MODEL_REVISION은 고정 commit"],
  [JOB, C + ["securityContext", "readOnlyRootFilesystem"], false, "root filesystem은 read-only다"],
  [JOB, POD + ["securityContext", "runAsUser"], 0, "runAsUser 10001"],
  [JOB, POD + ["securityContext", "fsGroup"], DELETE_KEY, "fsGroup은 10001이다"],
  [JOB, POD + ["securityContext", "fsGroup"], 0, "fsGroup은 10001이다"],
  [JOB, C + ["volumeMounts", { "name" => "tmp" }], DELETE_KEY, "seed mount는 /models·/tmp·/opt/persona-seed 셋뿐이다"],
  [JOB, C + ["volumeMounts", { "name" => "seed-script" }, "readOnly"], false, "read-only ConfigMap이다"],
  [JOB, ["spec", "template", "metadata", "labels", "app.kubernetes.io/name"], "persona-vllm", "seed Pod label은 persona-vllm-model-seed"],
  [PVC, ["spec", "resources", "requests", "storage"], "20Gi", "PVC 크기는 40Gi다"],
  [PVC, ["spec", "storageClassName"], "standard", "StorageClass는 local-path다"],
  [PVC, ["spec", "accessModes"], ["ReadWriteMany"], "ReadWriteOnce만 쓴다"],
  ["argocd/persona-app.yaml", ["spec", "source", "path"], "kustomize/overlays/prod/persona-model-cache", "persona-model-cache overlay를 참조한다"],
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
    success = system("sh", File.join(root, "scripts/validate-model-cache-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end

# 파일 추가·삭제 사례: bootstrap에 같은 Namespace를 다시 두면 소유자가 둘이 된다.
duplicate = File.join(root, "bootstrap/namespaces/persona-inference.yaml")
File.write(duplicate, { "apiVersion" => "v1", "kind" => "Namespace", "metadata" => { "name" => "persona-inference" } }.to_yaml)
begin
  output_path = File.join(root, "result.log")
  success = system("sh", File.join(root, "scripts/validate-model-cache-manifests.sh"), out: output_path, err: [:child, :out])
  raise "회귀 검사가 결함을 놓쳤다: bootstrap Namespace 중복" if success
  raise "예상과 다른 검사 오류다: bootstrap Namespace 중복" unless File.read(output_path).include?("소유자를 하나로 둔다")
  puts "검출: 소유자를 하나로 둔다"
ensure
  File.delete(duplicate)
end
puts "모델 cache 음성 테스트 #{cases.length + 1}건 통과"
RUBY
