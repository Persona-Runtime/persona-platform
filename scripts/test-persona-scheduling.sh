#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 과거 설정을 넣어 회귀 검사가 실패하는지 확인한다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-scheduling.XXXXXX")
# 이 실행이 만든 복사본만 제거하며 원본·클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$repo_dir/bootstrap" "$repo_dir/db" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-persona-app-manifests.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-persona-app-manifests.sh"

ruby -ryaml - "$test_dir" <<'RUBY'
root = ARGV.fetch(0)
# 각 사례는 원래 파일로 되돌린 뒤 다음 사례를 실행한다. 검증 실패뿐 아니라 의도한 오류도 확인한다.
cases = [
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "priorityClassName"], "persona-critical", "DB: 커스텀 PriorityClass"],
  ["kustomize/base/persona-migrate/job.yaml", ["spec", "template", "spec", "priorityClassName"], "persona-low", "migration Job: 커스텀 PriorityClass"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "template", "spec", "priorityClassName"], "persona-low", "Gateway: 커스텀 PriorityClass"],
  ["kustomize/base/persona-web/deployment.yaml", ["spec", "template", "spec", "priorityClassName"], "persona-low", "Web: 커스텀 PriorityClass"],
  ["bootstrap/traefik/values.yaml", ["priorityClassName"], "persona-low", "Traefik: 커스텀 PriorityClass"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "strategy", "type"], "Recreate", "Gateway는 RollingUpdate"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "strategy", "rollingUpdate", "maxSurge"], 0, "Gateway maxSurge는 1"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "strategy", "rollingUpdate", "maxUnavailable"], 1, "Gateway maxUnavailable은 0"],
]
cases.each do |relative_path, keys, value, message|
  path = File.join(root, relative_path)
  original = File.read(path)
  begin
    document = YAML.load(original)
    parent = keys[0...-1].reduce(document) { |node, key| node.fetch(key) }
    parent[keys.last] = value
    File.write(path, YAML.dump(document))
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-persona-app-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end
puts "스케줄링 음성 테스트 #{cases.length}건 통과"
RUBY
