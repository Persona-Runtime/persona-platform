#!/bin/sh

set -eu

# monitoring-stack(kube-prometheus-stack) 렌더가 Grafana 플러그인 선언의 계약을 지키는지
# 로컬에서만 검사한다. 클러스터를 호출하지 않고 Argo Sync도 하지 않는다.
# scripts/validate-networkpolicy-manifests.sh와 같은 패턴([안전]·[기준선] 태그, 렌더 +
# ruby 검사)을 쓴다.
#
# 이 스크립트가 지키려는 것: Grafana 13.2의 Prometheus datasource는 본체에 없는 별도
# 플러그인이고, persistence가 꺼져 있어 플러그인 디렉터리가 Pod마다 새로 빈다. 그래서
# "기동할 때마다 다시 설치"라는 선언이 정확히 하나 있어야 하고, 그 버전은 Grafana
# 이미지 버전과 같아야 한다. 둘이 어긋나면 여기서 실패한다.
#
# chart는 네트워크로 받는다(argocd/monitoring-stack.yaml이 가리키는 Helm 저장소).
# 오프라인에서는 실행되지 않는다 — 그 점은 argo-preflight.sh의 render_at_sha와 같다.
# 렌더 성공은 실제 플러그인 다운로드·Grafana 기동 성공의 증거가 아니다.

for tool in helm ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
app_file="$repo_dir/argocd/monitoring-stack.yaml"
values_file="$repo_dir/helm/values/monitoring-stack.yaml"

# chart 좌표를 이 스크립트에 적지 않고 Argo Application에서 읽는다. 하드코딩하면 Argo가
# 보는 chart와 여기서 검사하는 chart가 말없이 달라질 수 있다.
read_chart_field() {
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    source = app.fetch("spec").fetch("sources").find { |s| s.key?("chart") } ||
      abort("[안전] monitoring-stack에 Helm chart source가 없다")
    value = source[ARGV[1]] || source.dig("helm", ARGV[1])
    abort "[안전] chart source에 #{ARGV[1]}가 없다" if value.nil?
    puts value
  ' "$app_file" "$1"
}

chart_repo=$(read_chart_field repoURL)
chart_name=$(read_chart_field chart)
chart_version=$(read_chart_field targetRevision)
release_name=$(read_chart_field releaseName)

rendered_file=$(mktemp "${TMPDIR:-/tmp}/monitoring-stack.XXXXXX.yaml")
trap 'rm -f "$rendered_file"' EXIT
trap 'exit 1' HUP INT TERM

helm template "$release_name" "$chart_name" \
  --repo "$chart_repo" --version "$chart_version" \
  -n monitoring -f "$values_file" > "$rendered_file"

ruby -ryaml - "$rendered_file" "$release_name" <<'RUBY'
# encoding: utf-8
#
# heredoc로 넘긴 Ruby 소스는 파일이 아니라 stdin이라, 로케일이 UTF-8이 아니면(LC_ALL=C,
# cron 등) US-ASCII로 파싱돼 아래 한글 메시지에서 "invalid multibyte char"로 즉시 죽는다.
# 매직 코멘트는 반드시 첫 줄이어야 하며, 고치는 것은 이 소스의 인코딩뿐이다.
# 아래 Encoding.default_external은 File.read로 읽는 렌더 결과의 인코딩을 맡는다.
Encoding.default_external = Encoding::UTF_8

rendered_path, release_name = ARGV
resources = YAML.load_stream(File.read(rendered_path)).compact

def resource(all, kind, name)
  all.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("[안전] #{kind}/#{name}이 렌더 결과에 없다")
end

grafana_name = "#{release_name}-grafana"
deployment = resource(resources, "Deployment", grafana_name)
containers = deployment.dig("spec", "template", "spec", "containers")
grafana = containers.find { |item| item["name"] == "grafana" } ||
  raise("[안전] Grafana Deployment에 grafana 컨테이너가 없다")

# 1. 설치 선언이 정확히 하나여야 한다. chart가 넣는 ConfigMap 참조와 values의 env로
#    같은 이름을 두 번 선언하면 나중 것이 이기는데, 어느 쪽이 이겼는지는 렌더만 봐서는
#    알기 어렵다. 그래서 개수부터 고정한다.
preinstall = grafana.fetch("env").select { |item| item["name"] == "GF_PLUGINS_PREINSTALL_SYNC" }
unless preinstall.length == 1
  raise "[안전] GF_PLUGINS_PREINSTALL_SYNC 선언이 정확히 1개여야 한다: #{preinstall.length}개"
end
source_ref = preinstall.fetch(0).dig("valueFrom", "configMapKeyRef")
unless source_ref == { "name" => grafana_name, "key" => "plugins" }
  raise "[안전] 플러그인 선언은 chart가 만드는 #{grafana_name} ConfigMap의 plugins 키를 " \
        "가리켜야 한다 — grafana.env로 값을 직접 박지 않는다"
end

# 2. 그 ConfigMap에 실제로 무엇이 들어 있는지 본다. 값은 쉼표로 이어 붙는 형식이라
#    다른 플러그인이 조용히 딸려 들어올 수 있다.
config = resource(resources, "ConfigMap", grafana_name)
plugins = (config.dig("data", "plugins") || "").split(",").map(&:strip)
raise "[안전] Grafana ConfigMap에 plugins 값이 없다 — 플러그인이 설치되지 않는다" if plugins.empty?
unless plugins.length == 1
  raise "[기준선] 설치 대상 플러그인이 1개(prometheus)여야 한다: #{plugins.join(', ')}"
end
plugin_name, plugin_version = plugins.fetch(0).split("@", 2)
raise "[안전] 설치 대상 플러그인이 prometheus가 아니다: #{plugin_name}" unless plugin_name == "prometheus"
if plugin_version.nil? || plugin_version.empty?
  raise "[안전] 플러그인 버전을 고정하지 않으면 기동할 때마다 다른 버전이 설치될 수 있다"
end

# 3. 플러그인 버전은 Grafana 이미지 버전을 따라간다. 이미지를 올리고 이 줄을 잊으면
#    본체와 플러그인이 어긋난 채로 배포된다.
image = grafana.fetch("image")
image_tag = image.split(":", 2).fetch(1, "")
expected_image = "docker.io/grafana/grafana:#{plugin_version}-distroless"
unless image == expected_image
  raise "[안전] Grafana 이미지와 플러그인 버전이 어긋난다: 이미지 #{image}, " \
        "플러그인 #{plugin_version} — helm/values/monitoring-stack.yaml의 두 줄을 함께 고친다"
end
unless image_tag.end_with?("-distroless")
  raise "[기준선] Grafana 이미지는 distroless 태그를 쓴다: #{image_tag}"
end

# 4. 플러그인이 왜 매번 다시 설치돼야 하는지의 전제. persistence를 켜면서 위 선언을
#    지우는 조합이라면 그때 이 검사를 함께 고쳐야 한다.
volumes = deployment.dig("spec", "template", "spec", "volumes") || []
mount = grafana.fetch("volumeMounts").find { |item| item["mountPath"] == "/var/lib/grafana" } ||
  raise("[안전] grafana 컨테이너에 /var/lib/grafana 마운트가 없다")
storage = volumes.find { |item| item["name"] == mount.fetch("name") } ||
  raise("[안전] /var/lib/grafana를 받는 볼륨이 렌더 결과에 없다")
unless storage.key?("emptyDir")
  raise "[기준선] /var/lib/grafana가 emptyDir이 아니다 — 플러그인 휘발 전제가 바뀌었다"
end

# 5. 이번 변경이 datasource provisioning을 건드리지 않았는지 확인한다. chart가 만드는
#    ConfigMap이라 저장소에서 직접 고칠 수 없고, 고쳐서도 안 되는 자리다.
datasource = resource(resources, "ConfigMap", "#{release_name}-kube-prom-grafana-datasource")
provisioning = YAML.safe_load(datasource.dig("data", "datasource.yaml"))
prometheus = (provisioning.fetch("datasources")).find { |item| item["uid"] == "prometheus" } ||
  raise("[안전] uid=prometheus datasource가 없다")
raise "[안전] Prometheus datasource type이 prometheus가 아니다" unless prometheus["type"] == "prometheus"
raise "[안전] Prometheus datasource가 기본값이 아니다" unless prometheus["isDefault"] == true
expected_url = "http://#{release_name}-kube-prom-prometheus.monitoring:9090/"
unless prometheus["url"] == expected_url
  raise "[기준선] Prometheus datasource URL이 기준선과 다르다: #{prometheus['url']}"
end

puts "monitoring-stack 렌더와 Grafana 플러그인 선언 검사 통과"
RUBY
