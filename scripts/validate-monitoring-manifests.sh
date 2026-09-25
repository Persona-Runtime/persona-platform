#!/bin/sh

set -eu

# monitoring-stack(kube-prometheus-stack) 렌더가 Grafana·datasource 기준선을 지키는지
# 로컬에서만 검사한다. 클러스터를 호출하지 않고 Argo Sync도 하지 않는다.
# scripts/validate-networkpolicy-manifests.sh와 같은 패턴([안전]·[기준선] 태그, 렌더 +
# ruby 검사)을 쓴다.
#
# Grafana 플러그인 런타임 설치(GF_PLUGINS_PREINSTALL*)와 [plugin.prometheus] 설정은
# 13.2.1-distroless에서 읽기 전용 bundled 경로와 충돌해 CrashLoop를 일으켰다. 별도 검증 없이
# 다시 들어오지 않도록, 그 선언이 렌더에 없어야 통과한다.
#
# chart는 네트워크로 받는다(argocd/monitoring-stack.yaml이 가리키는 Helm 저장소).
# 오프라인에서는 실행되지 않는다 — 그 점은 argo-preflight.sh의 render_at_sha와 같다.
# 렌더 검사 통과는 Grafana 기동이나 datasource 동작 성공의 증거가 아니다.

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

# 1. 플러그인 런타임 설치가 선언돼 있지 않아야 한다. chart는 grafana.plugins를
#    GF_PLUGINS_PREINSTALL_SYNC로 바꾸는데, 13.2.1-distroless에서는 이 설치가 bundled
#    Prometheus 플러그인을 업데이트하려다 읽기 전용 경로에서 실패해 Grafana가 기동하지
#    못했다(2026-09-25). values의 env로 직접 넣는 경우도 함께 막으려고 접두사로 본다.
#    다른 플러그인이 필요해져도 values에 한 줄 추가하고 Sync하는 식으로 풀지 않는다.
#    격리 환경에서 기동·provisioning·재시작을 검증한 뒤 이 가드를 의도적으로 고친다.
preinstall = (grafana["env"] || []).map { |item| item["name"] }.select do |name|
  name.start_with?("GF_PLUGINS_PREINSTALL")
end
unless preinstall.empty?
  raise "[안전] 검증되지 않은 플러그인 런타임 설치 선언이 있다: #{preinstall.join(', ')}"
end
config = resource(resources, "ConfigMap", grafana_name)
plugins = (config.dig("data", "plugins") || "").strip
raise "[안전] Grafana ConfigMap에 plugins 값이 있다: #{plugins}" unless plugins.empty?

# 2. [plugin.prometheus] 섹션도 없어야 한다. as_external을 켜도 같은 경로·같은 오류가
#    재현돼, 이 설정은 해결책으로 확인되지 않았다.
ini = config.dig("data", "grafana.ini") || ""
if ini.each_line.any? { |line| line.strip == "[plugin.prometheus]" }
  raise "[안전] grafana.ini에 검증되지 않은 [plugin.prometheus] 섹션이 있다"
end

# 3. 이미지는 distroless 계열을 유지한다.
image_tag = grafana.fetch("image").split(":", 2).fetch(1, "")
unless image_tag.end_with?("-distroless")
  raise "[기준선] Grafana 이미지는 distroless 태그를 쓴다: #{image_tag}"
end

# 4. persistence를 끈 기준선. /var/lib/grafana가 emptyDir이라 Pod 안에서 수동으로 설치한
#    플러그인이나 UI에서 만든 설정은 재시작 때 사라진다. 이 전제가 바뀌면 여기서 드러난다.
volumes = deployment.dig("spec", "template", "spec", "volumes") || []
mount = grafana.fetch("volumeMounts").find { |item| item["mountPath"] == "/var/lib/grafana" } ||
  raise("[안전] grafana 컨테이너에 /var/lib/grafana 마운트가 없다")
storage = volumes.find { |item| item["name"] == mount.fetch("name") } ||
  raise("[안전] /var/lib/grafana를 받는 볼륨이 렌더 결과에 없다")
unless storage.key?("emptyDir")
  raise "[기준선] /var/lib/grafana가 emptyDir이 아니다 — 플러그인 휘발 전제가 바뀌었다"
end

# 5. datasource provisioning 기준선을 확인한다. chart가 만드는 ConfigMap이라 저장소에서
#    직접 고칠 수 없고, 고쳐서도 안 되는 자리다.
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

puts "monitoring-stack 렌더와 Grafana·datasource 기준선 검사 통과"
RUBY
