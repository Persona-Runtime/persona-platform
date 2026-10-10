#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 결함을 하나씩 넣어 validate-grafana-dashboards.sh가 실패하는지 확인한다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/grafana-dashboards-test.XXXXXX")
# 이 실행이 만든 복사본만 제거하며 원본·클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-grafana-dashboards.sh" "$test_dir/scripts/"
# 깨끗한 복사본은 먼저 통과해야 한다. 아니면 아래 실패가 결함 때문인지 알 수 없다.
sh "$test_dir/scripts/validate-grafana-dashboards.sh" > /dev/null

ruby -ryaml -rjson -rdigest -rfileutils - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8

root = ARGV.fetch(0)
BASE = "kustomize/base/grafana-dashboards"
APP = "argocd/monitoring-stack.yaml"

def edit_json(path, &block)
  document = JSON.parse(File.read(path))
  block.call(document)
  File.write(path, JSON.pretty_generate(document))
end

# 사본을 고치고 SOURCE.sha256도 맞춰, 해시 불일치가 아니라 대상 결함만 드러나게 한다.
def resync(root, file)
  manifest = File.join(root, BASE, "SOURCE.sha256")
  digest = Digest::SHA256.hexdigest(File.binread(File.join(root, BASE, file)))
  lines = File.readlines(manifest, chomp: true).map { |line| line.end_with?("  #{file}") ? "#{digest}  #{file}" : line }
  File.write(manifest, lines.join("\n") + "\n")
end

def mutate_dashboard(root, file, &block)
  edit_json(File.join(root, BASE, file), &block)
  resync(root, file)
end

def mutate_app(root, &block)
  path = File.join(root, APP)
  app = YAML.load_file(path)
  block.call(app)
  File.write(path, YAML.dump(app))
end

cases = [
  ["사본이 정본 해시와 다름", ->(r) { File.write(File.join(r, BASE, "vllm-serving.json"), File.read(File.join(r, BASE, "vllm-serving.json")) + " ") }, "정본 해시"],
  ["__inputs가 남음", ->(r) { mutate_dashboard(r, "gpu-dcgm.json") { |d| d["__inputs"] = [{ "name" => "DS_PROMETHEUS" }] } }, "__inputs"],
  ["고정 uid가 바뀜", ->(r) { mutate_dashboard(r, "postgres-cnpg.json") { |d| d["uid"] = "cloudnative-pg" } }, "uid는 persona-cnpg"],
  ["패널 ID 충돌", ->(r) { mutate_dashboard(r, "mafest-service.json") { |d| d["panels"][2]["id"] = d["panels"][1]["id"] } }, "패널 ID 충돌"],
  ["datasource가 고정 uid Prometheus", ->(r) { mutate_dashboard(r, "vllm-serving.json") { |d| d["panels"][1]["datasource"] = { "type" => "prometheus", "uid" => "Prometheus" } } }, "datasource 참조"],
  ["${DS_*} 참조", ->(r) { mutate_dashboard(r, "vllm-serving.json") { |d| d["description"] = "${DS_PROMETHEUS}" } }, "DS_"],
  ["기본 시간 범위 변경", ->(r) { mutate_dashboard(r, "gpu-dcgm.json") { |d| d["time"]["from"] = "now-7d" } }, "기본 시간"],
  ["sidecar 라벨 제거", ->(r) { path = File.join(r, BASE, "kustomization.yaml"); File.write(path, File.read(path).sub(/^    grafana_dashboard: "1"/, "    grafana_dashboard: \"0\"")) }, "sidecar 라벨"],
  ["ConfigMap 이름 변경", ->(r) { path = File.join(r, BASE, "kustomization.yaml"); File.write(path, File.read(path).sub("persona-dashboard-gpu-dcgm", "gpu-dcgm")) }, "ConfigMap 이름"],
  ["차트 revision 변경", ->(r) { mutate_app(r) { |a| a["spec"]["sources"][0]["targetRevision"] = "90.0.0" } }, "차트 source가 바뀌었다"],
  ["values ref path 제거", ->(r) { mutate_app(r) { |a| a["spec"]["sources"][1].delete("path") } }, "path는"],
  ["자동 Sync 추가", ->(r) { mutate_app(r) { |a| a["spec"]["syncPolicy"]["automated"] = {} } }, "자동 Sync"],
  ["ServerSideApply 제거", ->(r) { mutate_app(r) { |a| a["spec"]["syncPolicy"]["syncOptions"] = [] } }, "ServerSideApply"],
  ["source 추가", ->(r) { mutate_app(r) { |a| a["spec"]["sources"] << { "repoURL" => "https://example.invalid/x.git", "targetRevision" => "main" } } }, "두 개여야"],
]

cases.each do |label, mutate, message|
  case_dir = File.join(root, "case")
  FileUtils.rm_rf(case_dir)
  FileUtils.mkdir_p(case_dir)
  %w[kustomize argocd scripts].each { |dir| FileUtils.cp_r(File.join(root, dir), case_dir) }
  mutate.call(case_dir)
  output_path = File.join(case_dir, "result.log")
  success = system("sh", File.join(case_dir, "scripts/validate-grafana-dashboards.sh"), out: output_path, err: [:child, :out])
  raise "회귀 검사가 결함을 놓쳤다: #{label}" if success
  raise "예상과 다른 검사 오류다(#{label}): #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
  puts "검출: #{label}"
end
puts "grafana 대시보드 음성 테스트 #{cases.length}건 통과"
RUBY
