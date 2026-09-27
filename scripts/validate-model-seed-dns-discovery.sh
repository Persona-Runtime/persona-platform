#!/bin/sh
# 임시 모델 seed DNS discovery overlay를 렌더해, 관측 범위가 좁고 임시로 남는지 검사한다.
#
# 클러스터를 호출하지 않는다(kubectl은 로컬 렌더에만 쓴다). 통과는 "선언이 계약에 맞다"까지이며
# 실제 질의 호스트 관측의 증거가 아니다.
set -eu

for tool in kubectl ruby mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/persona-seed-dns-discovery.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
kubectl kustomize "$repo_dir/kustomize/overlays/discovery/persona-model-seed-dns" > "$work/discovery.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-model-cache" > "$work/seed.yaml"

ruby -ryaml - "$work/discovery.yaml" "$work/seed.yaml" "$repo_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
discovery_path, seed_path, repo_dir = ARGV
discovery = YAML.load_stream(File.read(discovery_path)).compact
seed = YAML.load_stream(File.read(seed_path)).compact

NAMESPACE = "persona-inference"
PREFIX = "dns-discovery-"
SEED_LABEL = "persona-vllm-model-seed"
DISCOVERY_SELECTOR = { "app.kubernetes.io/name" => SEED_LABEL, "persona.runtime/purpose" => "dns-discovery" }
KUBE_DNS = { "k8s:io.kubernetes.pod.namespace" => "kube-system", "k8s-app" => "kube-dns" }
DNS_PORTS = [{ "port" => "53", "protocol" => "UDP" }, { "port" => "53", "protocol" => "TCP" }]
HTTPS_PORTS = [{ "port" => "443", "protocol" => "TCP" }]

def one(resources, kind, label)
  found = resources.select { |r| r["kind"] == kind }
  raise "[안전] #{label}: #{kind}는 정확히 1개여야 한다: #{found.length}개" unless found.length == 1
  found.first
end

# --- 범위 ----------------------------------------------------------------
kinds = discovery.map { |r| r["kind"] }.sort
raise "[안전] discovery 렌더 kind는 ConfigMap·Job·CiliumNetworkPolicy만 허용한다: #{kinds.join(", ")}" unless kinds == %w[CiliumNetworkPolicy ConfigMap Job]
discovery.each do |r|
  name = r.dig("metadata", "name").to_s
  raise "[안전] discovery 리소스는 #{NAMESPACE} namespace다: #{name}" unless r.dig("metadata", "namespace") == NAMESPACE
  raise "[안전] discovery 리소스 이름은 #{PREFIX} 접두사로 seed 리소스와 구분한다: #{name}" unless name.start_with?(PREFIX)
end

# --- 임시 정책 -----------------------------------------------------------
policy = one(discovery, "CiliumNetworkPolicy", "discovery")
pspec = policy.fetch("spec")
raise "[안전] 임시 정책임을 annotation으로 표시한다" unless policy.dig("metadata", "annotations", "persona.runtime/lifecycle") == "temporary-remove-after-observation"
raise "[안전] 임시 정책은 seed 전용 label과 discovery label을 모두 가진 Pod만 고른다" unless pspec["endpointSelector"] == { "matchLabels" => DISCOVERY_SELECTOR }
raise "[안전] 임시 정책은 ingress를 열지 않는다" if pspec.key?("ingress") || pspec.key?("ingressDeny")
egress = pspec["egress"] || []
raise "[안전] 임시 정책 egress는 DNS·HTTPS 두 규칙뿐이다: #{egress.length}개" unless egress.length == 2
dns = egress.find { |rule| rule.key?("toEndpoints") } || raise("[안전] CoreDNS DNS 규칙이 없다")
raise "[안전] DNS 규칙 대상은 kube-system kube-dns뿐이다" unless dns["toEndpoints"] == [{ "matchLabels" => KUBE_DNS }]
dns_port_rules = dns["toPorts"] || []
raise "[안전] DNS 규칙은 UDP/TCP 53 하나의 포트 묶음이다" unless dns_port_rules.length == 1 && dns_port_rules.first["ports"] == DNS_PORTS
raise "[안전] DNS L7 matchPattern \"*\"가 있어야 질의 이름이 관측된다" unless dns_port_rules.first.dig("rules", "dns") == [{ "matchPattern" => "*" }]
https = egress.find { |rule| rule.key?("toEntities") } || raise("[안전] 임시 외부 HTTPS 규칙이 없다")
raise "[안전] 임시 외부 HTTPS는 world 443/TCP만이다" unless https["toEntities"] == ["world"] && https["toPorts"] == [{ "ports" => HTTPS_PORTS }]
egress.each do |rule|
  %w[toFQDNs toCIDR toCIDRSet toServices].each { |key| raise "[안전] 임시 정책에 #{key}를 두지 않는다 — 관측 전 추측 목록이 된다" if rule.key?(key) }
end

# --- discovery Job: seed와 같은 흐름, 저장만 emptyDir -----------------------
job = one(discovery, "Job", "discovery")
jspec = job.fetch("spec")
template = jspec.fetch("template")
pod = template.fetch("spec")
raise "[안전] discovery Pod는 seed 전용 label과 discovery label을 모두 가진다" unless DISCOVERY_SELECTOR.all? { |k, v| template.dig("metadata", "labels", k) == v }
raise "[안전] discovery Job backoffLimit은 0이다" unless jspec["backoffLimit"] == 0
raise "[안전] discovery Pod restartPolicy는 Never다" unless pod["restartPolicy"] == "Never"
deadline = jspec["activeDeadlineSeconds"]
raise "[안전] discovery Job에 7200초 이하의 activeDeadlineSeconds가 필요하다" unless deadline.is_a?(Integer) && deadline.positive? && deadline <= 7200
raise "[안전] discovery Pod는 RuntimeClass를 쓰지 않는다" if pod.key?("runtimeClassName")
volumes = pod.fetch("volumes")
raise "[안전] discovery Job은 PVC를 쓰지 않는다 — 현재 모델 cache를 건드리지 않는다" if volumes.any? { |v| v.key?("persistentVolumeClaim") }
raise "[안전] discovery Pod는 hostPath를 쓰지 않는다" if volumes.any? { |v| v.key?("hostPath") }
c = pod.fetch("containers").first
raise "[안전] discovery container는 하나다" unless pod.fetch("containers").length == 1
raise "[안전] discovery Job은 GPU(nvidia.com/gpu)를 요청하지 않는다" if [c.dig("resources", "requests"), c.dig("resources", "limits")].compact.any? { |r| r.key?("nvidia.com/gpu") }
env = (c["env"] || []).to_h { |e| [e["name"], e["value"]] }
raise "[안전] discovery TARGET_DIR은 /discovery다" unless env["TARGET_DIR"] == "/discovery"
mounts = (c["volumeMounts"] || []).to_h { |m| [m["mountPath"], m] }
raise "[안전] discovery mount는 /discovery·/tmp·/opt/persona-seed 셋뿐이다: #{mounts.keys.join(", ")}" unless mounts.keys.sort == ["/discovery", "/opt/persona-seed", "/tmp"]
target_volume = volumes.find { |v| v["name"] == mounts["/discovery"]["name"] } || {}
raise "[안전] /discovery는 sizeLimit이 있는 emptyDir다" unless target_volume.dig("emptyDir", "sizeLimit")

# "같은 다운로드 흐름"을 seed 렌더와 직접 대조한다.
seed_pod = one(seed, "Job", "seed").dig("spec", "template", "spec")
seed_c = seed_pod.fetch("containers").first
seed_env = (seed_c["env"] || []).to_h { |e| [e["name"], e["value"]] }
raise "[안전] discovery image가 seed Job과 다르다" unless c["image"] == seed_c["image"]
raise "[안전] discovery 명령이 seed Job과 다르다" unless c["command"] == seed_c["command"] && c["args"] == seed_c["args"]
%w[MODEL_ID MODEL_REVISION HOME HF_HOME HF_HUB_DISABLE_TELEMETRY].each do |key|
  raise "[안전] discovery env #{key}가 seed Job과 다르다" unless env[key] == seed_env[key]
end
%w[securityContext nodeSelector tolerations].each do |key|
  raise "[안전] discovery Pod #{key}가 seed Job과 다르다" unless pod[key] == seed_pod[key]
end
raise "[안전] discovery container securityContext가 seed Job과 다르다" unless c["securityContext"] == seed_c["securityContext"]
discovery_script = one(discovery, "ConfigMap", "discovery")
seed_script = one(seed, "ConfigMap", "seed")
raise "[안전] discovery 스크립트가 seed 스크립트와 다르다" unless discovery_script["data"] == seed_script["data"]
script_volume = volumes.find { |v| v["name"] == mounts["/opt/persona-seed"]["name"] } || {}
raise "[안전] discovery Job이 discovery ConfigMap을 가리키지 않는다" unless script_volume.dig("configMap", "name") == discovery_script.dig("metadata", "name")
raise "[안전] discovery ConfigMap 이름이 seed ConfigMap과 같다 — discovery를 지우면 seed 스크립트도 지워진다" if discovery_script.dig("metadata", "name") == seed_script.dig("metadata", "name")

# --- 임시로 남는가 --------------------------------------------------------
Dir.glob(File.join(repo_dir, "argocd", "**", "*.{yaml,yml}")).sort.each do |path|
  text = File.read(path)
  raise "[안전] Argo 선언이 임시 discovery overlay를 참조한다: #{File.basename(path)}" if text.include?("overlays/discovery") || text.include?("persona-model-seed-dns")
end
Dir.glob(File.join(repo_dir, "kustomize", "overlays", "prod", "**", "kustomization.yaml")).sort.each do |path|
  raise "[안전] prod overlay가 임시 discovery를 포함한다: #{path.sub(repo_dir + "/", "")}" if File.read(path).include?("discovery")
end
# 임시 world 443 허용을 영구 정책으로 옮기지 않는다(영구 정책은 관측한 이름만 toFQDNs로 적는다).
Dir.glob(File.join(repo_dir, "kustomize", "base", "networkpolicy", "persona-inference", "*")).sort.each do |path|
  next unless File.file?(path)
  document_text = File.read(path).lines.reject { |line| line.lstrip.start_with?("#") }.join
  raise "[안전] persona-inference 영구 정책(초안 포함)에 world entity가 있다 — 임시 허용을 승격하지 않는다: #{File.basename(path)}" if document_text.match?(/toEntities|\bworld\b/)
end

puts "모델 seed DNS discovery overlay 검사 통과(임시, Argo 미등록, cache PVC 미사용, 클러스터 미접근)"
RUBY
