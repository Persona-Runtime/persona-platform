#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
rendered_file=$(mktemp "${TMPDIR:-/tmp}/persona-mock-sse.XXXXXX.yaml")
trap 'rm -f "$rendered_file"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/mock-sse" > "$rendered_file"

ruby -ryaml - "$rendered_file" "$repo_dir/argocd/persona-mock-sse.yaml" "$repo_dir/bootstrap/namespaces/persona-mock-sse.yaml" <<'RUBY'
rendered_path, application_path, namespace_path = ARGV
resources = YAML.load_stream(File.read(rendered_path)).compact

def resource(resources, kind, name)
  resources.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("missing #{kind}/#{name}")
end

deployment = resource(resources, "Deployment", "persona-mock-sse")
raise "Argo overlay must not manage the bootstrap Namespace" if resources.any? { |item| item["kind"] == "Namespace" }
spec = deployment.fetch("spec")
raise "mock SSE must have one replica" unless spec["replicas"] == 1
raise "mock SSE must use a zero-surge rollout" unless spec.dig("strategy", "rollingUpdate", "maxSurge") == 0

pod_spec = spec.dig("template", "spec")
raise "service account token mount must be disabled" unless pod_spec["automountServiceAccountToken"] == false
raise "termination grace period must be 15 seconds" unless pod_spec["terminationGracePeriodSeconds"] == 15
raise "GHCR pull Secret is missing" unless pod_spec["imagePullSecrets"] == [{"name" => "persona-mock-sse-ghcr"}]
raise "RuntimeDefault seccomp is required" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"

nodes = pod_spec.dig("affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values")
raise "mock SSE must target only home workers" unless nodes == ["k8s-worker1", "k8s-worker2"]

container = pod_spec.fetch("containers").find { |item| item["name"] == "mock-sse" } || raise("mock-sse container missing")
image = container.fetch("image")
valid_digest = %r{\Aghcr\.io/persona-runtime/persona-mock-sse@sha256:[0-9a-f]{64}\z}
placeholder = "ghcr.io/persona-runtime/persona-mock-sse@sha256:REPLACE_WITH_LINUX_AMD64_MANIFEST_DIGEST"
raise "image must be a GHCR digest or the explicit deployment placeholder" unless image == placeholder || valid_digest.match?(image)
raise "container port must be 8080" unless container.dig("ports", 0, "containerPort") == 8080
raise "grace period must be passed to the server" unless container.dig("env", 0, "name") == "MOCK_SSE_GRACE_PERIOD_SECONDS" && container.dig("env", 0, "value") == "5"
security = container.fetch("securityContext")
raise "container must run non-root" unless security["runAsNonRoot"] == true && security["runAsUser"] == 10_001
raise "privilege escalation must be disabled" unless security["allowPrivilegeEscalation"] == false
raise "all Linux capabilities must be dropped" unless security.dig("capabilities", "drop") == ["ALL"]
raise "root filesystem must be read-only" unless security["readOnlyRootFilesystem"] == true
raise "health startup probe missing" unless container.dig("startupProbe", "httpGet", "path") == "/healthz"
raise "health liveness probe missing" unless container.dig("livenessProbe", "httpGet", "path") == "/healthz"
raise "readiness probe missing" unless container.dig("readinessProbe", "httpGet", "path") == "/readyz"

service = resource(resources, "Service", "persona-mock-sse")
raise "Service must be ClusterIP" unless service.dig("spec", "type") == "ClusterIP"
raise "Service must expose port 8080" unless service.dig("spec", "ports", 0, "port") == 8080

gateway = resource(resources, "Gateway", "persona-mock-sse")
raise "Gateway must use Traefik" unless gateway.dig("spec", "gatewayClassName") == "traefik"
listener = gateway.dig("spec", "listeners", 0)
raise "Gateway must use Traefik's HTTP entryPoint port 8000" unless listener["name"] == "http" && listener["protocol"] == "HTTP" && listener["port"] == 8000

route = resource(resources, "HTTPRoute", "persona-mock-sse")
match = route.dig("spec", "rules", 0, "matches", 0)
raise "Route must expose POST only" unless match["method"] == "POST"
raise "Route must preserve the exact mock chat path" unless match.dig("path", "type") == "Exact" && match.dig("path", "value") == "/mock/chat"
raise "Route must target the mock Service" unless route.dig("spec", "rules", 0, "backendRefs", 0, "name") == "persona-mock-sse" && route.dig("spec", "rules", 0, "backendRefs", 0, "port") == 8080

application = YAML.load_file(application_path)
raise "Argo Application kind is invalid" unless application["kind"] == "Application"
app_spec = application.fetch("spec")
raise "Argo Application must target the main branch" unless app_spec.dig("source", "targetRevision") == "main"
raise "Argo Application must point to the mock SSE overlay" unless app_spec.dig("source", "path") == "kustomize/overlays/prod/mock-sse"
raise "Argo Application must not enable sync automation" if app_spec.key?("syncPolicy")

namespace = YAML.load_file(namespace_path)
raise "bootstrap Namespace kind is invalid" unless namespace["kind"] == "Namespace"
raise "bootstrap Namespace name is invalid" unless namespace.dig("metadata", "name") == "persona-mock-sse"

puts "mock SSE Kustomize render and manifest policy checks passed"
puts "image digest is still an intentional deployment placeholder" if image == placeholder
RUBY
