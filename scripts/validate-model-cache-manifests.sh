#!/bin/sh
# 모델 cache overlay(persona-inference Namespace, model cache PVC, seed Job)를 렌더하고 계약을 검사한다.
#
# 클러스터를 호출하지 않는다(kubectl은 로컬 렌더에만 쓴다). 통과는 "선언이 계약에 맞다"까지이며
# seed 성공·다운로드 호스트·PVC Bound의 증거가 아니다.
set -eu

for tool in kubectl ruby mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
rendered=$(mktemp "${TMPDIR:-/tmp}/persona-model-cache.XXXXXX")
trap 'rm -f "$rendered"' EXIT HUP INT TERM
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-model-cache" > "$rendered"

ruby -ryaml - "$rendered" "$repo_dir/argocd" "$repo_dir/bootstrap/namespaces" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
rendered_path, argocd_dir, bootstrap_namespaces_dir = ARGV
resources = YAML.load_stream(File.read(rendered_path)).compact

NAMESPACE = "persona-inference"
IMAGE = "vllm/vllm-openai@sha256:51b1042786c1bb7ab640fd05e4a2b19ae41662959387cc07e1c3106ae2a851b8"
MODEL_ID = "Qwen/Qwen3-4B-Instruct-2507"
MODEL_REVISION = "cdbee75f17c01a7cc42f958dc650907174af0554"
SEED_LABEL = "persona-vllm-model-seed"
GPU_SELECTOR = { "personaruntime.xyz/node-pool" => "gpu" }
GPU_TOLERATION = { "key" => "personaruntime.xyz/dedicated", "operator" => "Equal", "value" => "gpu-serving", "effect" => "NoSchedule" }
MAX_DEADLINE_SECONDS = 7200

def one(resources, kind)
  found = resources.select { |r| r["kind"] == kind }
  raise "[안전] #{kind}는 정확히 1개여야 한다: #{found.length}개" unless found.length == 1
  found.first
end

# 이번 overlay는 seed까지만 담는다. vLLM·NetworkPolicy·Service가 섞이면 적용 순서와 원인 분리가 깨진다.
kinds = resources.map { |r| r["kind"] }.sort
raise "[안전] 렌더 kind는 Namespace·ConfigMap·PersistentVolumeClaim·Job만 허용한다: #{kinds.uniq.join(", ")}" unless kinds == %w[ConfigMap Job Namespace PersistentVolumeClaim]
resources.reject { |r| r["kind"] == "Namespace" }.each do |r|
  raise "[안전] #{r["kind"]}/#{r.dig("metadata", "name")}는 #{NAMESPACE} namespace여야 한다" unless r.dig("metadata", "namespace") == NAMESPACE
end
raise "[안전] Namespace 이름은 #{NAMESPACE}다" unless one(resources, "Namespace").dig("metadata", "name") == NAMESPACE

# --- PVC -----------------------------------------------------------------
pvc = one(resources, "PersistentVolumeClaim")
pspec = pvc.fetch("spec")
raise "[안전] PVC 이름은 persona-vllm-model-cache다" unless pvc.dig("metadata", "name") == "persona-vllm-model-cache"
raise "[기준선] PVC StorageClass는 local-path다 — GPU 노드 로컬 디스크에 고정한다" unless pspec["storageClassName"] == "local-path"
raise "[안전] PVC는 ReadWriteOnce만 쓴다 — seed와 vLLM을 동시에 붙이지 않는다" unless pspec["accessModes"] == ["ReadWriteOnce"]
raise "[기준선] PVC 크기는 40Gi다 — local-path는 나중에 늘릴 수 없다" unless pspec.dig("resources", "requests", "storage") == "40Gi"

# --- seed Job ------------------------------------------------------------
job = one(resources, "Job")
jspec = job.fetch("spec")
raise "[안전] seed Job backoffLimit은 0이다 — 실패를 재시도로 덮지 않는다" unless jspec["backoffLimit"] == 0
deadline = jspec["activeDeadlineSeconds"]
raise "[안전] seed Job에 #{MAX_DEADLINE_SECONDS}초 이하의 activeDeadlineSeconds가 필요하다" unless deadline.is_a?(Integer) && deadline.positive? && deadline <= MAX_DEADLINE_SECONDS
raise "[안전] 완료·실패한 seed Job과 로그를 자동 삭제하지 않는다" if jspec.key?("ttlSecondsAfterFinished")

template = jspec.fetch("template")
pod = template.fetch("spec")
raise "[안전] seed Pod label은 #{SEED_LABEL}이다 — vLLM label과 섞이면 vLLM 정책이 seed에도 걸린다" unless template.dig("metadata", "labels", "app.kubernetes.io/name") == SEED_LABEL
raise "[안전] seed Pod restartPolicy는 Never다" unless pod["restartPolicy"] == "Never"
raise "[안전] seed Pod는 service account token을 mount하지 않는다" unless pod["automountServiceAccountToken"] == false
raise "[안전] seed Pod는 GPU 노드 node-pool selector가 필요하다 — PVC가 GPU 노드에 고정돼야 한다" unless pod["nodeSelector"] == GPU_SELECTOR
raise "[안전] seed Pod는 GPU 전용 taint toleration 하나만 가진다" unless pod["tolerations"] == [GPU_TOLERATION]
raise "[안전] seed Pod는 RuntimeClass(nvidia)를 쓰지 않는다 — GPU가 필요 없는 Job이다" if pod.key?("runtimeClassName")
%w[hostNetwork hostPID hostIPC].each { |key| raise "[안전] seed Pod는 #{key}를 쓰지 않는다" if pod[key] }
psec = pod["securityContext"] || {}
raise "[안전] seed Pod는 runAsNonRoot·runAsUser 10001·runAsGroup 10001로 실행한다" unless psec["runAsNonRoot"] == true && psec["runAsUser"] == 10_001 && psec["runAsGroup"] == 10_001
raise "[안전] seed Pod는 RuntimeDefault seccomp가 필요하다" unless psec.dig("seccompProfile", "type") == "RuntimeDefault"
# non-root·read-only smoke가 통과한 권한 조건과 같게 둔다(/tmp/hf-home 등 볼륨 group 소유).
raise "[안전] seed Pod fsGroup은 10001이다 — 실측 smoke와 같은 권한 조건이어야 한다" unless psec["fsGroup"] == 10_001

containers = pod.fetch("containers")
raise "[안전] seed Pod container는 하나다" unless containers.length == 1 && !pod.key?("initContainers")
c = containers.first
raise "[안전] seed image는 검증한 vLLM linux/amd64 digest다 — tag로 바꾸지 않는다" unless c["image"] == IMAGE
raise "[안전] seed 명령은 python3 /opt/persona-seed/seed_model.py다" unless c["command"] == ["python3", "/opt/persona-seed/seed_model.py"] && c["args"].nil?
env = (c["env"] || []).to_h { |e| [e["name"], e["value"]] }
raise "[안전] MODEL_ID는 #{MODEL_ID}다" unless env["MODEL_ID"] == MODEL_ID
raise "[안전] MODEL_REVISION은 고정 commit #{MODEL_REVISION}이다 — branch·짧은 해시는 재현성이 없다" unless env["MODEL_REVISION"] == MODEL_REVISION
raise "[안전] TARGET_DIR은 /models다" unless env["TARGET_DIR"] == "/models"
%w[HF_TOKEN HUGGING_FACE_HUB_TOKEN].each { |key| raise "[안전] seed Job에 #{key}를 두지 않는다(gated 모델이 아니다)" if env.key?(key) }
all_resources = [c.dig("resources", "requests"), c.dig("resources", "limits")].compact
raise "[안전] seed Job은 GPU(nvidia.com/gpu)를 요청하지 않는다" if all_resources.any? { |r| r.key?("nvidia.com/gpu") }
raise "[기준선] seed container에 cpu·memory limit이 필요하다" unless c.dig("resources", "limits", "cpu") && c.dig("resources", "limits", "memory")
csec = c["securityContext"] || {}
raise "[안전] seed container는 privilege escalation을 막는다" unless csec["allowPrivilegeEscalation"] == false
raise "[안전] seed container root filesystem은 read-only다" unless csec["readOnlyRootFilesystem"] == true
raise "[안전] seed container는 모든 capability를 drop한다" unless csec.dig("capabilities", "drop") == ["ALL"]
raise "[안전] seed container는 privileged가 아니다" if csec["privileged"]

# 쓰기 가능한 곳은 /models(PVC)와 /tmp(emptyDir)뿐이다. 스크립트는 read-only ConfigMap이다.
volumes = (pod["volumes"] || []).to_h { |v| [v["name"], v] }
raise "[안전] seed Pod는 hostPath volume을 쓰지 않는다" if volumes.values.any? { |v| v.key?("hostPath") }
mounts = (c["volumeMounts"] || []).to_h { |m| [m["mountPath"], m] }
raise "[안전] seed mount는 /models·/tmp·/opt/persona-seed 셋뿐이다: #{mounts.keys.join(", ")}" unless mounts.keys.sort == ["/models", "/opt/persona-seed", "/tmp"]
models = volumes[mounts["/models"]["name"]] || {}
raise "[안전] /models는 persona-vllm-model-cache PVC다" unless models.dig("persistentVolumeClaim", "claimName") == "persona-vllm-model-cache"
tmp = volumes[mounts["/tmp"]["name"]] || {}
raise "[안전] /tmp는 emptyDir다" unless tmp.key?("emptyDir")
script = volumes[mounts["/opt/persona-seed"]["name"]] || {}
raise "[안전] seed 스크립트 mount는 read-only ConfigMap이다" unless mounts["/opt/persona-seed"]["readOnly"] == true && script.key?("configMap")

configmap = one(resources, "ConfigMap")
raise "[안전] Job이 렌더된 seed 스크립트 ConfigMap을 가리키지 않는다" unless script.dig("configMap", "name") == configmap.dig("metadata", "name")
source = configmap.dig("data", "seed_model.py").to_s
["snapshot_download", "files_metadata=True", "verify_directory", "MARKER_NAME"].each do |needle|
  raise "[안전] seed 스크립트에 무결성 검증 단계(#{needle})가 없다" unless source.include?(needle)
end

# --- 경계 ----------------------------------------------------------------
# 첫 seed는 사람이 적용하고 결과·다운로드 호스트를 기록한다. Application이 가리키면 Sync 한 번으로 돈다.
Dir.glob(File.join(argocd_dir, "**", "*.{yaml,yml}")).sort.each do |path|
  raise "[안전] Argo 선언이 persona-model-cache overlay를 참조한다: #{File.basename(path)}" if File.read(path).include?("persona-model-cache")
end
# Namespace 소유자는 이 overlay 하나다.
Dir.glob(File.join(bootstrap_namespaces_dir, "*.yaml")).sort.each do |path|
  raise "[안전] bootstrap에도 #{NAMESPACE} Namespace가 있다 — 소유자를 하나로 둔다: #{File.basename(path)}" if YAML.load_file(path).dig("metadata", "name") == NAMESPACE
end

puts "모델 cache overlay 렌더와 seed Job 계약 검사 통과(Argo 미등록, 클러스터 미접근)"
RUBY
