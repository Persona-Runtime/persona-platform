#!/bin/sh
# vLLM overlay(Deployment·Service·PodMonitor)를 렌더하고 서빙 계약을 검사한다.
#
# 클러스터를 호출하지 않는다(kubectl은 로컬 렌더에만 쓴다). 통과는 "선언이 계약에 맞다"까지이며
# vLLM 기동·GPU 적재·메트릭 수집의 증거가 아니다.
set -eu

for tool in kubectl ruby mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/persona-vllm.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-vllm" > "$work/vllm.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-inference-netpol" > "$work/netpol.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-model-cache" > "$work/model-cache.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-app" > "$work/app.yaml"

ruby -ryaml - "$work" "$repo_dir/argocd" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
work, argocd_dir = ARGV
load = ->(name) { YAML.load_stream(File.read(File.join(work, name))).compact }
vllm = load.call("vllm.yaml")
netpol = load.call("netpol.yaml")
model_cache = load.call("model-cache.yaml")
app = load.call("app.yaml")

NAMESPACE = "persona-inference"
IMAGE = "vllm/vllm-openai@sha256:51b1042786c1bb7ab640fd05e4a2b19ae41662959387cc07e1c3106ae2a851b8"
MODEL_DIR = "/models/Qwen/Qwen3-4B-Instruct-2507/cdbee75f17c01a7cc42f958dc650907174af0554"
SERVED_NAME = "Qwen/Qwen3-4B-Instruct-2507"
POD_LABEL = { "app.kubernetes.io/name" => "persona-vllm" }
GPU_SELECTOR = { "personaruntime.xyz/node-pool" => "gpu" }
GPU_TOLERATION = { "key" => "personaruntime.xyz/dedicated", "operator" => "Equal", "value" => "gpu-serving", "effect" => "NoSchedule" }
PVC = "persona-vllm-model-cache"
SEED_FILES = %w[.persona-seed-complete.json .persona-seed-manifest.json model.safetensors.index.json]

def one(resources, kind)
  found = resources.select { |r| r["kind"] == kind }
  raise "[안전] #{kind}는 정확히 1개여야 한다: #{found.length}개" unless found.length == 1
  found.first
end

def env_map(container)
  (container["env"] || []).to_h { |e| [e["name"], e["value"]] }
end

# 인자 목록에서 flag 다음 값을 읽는다(`--flag value` 형식만 쓴다).
def flag_value(args, flag)
  index = args.index(flag)
  index && args[index + 1]
end

# --- 범위 ----------------------------------------------------------------
kinds = vllm.map { |r| r["kind"] }.sort
raise "[안전] vLLM 렌더 kind는 Deployment·Service·PodMonitor만 허용한다(Namespace는 만들지 않는다): #{kinds.join(", ")}" unless kinds == %w[Deployment PodMonitor Service]
vllm.each { |r| raise "[안전] #{r["kind"]}는 #{NAMESPACE} namespace다" unless r.dig("metadata", "namespace") == NAMESPACE }

# --- Deployment ----------------------------------------------------------
deploy = one(vllm, "Deployment")
dspec = deploy.fetch("spec")
raise "[안전] vLLM replicas는 1이다 — GPU 노드의 GPU는 한 장이다" unless dspec["replicas"] == 1
raise "[안전] vLLM strategy는 Recreate다 — RollingUpdate면 새 Pod가 기존 Pod의 GPU 한 장을 기다리며 Pending될 수 있다" unless dspec.dig("strategy", "type") == "Recreate" && !dspec["strategy"].key?("rollingUpdate")
raise "[안전] Deployment selector는 persona-vllm name label이다" unless dspec.dig("selector", "matchLabels") == POD_LABEL
template = dspec.fetch("template")
pod = template.fetch("spec")
raise "[안전] Pod label은 persona-vllm이다" unless template.dig("metadata", "labels", "app.kubernetes.io/name") == "persona-vllm"
raise "[안전] vLLM Pod는 RuntimeClass nvidia를 쓴다" unless pod["runtimeClassName"] == "nvidia"
raise "[안전] vLLM Pod는 GPU 노드 node-pool selector가 필요하다" unless pod["nodeSelector"] == GPU_SELECTOR
raise "[안전] vLLM Pod는 GPU 전용 taint toleration 하나만 가진다" unless pod["tolerations"] == [GPU_TOLERATION]
raise "[안전] vLLM Pod는 service account token을 mount하지 않는다" unless pod["automountServiceAccountToken"] == false
%w[hostNetwork hostPID hostIPC].each { |key| raise "[안전] vLLM Pod는 #{key}를 쓰지 않는다" if pod[key] }
psec = pod["securityContext"] || {}
raise "[안전] vLLM Pod는 non-root 10001/10001, fsGroup 10001로 실행한다" unless psec["runAsNonRoot"] == true && psec["runAsUser"] == 10_001 && psec["runAsGroup"] == 10_001 && psec["fsGroup"] == 10_001
raise "[안전] vLLM Pod는 RuntimeDefault seccomp가 필요하다" unless psec.dig("seccompProfile", "type") == "RuntimeDefault"

volumes = (pod["volumes"] || []).to_h { |v| [v["name"], v] }
raise "[안전] vLLM Pod는 hostPath를 쓰지 않는다" if volumes.values.any? { |v| v.key?("hostPath") }

def check_container_security(container, label)
  sec = container["securityContext"] || {}
  raise "[안전] #{label}: privilege escalation을 막는다" unless sec["allowPrivilegeEscalation"] == false
  raise "[안전] #{label}: root filesystem은 read-only다" unless sec["readOnlyRootFilesystem"] == true
  raise "[안전] #{label}: 모든 capability를 drop한다" unless sec.dig("capabilities", "drop") == ["ALL"]
  raise "[안전] #{label}: privileged가 아니다" if sec["privileged"]
  raise "[안전] #{label}: image는 검증한 vLLM digest다" unless container["image"] == IMAGE
end

def check_models_mount(container, volumes, label)
  mount = (container["volumeMounts"] || []).find { |m| m["mountPath"] == "/models" } || raise("[안전] #{label}: /models mount가 없다")
  raise "[안전] #{label}: /models는 readOnly로 mount한다" unless mount["readOnly"] == true
  volume = volumes[mount["name"]] || {}
  raise "[안전] #{label}: /models는 #{PVC} PVC다" unless volume.dig("persistentVolumeClaim", "claimName") == PVC
  raise "[안전] #{label}: /models PVC는 readOnly다" unless volume.dig("persistentVolumeClaim", "readOnly") == true
end

# initContainer: seed 완료 확인만, GPU 없이.
inits = pod["initContainers"] || []
raise "[안전] initContainer는 verify-model-cache 하나다" unless inits.map { |c| c["name"] } == ["verify-model-cache"]
init = inits.first
check_container_security(init, "verify-model-cache")
check_models_mount(init, volumes, "verify-model-cache")
script = Array(init["command"]).join("\n") + Array(init["args"]).join("\n")
SEED_FILES.each { |name| raise "[안전] initContainer가 #{name}을 확인하지 않는다" unless script.include?(name) }
raise "[안전] initContainer가 모델 경로를 확인하지 않는다" unless script.include?(MODEL_DIR)
raise "[안전] initContainer가 없는 파일에서 실패하지 않는다(exit 1)" unless script.include?("exit 1")
raise "[안전] initContainer는 GPU를 요청하지 않는다" if [init.dig("resources", "requests"), init.dig("resources", "limits")].compact.any? { |r| r.key?("nvidia.com/gpu") }
raise "[안전] initContainer에 NVIDIA_VISIBLE_DEVICES=void가 필요하다 — image 기본값(all)이면 GPU가 노출될 수 있다" unless env_map(init)["NVIDIA_VISIBLE_DEVICES"] == "void"

# vLLM container.
containers = pod.fetch("containers")
raise "[안전] vLLM Pod container는 vllm 하나다" unless containers.map { |c| c["name"] } == ["vllm"]
c = containers.first
check_container_security(c, "vllm")
check_models_mount(c, volumes, "vllm")
raise "[안전] vLLM은 로컬 절대 모델 경로로 serve한다" unless c["command"] == ["vllm", "serve", MODEL_DIR]
args = c["args"] || []
raise "[안전] --served-model-name은 #{SERVED_NAME}다" unless flag_value(args, "--served-model-name") == SERVED_NAME
raise "[안전] vLLM port는 8000이다" unless flag_value(args, "--port") == "8000"
raise "[기준선] --max-model-len은 4096이다(서빙 기준선)" unless flag_value(args, "--max-model-len") == "4096"
raise "[기준선] --gpu-memory-utilization 초기값은 0.85다" unless flag_value(args, "--gpu-memory-utilization") == "0.85"
raise "[안전] --disable-log-requests는 vLLM v0.29.0에 없는 인자다 — 기동이 실패한다" if args.include?("--disable-log-requests")
raise "[안전] 요청 로그를 켜지 않는다(--enable-log-requests 금지)" if args.include?("--enable-log-requests")
raise "[안전] 요청 로그 꺼짐을 --no-enable-log-requests로 명시한다" unless args.include?("--no-enable-log-requests")
env = env_map(c)
{ "HF_HUB_OFFLINE" => "1", "TRANSFORMERS_OFFLINE" => "1", "VLLM_NO_USAGE_STATS" => "1" }.each do |key, value|
  raise "[안전] #{key}=#{value}가 필요하다 — 재시작 때 외부 다운로드·telemetry에 기대지 않는다" unless env[key] == value
end
%w[HF_TOKEN HUGGING_FACE_HUB_TOKEN].each { |key| raise "[안전] vLLM에 #{key}를 두지 않는다" if env.key?(key) }
requests = c.dig("resources", "requests") || {}
limits = c.dig("resources", "limits") || {}
raise "[안전] vLLM은 GPU 1장을 requests·limits 모두 요청한다" unless requests["nvidia.com/gpu"] == 1 && limits["nvidia.com/gpu"] == 1
raise "[기준선] vLLM memory limit이 필요하다" unless limits["memory"]
port = (c["ports"] || []).find { |p| p["name"] == "http" } || raise("[안전] vLLM에 http 포트가 없다")
raise "[안전] http 포트는 TCP 8000이다" unless port["containerPort"] == 8000 && port.fetch("protocol", "TCP") == "TCP"

%w[startupProbe readinessProbe livenessProbe].each do |probe|
  spec = c[probe] || raise("[안전] vLLM #{probe}가 없다")
  raise "[안전] #{probe}는 http 포트 /health다" unless spec.dig("httpGet", "path") == "/health" && spec.dig("httpGet", "port") == "http"
end
startup = c["startupProbe"]
startup_window = startup.fetch("periodSeconds", 10) * startup.fetch("failureThreshold", 3)
raise "[기준선] startupProbe 허용 시간은 모델 적재를 고려해 300초 이상이다(현재 #{startup_window}초)" unless startup_window >= 300

mounts = (c["volumeMounts"] || []).to_h { |m| [m["mountPath"], m] }
tmp = volumes[(mounts["/tmp"] || {})["name"]] || {}
raise "[안전] /tmp는 emptyDir다" unless tmp.key?("emptyDir")
shm = volumes[(mounts["/dev/shm"] || {})["name"]] || {}
raise "[안전] /dev/shm은 Memory emptyDir다" unless shm.dig("emptyDir", "medium") == "Memory"
raise "[안전] vLLM mount는 /models·/tmp·/dev/shm 셋뿐이다: #{mounts.keys.join(", ")}" unless mounts.keys.sort == ["/dev/shm", "/models", "/tmp"]

# --- Service·PodMonitor --------------------------------------------------
service = one(vllm, "Service")
raise "[안전] Service 이름은 persona-vllm이다(Gateway 계획 URL)" unless service.dig("metadata", "name") == "persona-vllm"
raise "[안전] Service는 ClusterIP다" unless service.dig("spec", "type") == "ClusterIP"
raise "[안전] Service selector는 Pod label과 같다" unless service.dig("spec", "selector") == POD_LABEL
sports = service.dig("spec", "ports") || []
raise "[안전] Service는 http 8000 하나를 targetPort http로 연다" unless sports == [{ "name" => "http", "protocol" => "TCP", "port" => 8000, "targetPort" => "http" }]

monitor = one(vllm, "PodMonitor")
mspec = monitor.fetch("spec")
raise "[안전] PodMonitor에 release=monitoring-stack label이 있어야 Prometheus가 고른다" unless monitor.dig("metadata", "labels", "release") == "monitoring-stack"
raise "[안전] PodMonitor namespaceSelector는 #{NAMESPACE}만이다" unless mspec["namespaceSelector"] == { "matchNames" => [NAMESPACE] }
raise "[안전] PodMonitor selector는 Pod label과 같다" unless mspec["selector"] == { "matchLabels" => POD_LABEL }
endpoints = mspec["podMetricsEndpoints"] || []
raise "[안전] PodMonitor는 http 포트 /metrics 하나를 30s/10s로 수집한다" unless endpoints == [{ "port" => "http", "path" => "/metrics", "scheme" => "http", "interval" => "30s", "scrapeTimeout" => "10s" }]

# --- 다른 선언과의 일치 ----------------------------------------------------
# persona-inference NetworkPolicy(미적용)가 가정한 label·포트와 맞아야 적용 뒤 통신이 열린다.
vllm_policies = netpol.select { |p| p.dig("spec", "podSelector", "matchLabels") == POD_LABEL }
raise "[안전] persona-inference NetworkPolicy가 persona-vllm label을 고르지 않는다" if vllm_policies.empty?
ingress_ports = vllm_policies.flat_map { |p| (p.dig("spec", "ingress") || []).flat_map { |i| i["ports"] || [] } }.map { |p| p["port"] }.uniq
raise "[안전] NetworkPolicy 인입 포트(#{ingress_ports.join(", ")})가 vLLM 8000과 다르다" unless ingress_ports == [8000]
pvc = model_cache.find { |r| r["kind"] == "PersistentVolumeClaim" } || {}
raise "[안전] 모델 cache overlay에 #{PVC} PVC가 없다" unless pvc.dig("metadata", "name") == PVC && pvc.dig("metadata", "namespace") == NAMESPACE
raise "[안전] vLLM overlay는 Namespace를 만들지 않는다 — 모델 cache overlay가 소유한다" unless model_cache.any? { |r| r["kind"] == "Namespace" && r.dig("metadata", "name") == NAMESPACE }

# 이번 변경은 Gateway를 건드리지 않는다 — 계속 mock이어야 한다.
gateway = app.find { |r| r["kind"] == "Deployment" && r.dig("metadata", "name") == "persona-gateway" } || raise("[안전] persona-gateway Deployment가 없다")
gateway_env = env_map(gateway.dig("spec", "template", "spec", "containers").first)
raise "[안전] Gateway PERSONA_CHAT_INFERENCE_MODE는 mock 그대로다 — LLM mode 전환은 별도 단계다" unless gateway_env["PERSONA_CHAT_INFERENCE_MODE"] == "mock"

Dir.glob(File.join(argocd_dir, "**", "*.{yaml,yml}")).sort.each do |path|
  raise "[안전] Argo 선언이 persona-vllm overlay를 참조한다: #{File.basename(path)}" if File.read(path).include?("overlays/prod/persona-vllm")
end

puts "vLLM overlay 렌더와 서빙 계약 검사 통과(정적 검사만, 클러스터 미접근, Argo 미등록)"
RUBY
