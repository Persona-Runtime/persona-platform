#!/bin/sh
# bootstrap local-path 선언의 복사본을 하나씩 망가뜨려 validate-local-path-bootstrap.sh가
# 실패하는지 확인한다. 원본 선언·클러스터는 바꾸지 않는다.
set -eu
for tool in ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-local-path-test.XXXXXX")
# 이 실행이 만든 복사본만 제거한다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bootstrap" "$test_dir/scripts"
cp -R "$repo_dir/bootstrap/local-path" "$test_dir/bootstrap/"
cp "$repo_dir/scripts/validate-local-path-bootstrap.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-local-path-bootstrap.sh"

ruby -ryaml -rjson - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
root = ARGV.fetch(0)
CONFIGMAP = File.join(root, "bootstrap/local-path/configmap.yaml")
STORAGECLASS = File.join(root, "bootstrap/local-path/storageclass.yaml")
ROOT_PATH = ["/opt/local-path-provisioner"]

# config.json의 nodePathMap을 바꾸는 사례. ConfigMap 안의 JSON 문자열을 다시 써 넣는다.
def with_node_map(document)
  config = JSON.parse(document["data"]["config.json"])
  yield config["nodePathMap"]
  document["data"]["config.json"] = JSON.pretty_generate(config)
end

# [파일, 변형, 기대 오류 문구]. 각 사례는 원래 파일로 되돌린 뒤 다음 사례를 실행한다.
cases = [
  [CONFIGMAP, ->(d) { with_node_map(d) { |m| m << { "node" => "DEFAULT_PATH_FOR_NON_LISTED_NODES", "paths" => ROOT_PATH } } }, "DEFAULT_PATH_FOR_NON_LISTED_NODES를 두지 않는다"],
  [CONFIGMAP, ->(d) { with_node_map(d) { |m| m << { "node" => "k8s-cp", "paths" => ROOT_PATH } } }, "nodePathMap 노드는 정확히"],
  [CONFIGMAP, ->(d) { with_node_map(d) { |m| m.reject! { |e| e["node"] == "persona-gpu-01" } } }, "nodePathMap 노드는 정확히"],
  [CONFIGMAP, ->(d) { with_node_map(d) { |m| m << { "node" => "persona-gpu-01", "paths" => ROOT_PATH } } }, "중복 노드"],
  [CONFIGMAP, ->(d) { with_node_map(d) { |m| m.find { |e| e["node"] == "persona-gpu-01" }["paths"] = ["/mnt/models"] } }, "persona-gpu-01의 경로는"],
  [CONFIGMAP, ->(d) { d["data"]["config.json"] = "{ not json" }, "JSON으로 파싱되지 않는다"],
  # 주석에도 0777이 있으므로 명령 줄 자체를 바꾼다(첫 0777만 바꾸면 주석이 바뀌어 검사가 결함을 못 본다).
  [CONFIGMAP, ->(d) { d["data"]["setup"] = d["data"]["setup"].sub("mkdir -m 0777", "mkdir -m 0700") }, "setup의 0777"],
  [STORAGECLASS, ->(d) { d["volumeBindingMode"] = "Immediate" }, "WaitForFirstConsumer"],
  [STORAGECLASS, ->(d) { d["reclaimPolicy"] = "Delete" }, "reclaimPolicy는 Retain"],
  [STORAGECLASS, ->(d) { d["allowVolumeExpansion"] = true }, "allowVolumeExpansion은 false"],
]

cases.each do |path, mutate, message|
  original = File.read(path)
  begin
    document = YAML.load(original)
    mutate.call(document)
    File.write(path, YAML.dump(document))
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-local-path-bootstrap.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end
puts "local-path bootstrap 음성 테스트 #{cases.length}건 통과"
RUBY
