#!/bin/sh
# bootstrap local-path 선언(ConfigMap·StorageClass)을 파일로만 읽어 안전 기준을 검사한다.
#
# 클러스터를 읽거나 적용하지 않는다(kubectl도 쓰지 않는다). bootstrap은 Argo 밖이라 이 검사
# 통과는 "Git 선언이 기준에 맞다"까지다 — 실제 클러스터 반영과 GPU 노드 PVC Bound는 따로
# 확인해야 한다.
set -eu

command -v ruby >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: ruby" >&2; exit 1; }
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

ruby -ryaml -rjson - "$repo_dir/bootstrap/local-path/configmap.yaml" "$repo_dir/bootstrap/local-path/storageclass.yaml" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
configmap_path, storageclass_path = ARGV

# 볼륨을 만들어도 되는 노드와 그 경로. 여기 없는 노드(control-plane 등)는 provisioning이
# 실패해야 한다 — nodeSelector를 빠뜨린 PVC가 엉뚱한 디스크에 생기지 않게 하는 안전장치다.
ALLOWED_NODES = %w[k8s-worker1 k8s-worker2 persona-gpu-01].freeze
VOLUME_ROOT = ["/opt/local-path-provisioner"].freeze
DEFAULT_PATH_KEY = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
# README가 "반드시 유지"라고 한 setup 줄. 낮추면 non-root 컨테이너(CNPG 등)가 볼륨에 쓰지 못한다.
SETUP_LINE = 'mkdir -m 0777 -p "$VOL_DIR"'

configmap = YAML.load_file(configmap_path)
raise "[안전] local-path ConfigMap 이름·namespace가 다르다" unless configmap.dig("metadata", "name") == "local-path-config" && configmap.dig("metadata", "namespace") == "local-path-storage"
config_text = configmap.dig("data", "config.json") || raise("[안전] config.json이 없다")
begin
  config = JSON.parse(config_text)
rescue JSON::ParserError => e
  raise "[안전] config.json이 JSON으로 파싱되지 않는다: #{e.message}"
end

# 기본 경로는 노드 항목으로 넣어도, 문자열 어딘가에 남겨도 안 된다.
raise "[안전] #{DEFAULT_PATH_KEY}를 두지 않는다 — 목록에 없는 노드(control-plane 등)에 볼륨이 조용히 생긴다" if config_text.include?(DEFAULT_PATH_KEY)

entries = config["nodePathMap"]
raise "[안전] nodePathMap이 목록이 아니다" unless entries.is_a?(Array)
nodes = entries.map { |entry| entry["node"] }
raise "[안전] nodePathMap에 중복 노드가 있다: #{nodes.inspect}" unless nodes.uniq.length == nodes.length
unless nodes.sort == ALLOWED_NODES.sort
  raise "[안전] nodePathMap 노드는 정확히 #{ALLOWED_NODES.join(", ")}여야 한다(실제: #{nodes.join(", ")})"
end
entries.each do |entry|
  unless entry["paths"] == VOLUME_ROOT
    raise "[안전] #{entry["node"]}의 경로는 #{VOLUME_ROOT.first} 하나여야 한다(실제: #{entry["paths"].inspect})"
  end
end

setup = configmap.dig("data", "setup").to_s
raise "[기준선] setup의 0777 디렉터리 생성이 바뀌었다 — non-root 컨테이너가 볼륨에 쓰지 못한다" unless setup.include?(SETUP_LINE)

storageclass = YAML.load_file(storageclass_path)
raise "[기준선] StorageClass 이름은 local-path다" unless storageclass.dig("metadata", "name") == "local-path"
raise "[기준선] provisioner는 rancher.io/local-path다" unless storageclass["provisioner"] == "rancher.io/local-path"
raise "[기준선] volumeBindingMode는 WaitForFirstConsumer다 — Pod가 스케줄된 노드에 볼륨을 만든다" unless storageclass["volumeBindingMode"] == "WaitForFirstConsumer"
raise "[기준선] reclaimPolicy는 Retain이다 — PVC를 지워도 노드 디스크 데이터를 바로 지우지 않는다" unless storageclass["reclaimPolicy"] == "Retain"
raise "[기준선] allowVolumeExpansion은 false다 — local-path는 확장을 지원하지 않는다" unless storageclass["allowVolumeExpansion"] == false

puts "local-path bootstrap 선언 검사 통과(허용 노드: #{ALLOWED_NODES.join(", ")}, 클러스터 미접근)"
RUBY
