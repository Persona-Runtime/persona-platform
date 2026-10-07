#!/usr/bin/env bash
# persona 폐기(26A) 전 읽기 전용 인벤토리 — 홈 CP(k8s-cp)에서 사람이 실행한다.
#
# 무엇을 하나: 지울 대상(persona 앱·DB·그 PVC/PV·NetworkPolicy·Route·NFS)과 지킬 대상(Gateway·TLS·
# persona-edge·vLLM·모델 캐시·공용)을 정확한 이름으로 확정할 수 있게 현재 상태와 참조 관계를 모은다.
# 클러스터에는 get·config view만 보낸다. apply·patch·delete·exec·port-forward를 쓰지 않는다.
#
# 결과(실행마다 새 디렉터리, 이전 결과를 덮어쓰지 않는다):
#   <PERSONA_RETIRE_OUTPUT_ROOT>/<run-id>/00_run_info.txt   실행 시각·context·스크립트 SHA256
#   <PERSONA_RETIRE_OUTPUT_ROOT>/<run-id>/manifest.tsv      조회별 분류(required/optional)·종료 코드
#   <PERSONA_RETIRE_OUTPUT_ROOT>/<run-id>/<조회이름>.txt    조회 결과(첫 줄 command, 끝 줄 exit_code)
#   <PERSONA_RETIRE_OUTPUT_ROOT>/<run-id>/90_references.txt 참조 관계 요약(지울/지킬 판단 재료)
# 기본 출력 위치는 이 checkout의 runbooks/transition/retire-persona/out(gitignore)이다.
#
# 종료 코드: 0 정상, 1 required 조회 실패, 2 설정 오류(context 불일치 등), 3 결과에 공인 IP·비밀 모양 발견.
# 3이면 결과 파일을 공유하지 말고 어느 파일·몇째 줄인지(값 없이)만 보고 원인을 고친다.
#
# 민감 정보 경계:
# - Secret은 namespace·이름·type만 읽는다(custom-columns). -o yaml/json·describe를 쓰지 않는다.
# - ConfigMap은 이름만 읽는다.
# - Pod·NetworkPolicy처럼 필드를 골라야 하는 객체는 -o json을 메모리(파이프)로만 받아 필요한 필드만
#   남긴다. 원본 JSON은 파일로 쓰지 않는다(Pod env에 값이 들어 있을 수 있다).
# - IP 필드(podIP·hostIP·loadBalancer·externalIPs)는 고르지 않는다. 그래도 끝에서 출력 전체를 훑어
#   사설 대역이 아닌 IPv4와 비밀 모양(PRIVATE KEY·JWT·data:/stringData:)이 있으면 3으로 끝낸다.
#
# 사용법(CP, 이 checkout 루트에서):
#   bash scripts/inventory/persona_retire.sh
#   PERSONA_RETIRE_KUBE_CONTEXT=<context> PERSONA_RETIRE_KUBE_SERVER=<API server URL> bash scripts/inventory/persona_retire.sh
#
# 설정 환경변수:
#   PERSONA_RETIRE_KUBE_CONTEXT     모든 kubectl 호출의 context. 기본 kubernetes-admin@kubernetes
#   PERSONA_RETIRE_KUBE_SERVER      있으면 그 context의 API server URL이 이 값과 같아야 한다(다른 클러스터 방지)
#   PERSONA_RETIRE_REQUEST_TIMEOUT  kubectl --request-timeout. 기본 20s. <양의 정수>s|m만 허용
#   PERSONA_RETIRE_OUTPUT_ROOT      run 디렉터리를 만들 상위 폴더
#   PERSONA_RETIRE_KUBECTL          kubectl 실행 파일(테스트용 가짜 kubectl 주입). 기본 kubectl

set -u
set -o pipefail
# 수집 결과에는 내부 구성 정보가 담기므로 다른 사용자가 읽지 못하게 한다.
umask 077

readonly DEFAULT_KUBE_CONTEXT="kubernetes-admin@kubernetes"
# 폐기·유지 판단과 닿는 namespace. persona-inference(vLLM·모델 캐시)와 traefik(공개 진입)은 지킬 대상이다.
readonly NAMESPACES=(persona-app persona-data persona-edge persona-inference persona-mock-sse traefik default)
# 없는 것이 정상일 수 있는 namespace(이미 정리했거나 쓰지 않음). 조회 실패를 optional로 기록한다.
readonly OPTIONAL_NAMESPACES=" persona-mock-sse default "
# namespace별로 이름·소유 관계만 보는 종류. Secret·ConfigMap도 이름만 고른다(아래 custom-columns).
readonly NAMESPACED_KINDS="deploy,sts,ds,job,cronjob,pod,svc,pdb,pvc,configmap,secret,serviceaccount,role,rolebinding"
readonly ROUTING_KINDS="gateway.gateway.networking.k8s.io,httproute.gateway.networking.k8s.io,referencegrant.gateway.networking.k8s.io,middleware.traefik.io"
readonly POLICY_KINDS="networkpolicy,ciliumnetworkpolicy.cilium.io"
readonly MONITORING_KINDS="podmonitor.monitoring.coreos.com,servicemonitor.monitoring.coreos.com"
readonly MAX_RUN_DIR_ATTEMPTS=100

KUBE_CONTEXT="${PERSONA_RETIRE_KUBE_CONTEXT-$DEFAULT_KUBE_CONTEXT}"
KUBE_SERVER="${PERSONA_RETIRE_KUBE_SERVER-}"
REQUEST_TIMEOUT="${PERSONA_RETIRE_REQUEST_TIMEOUT-20s}"
KUBECTL="${PERSONA_RETIRE_KUBECTL-kubectl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_ROOT="${PERSONA_RETIRE_OUTPUT_ROOT-$REPO_DIR/runbooks/transition/retire-persona/out}"

REQUIRED_FAILURES=0
OPTIONAL_FAILURES=0

config_error() {
  echo "설정 오류: $*" >&2
  exit 2
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

k() {
  "$KUBECTL" --context="$KUBE_CONTEXT" --request-timeout="$REQUEST_TIMEOUT" "$@"
}

# 조회 하나를 파일로 남긴다. $1=이름 $2=required|optional, 나머지=kubectl 인자.
# 실패를 빈 값이나 성공으로 바꾸지 않는다 — exit_code를 파일 꼬리와 manifest에 그대로 남긴다.
query() {
  local name="$1" class="$2"
  shift 2
  local file="$RUN_DIR/$name.txt" status=0
  {
    echo "# command: kubectl $*"
    echo "# collected_at: $(utc_now)"
    echo "# class: $class"
    echo
  } > "$file"
  k "$@" >> "$file" 2>&1 || status=$?
  printf '\n# exit_code: %s\n' "$status" >> "$file"
  record "$name" "$class" "$status"
}

# -o json을 메모리로만 받아 필드를 골라 쓴다. $1=이름 $2=class $3=ruby 필터 소스, 나머지=kubectl 인자.
query_filtered() {
  local name="$1" class="$2" filter="$3"
  shift 3
  local file="$RUN_DIR/$name.txt" status=0 json
  {
    echo "# command: kubectl $* (필드만 골라 기록, 원본 미저장)"
    echo "# collected_at: $(utc_now)"
    echo "# class: $class"
    echo
  } > "$file"
  if json=$(k "$@" 2>&1); then
    printf '%s' "$json" | ruby -rjson -e "$filter" >> "$file" 2>&1 || status=$?
  else
    status=$?
    # 실패 메시지는 kubectl 오류문이다(객체 본문이 아니다).
    printf '%s\n' "$json" | head -5 >> "$file"
  fi
  printf '\n# exit_code: %s\n' "$status" >> "$file"
  record "$name" "$class" "$status"
}

record() {
  local name="$1" class="$2" status="$3"
  printf '%s\t%s\t%s\t%s\n' "$name" "$class" "$status" "$(utc_now)" >> "$RUN_DIR/manifest.tsv"
  if [ "$status" -ne 0 ]; then
    if [ "$class" = required ]; then
      REQUIRED_FAILURES=$((REQUIRED_FAILURES + 1))
    else
      OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
    fi
  fi
}

# ---------------------------------------------------------------------------
# 설정 검사
# ---------------------------------------------------------------------------
[[ "$REQUEST_TIMEOUT" =~ ^[1-9][0-9]*(s|m)$ ]] || config_error "PERSONA_RETIRE_REQUEST_TIMEOUT는 <양의 정수>s|m이어야 한다(실제: ${REQUEST_TIMEOUT:-빈 값})"
[ -n "$KUBE_CONTEXT" ] || config_error "PERSONA_RETIRE_KUBE_CONTEXT가 비었다"
[ -n "$OUTPUT_ROOT" ] || config_error "PERSONA_RETIRE_OUTPUT_ROOT가 비었다"
command -v ruby > /dev/null 2>&1 || config_error "ruby가 없다"
command -v "$KUBECTL" > /dev/null 2>&1 || config_error "kubectl이 없다: $KUBECTL"

# context가 정말 그 클러스터인지 먼저 본다. 다른 클러스터의 "없음"을 정리 근거로 쓰면 안 된다.
current_context=$("$KUBECTL" config current-context 2> /dev/null || true)
[ "$current_context" = "$KUBE_CONTEXT" ] || config_error "현재 context(${current_context:-없음})가 ${KUBE_CONTEXT}가 아니다"
if [ -n "$KUBE_SERVER" ]; then
  current_server=$("$KUBECTL" config view --minify --context="$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}' 2> /dev/null || true)
  [ "$current_server" = "$KUBE_SERVER" ] || config_error "context ${KUBE_CONTEXT}의 API server가 PERSONA_RETIRE_KUBE_SERVER와 다르다"
fi

mkdir -p "$OUTPUT_ROOT" || config_error "출력 폴더를 만들지 못했다: $OUTPUT_ROOT"
run_id="retire-$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUTPUT_ROOT/$run_id"
attempt=1
until mkdir "$RUN_DIR" 2> /dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -le "$MAX_RUN_DIR_ATTEMPTS" ] || config_error "run 디렉터리를 새로 만들지 못했다: $OUTPUT_ROOT/$run_id-*"
  RUN_DIR="$OUTPUT_ROOT/$run_id-$attempt"
done
readonly RUN_DIR

script_sha=$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "${BASH_SOURCE[0]}")
{
  printf '# persona_retire inventory\n'
  printf '# run_id\t%s\n' "$(basename "$RUN_DIR")"
  printf '# collected_at\t%s\n' "$(utc_now)"
  printf '# context\t%s\n' "$KUBE_CONTEXT"
  printf '# api_server_checked\t%s\n' "$([ -n "$KUBE_SERVER" ] && echo yes || echo no)"
  printf '# request_timeout\t%s\n' "$REQUEST_TIMEOUT"
  printf '# script_sha256\t%s\n' "$script_sha"
} > "$RUN_DIR/00_run_info.txt"
printf 'name\tclass\texit_code\tcollected_at\n' > "$RUN_DIR/manifest.tsv"

# ---------------------------------------------------------------------------
# 조회 묶음
# ---------------------------------------------------------------------------

# Argo Application: 무엇이 무엇을 추적하는지. automated가 있으면 Git 제거가 곧 삭제가 된다.
query argo_applications required -n argocd get applications.argoproj.io \
  -o 'custom-columns=NAME:.metadata.name,PATH:.spec.source.path,CHART:.spec.sources[*].chart,DEST_NS:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTOMATED:.spec.syncPolicy.automated,FINALIZERS:.metadata.finalizers'
query_filtered argo_application_resources required '
  JSON.parse(STDIN.read).fetch("items").each do |app|
    puts "APP\t#{app.dig("metadata", "name")}"
    (app.dig("status", "resources") || []).each do |r|
      puts "  #{r["group"]}\t#{r["kind"]}\t#{r["namespace"]}\t#{r["name"]}\tsync=#{r["status"]}\thealth=#{r.dig("health", "status")}"
    end
  end' -n argocd get applications.argoproj.io -o json

# namespace별 객체 이름·소유자·Argo tracking-id. Secret은 type까지만.
for ns in "${NAMESPACES[@]}"; do
  class=required
  case "$OPTIONAL_NAMESPACES" in *" $ns "*) class=optional ;; esac
  query "ns_${ns}_namespace" "$class" get namespace "$ns" \
    -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,PHASE:.status.phase'
  query "ns_${ns}_objects" "$class" -n "$ns" get "$NAMESPACED_KINDS" \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,TYPE:.type,OWNER:.metadata.ownerReferences[*].kind,NODE:.spec.nodeName,TRACKING:.metadata.annotations.argocd\.argoproj\.io/tracking-id'
  query "ns_${ns}_routing" optional -n "$ns" get "$ROUTING_KINDS" \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,TRACKING:.metadata.annotations.argocd\.argoproj\.io/tracking-id'
  query "ns_${ns}_policies" optional -n "$ns" get "$POLICY_KINDS" \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,TRACKING:.metadata.annotations.argocd\.argoproj\.io/tracking-id'
  query "ns_${ns}_monitoring" optional -n "$ns" get "$MONITORING_KINDS" \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name'
done

# 지킬 대상: Gateway·Certificate·TLS Secret의 신원. 정리 전후로 같은 값이어야 한다.
query gateway_identity required -n persona-app get gateway.gateway.networking.k8s.io persona-app \
  -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status,TRACKING:.metadata.annotations.argocd\.argoproj\.io/tracking-id'
query certificate_identity required -n persona-app get certificate.cert-manager.io persona-app-tls \
  -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,READY:.status.conditions[?(@.type=="Ready")].status,NOT_AFTER:.status.notAfter,OWNER:.metadata.ownerReferences[*].kind,OWNER_UID:.metadata.ownerReferences[*].uid'
query tls_secret_identity required -n persona-app get secret persona-app-tls \
  -o 'custom-columns=NAME:.metadata.name,TYPE:.type,UID:.metadata.uid'

# 공개·내부 Route가 어디로 붙고 어디로 보내는지(전 namespace).
query_filtered httproutes required '
  JSON.parse(STDIN.read).fetch("items").each do |route|
    parents = (route.dig("spec", "parentRefs") || []).map { |p| "#{p["namespace"] || route.dig("metadata", "namespace")}/#{p["name"]}:#{p["sectionName"]}" }
    backends = (route.dig("spec", "rules") || []).flat_map { |r| (r["backendRefs"] || []).map { |b| "#{b["namespace"] || route.dig("metadata", "namespace")}/#{b["name"]}:#{b["port"]}" } }.uniq
    accepted = (route.dig("status", "parents") || []).map { |p| (p["conditions"] || []).find { |c| c["type"] == "Accepted" }&.dig("status") }.compact
    puts [route.dig("metadata", "namespace"), route.dig("metadata", "name"), "parents=#{parents.join(",")}", "hosts=#{(route.dig("spec", "hostnames") || []).join(",")}", "backends=#{backends.join(",")}", "accepted=#{accepted.join(",")}"].join("\t")
  end' get httproutes.gateway.networking.k8s.io -A -o json
query_filtered referencegrants optional '
  JSON.parse(STDIN.read).fetch("items").each do |grant|
    from = (grant.dig("spec", "from") || []).map { |f| "#{f["namespace"]}/#{f["kind"]}" }
    to = (grant.dig("spec", "to") || []).map { |t| "#{t["kind"]}/#{t["name"] || "*"}" }
    puts [grant.dig("metadata", "namespace"), grant.dig("metadata", "name"), "from=#{from.join(",")}", "to=#{to.join(",")}"].join("\t")
  end' get referencegrants.gateway.networking.k8s.io -A -o json

# 다른 namespace의 정책이 persona namespace를 가리키는지(지우면 끊기거나 남는 허용 규칙).
query_filtered networkpolicy_references required '
  watched = %w[persona-app persona-data persona-edge persona-mock-sse]
  JSON.parse(STDIN.read).fetch("items").each do |policy|
    peers = %w[ingress egress].flat_map { |dir| (policy.dig("spec", dir) || []).flat_map { |rule| (rule["from"] || rule["to"] || []).map { |peer| [dir, peer] } } }
    hits = peers.map do |dir, peer|
      ns = peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name")
      next nil unless watched.include?(ns)
      pod = (peer.dig("podSelector", "matchLabels") || {}).map { |k, v| "#{k}=#{v}" }.join(",")
      "#{dir}:#{ns}#{pod.empty? ? "" : "/" + pod}"
    end.compact
    next if hits.empty?
    puts [policy.dig("metadata", "namespace"), policy.dig("metadata", "name"), hits.uniq.join(" ")].join("\t")
  end' get networkpolicies -A -o json

# 저장소: 지울 PVC/PV(Retain이면 수동 삭제·노드 디렉터리)와 지킬 PVC(모델 캐시)를 가른다. IP는 고르지 않는다.
query_filtered persistent_volumes required '
  JSON.parse(STDIN.read).fetch("items").each do |pv|
    claim = pv.dig("spec", "claimRef") ? "#{pv.dig("spec", "claimRef", "namespace")}/#{pv.dig("spec", "claimRef", "name")}" : "-"
    path = pv.dig("spec", "local", "path") || pv.dig("spec", "hostPath", "path") || "-"
    nodes = (pv.dig("spec", "nodeAffinity", "required", "nodeSelectorTerms") || []).flat_map { |t| (t["matchExpressions"] || []).flat_map { |e| e["values"] || [] } }
    puts [pv.dig("metadata", "name"), "claim=#{claim}", "sc=#{pv.dig("spec", "storageClassName")}", "reclaim=#{pv.dig("spec", "persistentVolumeReclaimPolicy")}", "phase=#{pv.dig("status", "phase")}", "driver=#{pv.dig("spec", "csi", "driver") || "-"}", "node=#{nodes.join(",")}", "path=#{path}", "capacity=#{pv.dig("spec", "capacity", "storage")}"].join("\t")
  end' get pv -o json
query persistent_volume_claims required get pvc -A \
  -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,VOLUME:.spec.volumeName,PHASE:.status.phase'
query storage_classes required get storageclass \
  -o 'custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,ARGO_OPTIONS:.metadata.annotations.argocd\.argoproj\.io/sync-options'
query csi_drivers optional get csidriver -o 'custom-columns=NAME:.metadata.name'
# csi-driver-nfs Helm release·워크로드 이름만(값 없음). Application을 빼도 이것들은 남는다.
query nfs_csi_workloads optional -n kube-system get deploy,ds -l app.kubernetes.io/instance=csi-driver-nfs \
  -o 'custom-columns=KIND:.kind,NAME:.metadata.name'

# CNPG Cluster(지울 persona-db). env가 없도록 필드만 고른다.
query cnpg_clusters optional get clusters.postgresql.cnpg.io -A \
  -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,INSTANCES:.spec.instances,READY:.status.readyInstances,PHASE:.status.phase,SC:.spec.storage.storageClass,TRACKING:.metadata.annotations.argocd\.argoproj\.io/tracking-id'

# 지킬 대상: vLLM·모델 캐시.
query vllm_state required -n persona-inference get deploy \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.spec.replicas'

# 노드 자원표: 정리 뒤 회수량을 같은 방식으로 다시 재 비교한다. Pod env는 읽지 않는다.
query nodes required get nodes \
  -o 'custom-columns=NAME:.metadata.name,POOL:.metadata.labels.personaruntime\.xyz/node-pool,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,TAINTS:.spec.taints[*].key'
query_filtered node_requests required '
  parse_cpu = lambda { |v| v.nil? ? 0 : (v.end_with?("m") ? v.to_f : v.to_f * 1000) }
  parse_mem = lambda do |v|
    next 0 if v.nil?
    units = { "Ki" => 1.0 / 1024, "Mi" => 1, "Gi" => 1024, "K" => 1.0 / 1024, "M" => 1, "G" => 1024 }
    unit = units.keys.find { |u| v.end_with?(u) }
    unit ? v.to_f * units[unit] : v.to_f / (1024 * 1024)
  end
  totals = Hash.new { |h, k| h[k] = { cpu: 0, mem: 0, pods: 0, persona: 0 } }
  JSON.parse(STDIN.read).fetch("items").each do |pod|
    next if %w[Succeeded Failed].include?(pod.dig("status", "phase"))
    node = pod.dig("spec", "nodeName") || "(unscheduled)"
    (pod.dig("spec", "containers") || []).each do |c|
      totals[node][:cpu] += parse_cpu.call(c.dig("resources", "requests", "cpu"))
      totals[node][:mem] += parse_mem.call(c.dig("resources", "requests", "memory"))
    end
    totals[node][:pods] += 1
    totals[node][:persona] += 1 if %w[persona-app persona-data persona-mock-sse].include?(pod.dig("metadata", "namespace"))
  end
  puts "NODE\tCPU_REQ_m\tMEM_REQ_Mi\tPODS\tPERSONA_PODS"
  totals.sort.each { |node, t| puts [node, t[:cpu].round, t[:mem].round, t[:pods], t[:persona]].join("\t") }' get pods -A -o json

# ---------------------------------------------------------------------------
# 참조 요약 — 사람이 지울/지킬 표를 확정하는 재료. 판정이 아니라 사실만 모은다.
# ---------------------------------------------------------------------------
ruby -e '
run = ARGV[0]
read = lambda { |name| path = File.join(run, "#{name}.txt"); File.exist?(path) ? File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? } : [] }
out = []
out << "# 참조 요약 (판정 아님 — 사람이 지울/지킬 표를 확정할 때 쓴다)"
out << "## persona-app namespace HTTPRoute (namespace·이름·parent·backend)"
read.call("httproutes").select { |l| l.start_with?("persona-app\t") }.each { |l| out << "  #{l.chomp}" }
out << "## 다른 namespace 정책이 persona namespace를 가리킴"
read.call("networkpolicy_references").each { |l| out << "  #{l.chomp}" }
out << "## ReferenceGrant"
read.call("referencegrants").each { |l| out << "  #{l.chomp}" }
pvs = read.call("persistent_volumes")
out << "## persona-data에 묶인 PV (지울 후보 — reclaim=Retain이면 PV·노드 디렉터리를 수동 정리)"
pvs.select { |l| l.include?("claim=persona-data/") }.each { |l| out << "  #{l.chomp}" }
out << "## persona-inference에 묶인 PV (지킬 대상 — 모델 캐시)"
pvs.select { |l| l.include?("claim=persona-inference/") }.each { |l| out << "  #{l.chomp}" }
nfs = pvs.select { |l| l.include?("sc=nfs-shared") || l.include?("driver=nfs.csi.k8s.io") }
nfs_claims = read.call("persistent_volume_claims").select { |l| l.split[2] == "nfs-shared" }
out << "## nfs-shared·NFS CSI 사용: PV #{nfs.length}개 · PVC #{nfs_claims.length}개 (0이어야 csi-driver-nfs·StorageClass를 지운다)"
(nfs + nfs_claims).each { |l| out << "  #{l.chomp}" }
out << "## CNPG Cluster"
read.call("cnpg_clusters").each { |l| out << "  #{l.chomp}" }
out << "## 지킬 대상 신원 (정리 전후 같아야 한다)"
%w[gateway_identity certificate_identity tls_secret_identity vllm_state].each do |name|
  read.call(name).each { |l| out << "  #{name}: #{l.chomp}" }
end
File.write(File.join(run, "90_references.txt"), out.join("\n") + "\n")
' "$RUN_DIR"

# ---------------------------------------------------------------------------
# 누출 검사 — 공인 IPv4·비밀 모양이 결과에 있으면 3으로 끝낸다(값은 출력하지 않는다).
# ---------------------------------------------------------------------------
leaks=$(ruby -e '
private = lambda do |ip|
  a, b = ip.split(".").map(&:to_i)
  a == 10 || a == 127 || a == 0 || (a == 172 && (16..31).cover?(b)) || (a == 192 && b == 168) ||
    (a == 100 && (64..127).cover?(b)) || (a == 169 && b == 254) || (a == 192 && b == 0) || a >= 224
end
patterns = [/PRIVATE KEY/, /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, /^\s*(data|stringData):\s*$/]
Dir.glob(File.join(ARGV[0], "*")).sort.each do |path|
  File.readlines(path).each_with_index do |line, index|
    ips = line.scan(/(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])/).flatten.select { |ip| ip.split(".").all? { |o| o.to_i <= 255 } }
    hit = ips.any? { |ip| !private.call(ip) } || patterns.any? { |p| line.match?(p) }
    puts "#{File.basename(path)}:#{index + 1}" if hit
  end
end' "$RUN_DIR")

echo "인벤토리: $RUN_DIR"
echo "required 실패 ${REQUIRED_FAILURES}건 · optional 실패 ${OPTIONAL_FAILURES}건 (manifest.tsv)"
if [ -n "$leaks" ]; then
  echo "중단: 결과에 공인 IP·비밀 모양이 있다(값은 출력하지 않음). 공유하지 말고 위치를 확인한다:" >&2
  printf '  %s\n' $leaks >&2
  exit 3
fi
if [ "$REQUIRED_FAILURES" -ne 0 ]; then
  echo "required 조회가 실패했다 — 결과로 지울 대상을 확정하지 않는다" >&2
  exit 1
fi
echo "참조 요약: $RUN_DIR/90_references.txt"
exit 0
