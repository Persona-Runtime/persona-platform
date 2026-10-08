#!/bin/sh

set -eu

# Sync 통제(2026-09-19) — Argo Application을 Sync하기 전에 사람이 눌러야 하는 확인들을
# 기계적으로 강제한다. 이 스크립트는 읽기만 한다: kubectl get/diff, git fetch/worktree
# (읽기 전용 조회). kubectl apply·argocd app sync는 이 스크립트 안에서 절대 실행하지 않는다
# — 마지막에 사람이 실행할 명령을 "출력"만 한다.
#
# 사용법:
#   scripts/argo-preflight.sh <app>     # public-gateway, maintenance-page, persona-edge,
#                                        # metallb, metallb-config, cert-manager,
#                                        # cert-manager-issuers, gpu-runtime, dcgm-exporter,
#                                        # nvidia-device-plugin, mafest-db, mafest-db-netpol 중 하나
#   scripts/argo-preflight.sh --self-test
#
# live 조회 전에 kube context가 PREFLIGHT_KUBE_CONTEXT(기본 kubernetes-admin@kubernetes)인지 확인한다.
# PREFLIGHT_KUBE_SERVER를 주면 그 context의 API server URL도 비교한다.
#
# persona 앱·DB·NFS Application(persona-app, persona-app-ingress, persona-app-netpol, persona-db,
# persona-db-netpol, persona-nfs-storage, csi-driver-nfs)은 2026-10-07 폐기해 선행 조건 표에서 뺐다.
# public-gateway는 소유권 이관(Phase 1)이 끝난 뒤 기준으로 검사한다(아래 3-1).

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
approved_sync_file="$repo_dir/deploy/approved-sync.md"

usage() {
  echo "사용법: $0 <app> | $0 --self-test" >&2
  exit 1
}

require_tools() {
  for tool in kubectl ruby git mktemp; do
    if ! command -v "$tool" > /dev/null 2>&1; then
      echo "필요한 도구가 없습니다: ${tool}" >&2
      exit 1
    fi
  done
}

# argocd/<app>.yaml에서 source.path·destination.namespace를 읽는다. 하드코딩하지 않는
# 이유: 매핑이 실제 선언과 어긋나면(경로를 옮기고 여기를 안 고치면) 렌더가 그 자리에서
# 실패해 바로 드러난다.
app_source_path() {
  # 매직 코멘트가 -e 소스의 **첫 줄**에 있어야 한다. -e로 넘긴 Ruby 소스는 파일이 아니라
  # 로케일 인코딩으로 파싱되므로, LC_ALL=C 같은 환경에서는 아래 한글 abort 메시지에서
  # "invalid multibyte char"로 죽는다. `ruby -E UTF-8`은 외부 인코딩만 바꿔 이 문제를
  # 고치지 못한다(확인함) — 아래 다른 ruby 블록들도 같은 이유로 같은 첫 줄을 갖는다.
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    path = app.dig("spec", "source", "path")
    abort "source.path가 없다 — 이 스크립트는 단일 source(kustomize path) Application만 지원한다" if path.nil?
    puts path
  ' "$repo_dir/argocd/$1.yaml"
}

app_namespace() {
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    puts app.dig("spec", "destination", "namespace")
  ' "$repo_dir/argocd/$1.yaml"
}

# metallb·cert-manager는 spec.source(단수)가 아니라 spec.sources(복수, Helm 차트 + 이
# 저장소의 값 파일 source)를 쓴다 — kustomize path가 아예 없다. 아래 app_helm_* 함수들이
# 그 차트 source에서 render_at_sha가 helm template에 필요한 값을 뽑는다.
app_is_multi_source() {
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    puts app.dig("spec", "sources").nil? ? "false" : "true"
  ' "$repo_dir/argocd/$1.yaml"
}

app_helm_chart_source() {
  # 인자로 받은 필드(field) 하나만 출력한다 — sources 배열에서 "chart" 키를 가진
  # 항목(Helm 차트 source, 값 파일만 가리키는 source와 구분)을 찾아 그 필드를 읽는다.
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    field = ARGV[1]
    chart_source = app.fetch("spec").fetch("sources").find { |s| s.key?("chart") } ||
      abort("Helm 차트 source를 못 찾았다")
    value = case field
            when "repoURL"        then chart_source["repoURL"]
            when "chart"          then chart_source["chart"]
            when "targetRevision" then chart_source["targetRevision"]
            when "releaseName"    then chart_source.dig("helm", "releaseName")
            else abort("알 수 없는 필드: #{field}")
            end
    abort "#{field}가 없다" if value.nil?
    puts value
  ' "$repo_dir/argocd/$1.yaml" "$2"
}

# $values/helm/values/<name>.yaml 형태의 valueFiles 경로에서 "$values/" 접두사를 뺀,
# 이 저장소 루트 기준 상대 경로를 줄바꿈으로 하나씩 출력한다.
app_helm_value_files() {
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    chart_source = app.fetch("spec").fetch("sources").find { |s| s.key?("chart") } ||
      abort("Helm 차트 source를 못 찾았다")
    files = chart_source.dig("helm", "valueFiles") || []
    abort "helm.valueFiles가 없다" if files.empty?
    files.each { |f| puts f.sub(%r{\A\$values/}, "") }
  ' "$repo_dir/argocd/$1.yaml"
}

# --- 1. 승인 SHA -------------------------------------------------------------
record_approved_sha() {
  app="$1"
  sha="$2"
  result="$3"
  timestamp=$(date '+%Y-%m-%d %H:%M')
  operator=$(whoami 2> /dev/null || echo "알 수 없음")
  printf '| %s | %s | %s | %s | %s |\n' "$timestamp" "$app" "$sha" "$operator" "$result" >> "$approved_sync_file"
}

# 이 app의 직전 성공 기록에서 SHA를 찾는다(롤백 명령용). 없으면 빈 문자열.
previous_approved_sha() {
  app="$1"
  awk -F'|' -v app="$app" '
    NF >= 6 {
      gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $6)
      if ($3 == app && $6 ~ /통과|성공/) last = $4
    }
    END { if (last) print last }
  ' "$approved_sync_file" | tr -d ' '
}

# --- 2. SHA에서 렌더 -----------------------------------------------------------
render_at_sha() {
  app="$1"
  sha="$2"
  worktree_dir=$(mktemp -d "${TMPDIR:-/tmp}/argo-preflight-XXXXXX")
  trap 'git -C "'"$repo_dir"'" worktree remove --force "'"$worktree_dir"'" > /dev/null 2>&1 || true' EXIT HUP INT TERM
  git -C "$repo_dir" worktree add --detach --quiet "$worktree_dir" "$sha"

  if [ "$(app_is_multi_source "$app")" = "true" ]; then
    # metallb·cert-manager — Helm 차트(네트워크에서 직접 받는다, Argo가 Sync 때 하는 것과
    # 같다)를 이 저장소가 그 SHA 시점에 갖고 있던 값 파일로 렌더한다. kustomize path가
    # 없어 위 단일 source 경로(kubectl kustomize)를 쓸 수 없다.
    #
    # helm은 다중 source Application에서만 필요하다 — kustomize app만 점검하는 CP에도
    # 항상 요구하면 불필요하게 막힌다(require_tools가 아니라 여기서 확인하는 이유).
    if ! command -v helm > /dev/null 2>&1; then
      echo "필요한 도구가 없습니다: helm (다중 source Application인 ${app}에 필요)" >&2
      exit 1
    fi
    repo_url=$(app_helm_chart_source "$app" repoURL)
    chart=$(app_helm_chart_source "$app" chart)
    target_revision=$(app_helm_chart_source "$app" targetRevision)
    release_name=$(app_helm_chart_source "$app" releaseName)
    namespace=$(app_namespace "$app")
    set --
    while IFS= read -r value_file; do
      [ -n "$value_file" ] && set -- "$@" -f "$worktree_dir/$value_file"
    done <<EOF
$(app_helm_value_files "$app")
EOF
    helm template "$release_name" "$chart" --repo "$repo_url" --version "$target_revision" \
      -n "$namespace" "$@"
  else
    source_path=$(app_source_path "$app")
    kubectl kustomize "$worktree_dir/$source_path"
  fi
}

# --- 3. kubectl diff + kind/name 요약 -------------------------------------------
# kubectl diff 종료 코드: 0 = 차이 없음, 1 = 정상적인 차이 있음, 2 이상 = 접속·권한·스키마 오류.
# 오류를 "차이 있음"이나 "차이 없음"으로 삼키면 diff를 보지 못한 채 승인 기록이 남으므로 실패로 돌린다.
# $1 = 렌더 결과, $2 = diff 출력 파일
run_live_diff() {
  diff_status=0
  kubectl diff -f "$1" > "$2" 2>&1 || diff_status=$?
  if [ "$diff_status" -gt 1 ]; then
    echo "선행 조건 실패: kubectl diff가 오류로 끝났다(exit ${diff_status}) — 접속·권한·스키마 문제를 먼저 해결한다" >&2
    sed 's/^/  /' "$2" >&2
    return 1
  fi
}
summarize_diff() {
  diff_file="$1"
  echo "바뀌는 리소스(kind/namespace/name):"
  # kubectl diff -u -N 헤더 줄에 <group>.<version>.<Kind>.<namespace>.<name> 형태로
  # 대상이 인코딩돼 있다 — 이미지 태그 줄만 보고 넘어가는 실수를 막으려는 것이다.
  grep '^diff -u -N' "$diff_file" \
    | sed -E 's#^diff -u -N ([^ ]+/)?([^/ ]+) ([^ ]+/)?([^/ ]+)$#\2#' \
    | sort -u || echo "  (diff 없음 — 클러스터에 이미 반영된 상태이거나 클러스터에 접근할 수 없음)"
  echo
}

# --- 3-1. public-gateway 전용 검사 ----------------------------------------------
# Gateway persona-app의 소유권 이관(Phase 1, persona-app → public-gateway)은 끝났다는 전제다.
# 이관 전 상태(Phase 0 입력·persona-app tracking-id)를 보던 검사는 persona 폐기(2026-10-07)와 함께
# 지웠다 — 이관 전에 이 Application을 다시 Sync해야 하는 일이 생기면 그 커밋 이전 develop의
# 스크립트와 runbooks/transition/phase1/README.md를 쓴다.
#
# Gateway가 한 번이라도 삭제되면 gateway-shim이 만든 Certificate가 ownerReference로 함께 지워질 수
# 있으므로, Sync 명령을 출력하기 전에 아래 두 가지를 확인한다.
#   (1) 선언: Application path·destination, 자동 Sync·finalizer 없음, 렌더는 Gateway 하나뿐
#   (2) live: Gateway를 public-gateway가 추적하고, Gateway·Certificate·TLS Secret이 지금 정상이다
PUBLIC_GATEWAY_SOURCE_PATH="kustomize/overlays/prod/public-gateway"
# 이관 뒤 Gateway가 가져야 하는 Argo tracking-id(annotation 방식, <app>:<group>/<Kind>:<ns>/<name>).
GATEWAY_TRACKING_ID="public-gateway:gateway.networking.k8s.io/Gateway:persona-app/persona-app"
# live 조회를 보낼 kube context. 다른 클러스터(예: 맥의 minikube)의 결과를 통과로 읽지 않기 위해 고정한다.
EXPECTED_KUBE_CONTEXT="${PREFLIGHT_KUBE_CONTEXT:-kubernetes-admin@kubernetes}"

# (1) $1 = Application YAML, $2 = 그 SHA에서 렌더한 결과. 실패 시 사유를 stderr에 쓰고 1을 반환한다.
check_public_gateway_declaration() {
  ruby -ryaml -e '# encoding: utf-8
    app_path, rendered_path, expected_path = ARGV
    app = YAML.load_file(app_path)
    fail_with = lambda { |message| warn "선행 조건 실패: public-gateway → #{message}"; exit 1 }
    fail_with.call("Application 이름이 public-gateway가 아니다") unless app.dig("metadata", "name") == "public-gateway"
    fail_with.call("source.path가 #{expected_path}가 아니다(실제: #{app.dig("spec", "source", "path")})") unless app.dig("spec", "source", "path") == expected_path
    fail_with.call("destination이 in-cluster persona-app이 아니다") unless app.dig("spec", "destination") == { "server" => "https://kubernetes.default.svc", "namespace" => "persona-app" }
    # syncPolicy 키 전체를 막는다. automated(prune·selfHeal)뿐 아니라 Replace=true 같은 syncOptions도
    # 같은 객체를 지우고 다시 만들 수 있어서다.
    fail_with.call("syncPolicy가 있다 — automated·prune·selfHeal·syncOptions 없이 수동 Sync만 허용한다") if app["spec"].key?("syncPolicy")
    fail_with.call("finalizers가 있다 — Application 삭제가 Gateway 삭제로 번진다") unless app.dig("metadata", "finalizers").nil?
    objects = YAML.load_stream(File.read(rendered_path)).compact
    summary = objects.map { |o| "#{o["kind"]}/#{o.dig("metadata", "namespace")}/#{o.dig("metadata", "name")}" }
    fail_with.call("렌더가 Gateway/persona-app/persona-app 하나가 아니다(Certificate·Secret 선언 금지): #{summary}") unless summary == ["Gateway/persona-app/persona-app"]
  ' "$1" "$2" "$PUBLIC_GATEWAY_SOURCE_PATH"
}

# live 조회 전에 kube context가 홈 클러스터인지 본다. 다른 context(예: 맥의 minikube)에서 실행하면
# Gateway가 없다는 실패나, 우연히 같은 이름 객체의 "통과"를 홈 클러스터 결과로 오해할 수 있다.
# context 이름은 kubeconfig마다 같을 수 있으므로 PREFLIGHT_KUBE_SERVER가 있으면 API server URL도 본다.
require_expected_context() {
  expected_server="${1:-${PREFLIGHT_KUBE_SERVER:-}}"
  current_context=$(kubectl config current-context 2> /dev/null || true)
  if [ "$current_context" != "$EXPECTED_KUBE_CONTEXT" ]; then
    echo "선행 조건 실패: kube context가 ${EXPECTED_KUBE_CONTEXT}가 아니다(실제: ${current_context:-없음}) — live 조회를 하지 않는다" >&2
    return 1
  fi
  [ -n "$expected_server" ] || return 0
  current_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2> /dev/null || true)
  if [ "$current_server" != "$expected_server" ]; then
    echo "선행 조건 실패: context ${current_context}의 API server가 ${expected_server}가 아니다(실제: ${current_server:-없음}) — live 조회를 하지 않는다" >&2
    return 1
  fi
}

# 조건 하나의 status를 읽는다. $1 = 종류, $2 = 이름, $3 = 조건 type
live_condition() {
  kubectl -n persona-app get "$1" "$2" -o jsonpath="{.status.conditions[?(@.type==\"$3\")].status}" 2> /dev/null || true
}

# (2) live 상태(읽기 전용). Sync 직전에 다시 읽는다.
# 이전 실행·인벤토리에서 기록한 값을 PREFLIGHT_EXPECTED_GATEWAY_UID·PREFLIGHT_EXPECTED_CERT_NOT_AFTER로
# 주면 그 사이 Gateway가 다시 만들어졌거나 인증서가 재발급됐는지도 본다(주지 않으면 현재 값을 출력만 한다).
check_live_gateway_state() {
  # --check-preconditions처럼 main의 가드를 거치지 않는 입구에서도 다른 클러스터를 읽지 않게 한다.
  require_expected_context || return 1
  live_gateway_uid=$(kubectl -n persona-app get gateway persona-app -o jsonpath='{.metadata.uid}' 2> /dev/null || true)
  if [ -z "$live_gateway_uid" ]; then
    echo "선행 조건 실패: public-gateway → live Gateway persona-app이 없다 — 인증서도 함께 사라졌을 수 있다. 재생성 절차를 따로 밟는다" >&2
    return 1
  fi
  if [ -n "${PREFLIGHT_EXPECTED_GATEWAY_UID:-}" ] && [ "$live_gateway_uid" != "$PREFLIGHT_EXPECTED_GATEWAY_UID" ]; then
    echo "선행 조건 실패: public-gateway → live Gateway UID가 기록과 다르다(실제 ${live_gateway_uid}, 기록 ${PREFLIGHT_EXPECTED_GATEWAY_UID}) — 그사이 재생성됐다" >&2
    return 1
  fi
  # 이관이 끝났다면 Gateway를 추적하는 Application은 public-gateway다. persona-app 값이 남아 있으면
  # 이관 전 상태이므로 이 스크립트(이관 뒤 기준)로 Sync하지 않는다.
  live_tracking=$(kubectl -n persona-app get gateway persona-app \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2> /dev/null || true)
  if [ "$live_tracking" != "$GATEWAY_TRACKING_ID" ]; then
    echo "선행 조건 실패: public-gateway → live Gateway tracking-id가 public-gateway가 아니다(실제: ${live_tracking:-없음}) — 소유권 이관(Phase 1)을 먼저 마친다" >&2
    return 1
  fi
  live_cert_owners=$(kubectl -n persona-app get certificate persona-app-tls \
    -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name}/{.uid}{" "}{end}' 2> /dev/null || true)
  if [ "$live_cert_owners" != "Gateway/persona-app/${live_gateway_uid} " ]; then
    echo "선행 조건 실패: public-gateway → live Certificate ownerReference가 현재 Gateway 하나가 아니다(실제: ${live_cert_owners:-없음})" >&2
    return 1
  fi
  # TLS Secret은 metadata.uid만 읽는다. 값(data)은 조회하지 않는다.
  live_secret_uid=$(kubectl -n persona-app get secret persona-app-tls -o jsonpath='{.metadata.uid}' 2> /dev/null || true)
  if [ -z "$live_secret_uid" ]; then
    echo "선행 조건 실패: public-gateway → live TLS Secret persona-app-tls가 없다" >&2
    return 1
  fi
  live_not_after=$(kubectl -n persona-app get certificate persona-app-tls -o jsonpath='{.status.notAfter}' 2> /dev/null || true)
  if [ -n "${PREFLIGHT_EXPECTED_CERT_NOT_AFTER:-}" ] && [ "$live_not_after" != "$PREFLIGHT_EXPECTED_CERT_NOT_AFTER" ]; then
    echo "선행 조건 실패: public-gateway → live Certificate notAfter가 기록과 다르다(실제 ${live_not_after:-없음}, 기록 ${PREFLIGHT_EXPECTED_CERT_NOT_AFTER}) — 재발급 여부를 먼저 확인한다" >&2
    return 1
  fi
  programmed=$(live_condition gateway persona-app Programmed)
  if [ "$programmed" != "True" ]; then
    echo "선행 조건 실패: public-gateway → live Gateway persona-app이 Programmed=True가 아니다(실제: ${programmed:-없음})" >&2
    return 1
  fi
  ready=$(live_condition certificate persona-app-tls Ready)
  if [ "$ready" != "True" ]; then
    echo "선행 조건 실패: public-gateway → live Certificate persona-app-tls가 Ready=True가 아니다(실제: ${ready:-없음})" >&2
    return 1
  fi
  # 조회 실패를 "automated 없음"으로 읽지 않도록 종료 코드를 따로 본다.
  if ! automated=$(kubectl -n argocd get application public-gateway -o jsonpath='{.spec.syncPolicy.automated}' 2> /dev/null); then
    echo "선행 조건 실패: public-gateway → live Application public-gateway를 읽지 못했다" >&2
    return 1
  fi
  if [ -n "$automated" ]; then
    echo "선행 조건 실패: public-gateway → live Application public-gateway에 syncPolicy.automated가 있다" >&2
    return 1
  fi
  echo "live 확인: gateway_uid=${live_gateway_uid} tls_secret_uid=${live_secret_uid} cert_not_after=${live_not_after:-없음} — 다음 Sync 전 PREFLIGHT_EXPECTED_* 기록값으로 쓴다"
}

# --- 4. 선행 조건 -------------------------------------------------------------
# 실패하면 "어떤 조건인지"를 stderr에 적고 exit 1 한다. 이 함수 하나가 이 스크립트의
# 핵심이라 --self-test가 직접 이 함수를 부른다(fake kubectl로).
check_preconditions() {
  app="$1"
  case "$app" in
    maintenance-page)
      # HTTPRoute가 Middleware를 ExtensionRef로 참조한다. kubernetesCRD 프로바이더가 없으면 Route가 거부된다.
      args=$(kubectl -n traefik get pods -l app.kubernetes.io/name=traefik \
        -o jsonpath='{.items[0].spec.containers[0].args}' 2> /dev/null || true)
      case "$args" in
        *--providers.kubernetescrd*) : ;;
        *)
          echo "선행 조건 실패: maintenance-page → Traefik Pod args에 --providers.kubernetescrd가 없다" >&2
          return 1
          ;;
      esac
      # 공개 Route는 https listener(TLS Secret persona-app-tls)에 붙는다. Gateway·인증서가 먼저 정상이어야 한다.
      programmed=$(live_condition gateway persona-app Programmed)
      if [ "$programmed" != "True" ]; then
        echo "선행 조건 실패: maintenance-page → Gateway persona-app이 Programmed=True가 아니다(실제: ${programmed:-없음})" >&2
        return 1
      fi
      ready=$(live_condition certificate persona-app-tls Ready)
      if [ "$ready" != "True" ]; then
        echo "선행 조건 실패: maintenance-page → Certificate persona-app-tls가 Ready=True가 아니다(실제: ${ready:-없음})" >&2
        return 1
      fi
      ;;
    public-gateway)
      check_live_gateway_state || return 1
      ;;
    persona-edge)
      for secret in oauth2-proxy cloudflare-dns-token; do
        if ! kubectl -n persona-edge get secret "$secret" > /dev/null 2>&1; then
          echo "선행 조건 실패: persona-edge → Secret ${secret}이 없다" >&2
          return 1
        fi
      done
      ;;
    metallb)
      label=$(kubectl get namespace metallb-system \
        -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2> /dev/null || true)
      if [ "$label" != "privileged" ]; then
        echo "선행 조건 실패: metallb → Namespace metallb-system에 PSA privileged 라벨이 없다(bootstrap/namespaces/metallb-system.yaml 먼저 적용, 실제: ${label:-없음})" >&2
        return 1
      fi
      ;;
    cert-manager)
      if ! kubectl get namespace cert-manager > /dev/null 2>&1; then
        echo "선행 조건 실패: cert-manager → Namespace cert-manager가 없다(bootstrap/namespaces/cert-manager.yaml 먼저 적용)" >&2
        return 1
      fi
      ;;
    metallb-config)
      if ! kubectl get crd ipaddresspools.metallb.io > /dev/null 2>&1; then
        echo "선행 조건 실패: metallb-config → CRD ipaddresspools.metallb.io가 없다(metallb Sync 먼저)" >&2
        return 1
      fi
      ;;
    cert-manager-issuers)
      if ! kubectl get crd clusterissuers.cert-manager.io > /dev/null 2>&1; then
        echo "선행 조건 실패: cert-manager-issuers → CRD clusterissuers.cert-manager.io가 없다(cert-manager Sync 먼저)" >&2
        return 1
      fi
      ;;
    gpu-runtime)
      gpu_ready=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
      gpu_pool=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{.metadata.labels.personaruntime\.xyz/node-pool}' 2> /dev/null || true)
      gpu_taint=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{range .spec.taints[?(@.key=="personaruntime.xyz/dedicated")]}{.value}:{.effect}{end}' 2> /dev/null || true)
      if [ "$gpu_ready" != "True" ] || [ "$gpu_pool" != "gpu" ] || [ "$gpu_taint" != "gpu-serving:NoSchedule" ]; then
        echo "선행 조건 실패: gpu-runtime → persona-gpu-01 Ready=True, node-pool=gpu, dedicated=gpu-serving:NoSchedule가 모두 필요하다(실제: Ready=${gpu_ready:-없음}, pool=${gpu_pool:-없음}, taint=${gpu_taint:-없음})" >&2
        return 1
      fi
      ;;
    dcgm-exporter)
      if ! kubectl get runtimeclass nvidia > /dev/null 2>&1; then
        echo "선행 조건 실패: dcgm-exporter → RuntimeClass/nvidia가 없다(gpu-runtime Sync 먼저)" >&2
        return 1
      fi
      if ! kubectl get crd servicemonitors.monitoring.coreos.com > /dev/null 2>&1; then
        echo "선행 조건 실패: dcgm-exporter → ServiceMonitor CRD가 없다(monitoring-stack Sync 먼저)" >&2
        return 1
      fi
      prometheus_ready=$(kubectl -n monitoring get prometheus \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2> /dev/null || true)
      if [ "$prometheus_ready" != "True" ]; then
        echo "선행 조건 실패: dcgm-exporter → monitoring Prometheus가 Available=True가 아니다(실제: ${prometheus_ready:-없음})" >&2
        return 1
      fi
      # RuntimeClass가 GPU 전용 taint를 자동으로 합치지만, node 계약 자체가 깨졌다면
      # exporter는 Pending으로만 남는다. gpu-runtime과 같은 조건을 다시 확인한다.
      gpu_ready=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
      gpu_pool=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{.metadata.labels.personaruntime\.xyz/node-pool}' 2> /dev/null || true)
      if [ "$gpu_ready" != "True" ] || [ "$gpu_pool" != "gpu" ]; then
        echo "선행 조건 실패: dcgm-exporter → persona-gpu-01 Ready=True, node-pool=gpu가 필요하다(실제: Ready=${gpu_ready:-없음}, pool=${gpu_pool:-없음})" >&2
        return 1
      fi
      ;;
    mafest-db)
      # CNPG Cluster를 만들 수 있어야 한다: operator·CRD, local-path StorageClass, namespace,
      # initdb owner Secret·이미지 pull Secret·runtime 역할 Secret(이름만 확인 — 값은 읽지 않는다), 두 홈 워커.
      if ! kubectl get crd clusters.postgresql.cnpg.io > /dev/null 2>&1; then
        echo "선행 조건 실패: mafest-db → CRD clusters.postgresql.cnpg.io가 없다(bootstrap/cnpg/README.md로 operator 먼저 설치)" >&2
        return 1
      fi
      operator_ready=$(kubectl -n cnpg-system get deployment cnpg-controller-manager \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2> /dev/null || true)
      if [ "$operator_ready" != "True" ]; then
        echo "선행 조건 실패: mafest-db → cnpg-controller-manager가 Available=True가 아니다(실제: ${operator_ready:-없음})" >&2
        return 1
      fi
      if ! kubectl get storageclass local-path > /dev/null 2>&1; then
        echo "선행 조건 실패: mafest-db → StorageClass local-path가 없다" >&2
        return 1
      fi
      if ! kubectl get namespace mafest-data > /dev/null 2>&1; then
        echo "선행 조건 실패: mafest-db → Namespace mafest-data가 없다(bootstrap/namespaces/mafest-data.yaml 먼저 적용)" >&2
        return 1
      fi
      for secret in mafest-db-owner mafest-db-runtime mafest-ghcr; do
        # -o name만 쓴다. Secret 본문(data)은 조회하지 않는다.
        if ! kubectl -n mafest-data get secret "$secret" -o name > /dev/null 2>&1; then
          echo "선행 조건 실패: mafest-db → Secret ${secret}이 없다(값 없이 이름만 확인)" >&2
          return 1
        fi
      done
      for node in k8s-worker1 k8s-worker2; do
        node_ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
        if [ "$node_ready" != "True" ]; then
          echo "선행 조건 실패: mafest-db → ${node}가 Ready가 아니다 — 두 인스턴스를 서로 다른 워커에 둔다(실제: ${node_ready:-없음})" >&2
          return 1
        fi
      done
      ;;
    mafest-db-netpol)
      # 정책을 걸기 전에 DB가 2/2로 떠 있어야 하고 Cilium이 정상이어야 한다(allow → default-deny).
      phase=$(kubectl -n mafest-data get cluster mafest-db -o jsonpath='{.status.phase}' 2> /dev/null || true)
      case "$phase" in
        *[Hh]ealthy*) : ;;
        *)
          echo "선행 조건 실패: mafest-db-netpol → Cluster mafest-db phase가 healthy가 아니다(실제: ${phase:-없음})" >&2
          return 1
          ;;
      esac
      cilium_pod=$(kubectl -n kube-system get pods -l k8s-app=cilium \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2> /dev/null || true)
      if [ -z "$cilium_pod" ]; then
        echo "선행 조건 실패: mafest-db-netpol → Running 상태인 cilium Pod를 못 찾았다" >&2
        return 1
      fi
      if ! kubectl -n kube-system exec "$cilium_pod" -c cilium-agent -- cilium-dbg status --brief > /dev/null 2>&1; then
        echo "선행 조건 실패: mafest-db-netpol → cilium-dbg status가 ok가 아니다" >&2
        return 1
      fi
      ;;
    nvidia-device-plugin)
      if ! kubectl get runtimeclass nvidia > /dev/null 2>&1; then
        echo "선행 조건 실패: nvidia-device-plugin → RuntimeClass/nvidia가 없다(gpu-runtime Sync 먼저)" >&2
        return 1
      fi
      gpu_ready=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
      gpu_pool=$(kubectl get node persona-gpu-01 \
        -o jsonpath='{.metadata.labels.personaruntime\.xyz/node-pool}' 2> /dev/null || true)
      dcgm_ready=$(kubectl -n monitoring get daemonset dcgm-exporter \
        -o jsonpath='{.status.numberAvailable}' 2> /dev/null || true)
      if [ "$gpu_ready" != "True" ] || [ "$gpu_pool" != "gpu" ] || [ "$dcgm_ready" != "1" ]; then
        echo "선행 조건 실패: nvidia-device-plugin → persona-gpu-01 Ready=True·node-pool=gpu, DCGM exporter available=1이 모두 필요하다(실제: Ready=${gpu_ready:-없음}, pool=${gpu_pool:-없음}, dcgm=${dcgm_ready:-없음})" >&2
        return 1
      fi
      ;;
    *)
      echo "선행 조건 표에 없는 app이다: $app — scripts/argo-preflight.sh와 argocd/README.md에 함께 추가하라" >&2
      return 1
      ;;
  esac
}

# --- 5. 실행할 명령 출력 --------------------------------------------------------
print_next_commands() {
  app="$1"
  sha="$2"
  previous_sha=$(previous_approved_sha "$app")
  multi_source=$(app_is_multi_source "$app")
  echo
  echo "실행할 명령:"
  if command -v argocd > /dev/null 2>&1; then
    if [ "$multi_source" = "true" ]; then
      # 다중 source(metallb·cert-manager)는 --revision 단일 인자가 안 맞는다 — 값 파일을
      # 담은 두 번째 source(위치 2, 1-indexed)에만 SHA를 지정한다. 첫 번째 source(Helm
      # 차트)의 targetRevision(차트 버전)은 건드리지 않는다.
      echo "  argocd app sync $app --revisions $sha --source-positions 2"
    else
      echo "  argocd app sync $app --revision $sha"
    fi
  else
    if [ "$multi_source" = "true" ]; then
      echo "  (argocd CLI 없음) Argo UI → Applications → $app → Sync → 두 번째 source(값 파일)의 Revision에 $sha 입력"
    else
      echo "  (argocd CLI 없음) Argo UI → Applications → $app → Sync → Revision에 $sha 입력"
    fi
  fi
  echo
  echo "롤백 명령:"
  if [ -n "$previous_sha" ]; then
    if command -v argocd > /dev/null 2>&1; then
      if [ "$multi_source" = "true" ]; then
        echo "  argocd app sync $app --revisions $previous_sha --source-positions 2"
      else
        echo "  argocd app sync $app --revision $previous_sha"
      fi
    else
      if [ "$multi_source" = "true" ]; then
        echo "  (argocd CLI 없음) Argo UI → Applications → $app → Sync → 두 번째 source(값 파일)의 Revision에 $previous_sha 입력"
      else
        echo "  (argocd CLI 없음) Argo UI → Applications → $app → Sync → Revision에 $previous_sha 입력"
      fi
    fi
  else
    echo "  ${app}의 직전 성공 기록이 deploy/approved-sync.md에 없다 — 수동으로 확인 후 이전 revision을 지정한다"
  fi
}

# --- self-test -----------------------------------------------------------------
# 가짜 kubectl로 "선행 조건 실패 → exit 1"만 재현한다. 실제 클러스터·git 동작은
# 손대지 않는다 — check_preconditions 함수 하나만 직접 부른다. maintenance-page의 Traefik
# provider 누락과 nvidia-device-plugin의 RuntimeClass 누락을 함께 본다.
#
# metallb·cert-manager의 helm template 렌더 경로(render_at_sha의 다중 source 분기)는
# 여기서 재현하지 않는다 — 실제 네트워크로 차트를 받아야 해서 가짜 kubectl 하나로
# 대체할 수 없다. 이 한계는 완료 보고에 남긴다.
self_test() {
  fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/argo-preflight-selftest-XXXXXX")
  trap 'rm -rf "$fake_bin"' EXIT HUP INT TERM
  cat > "$fake_bin/kubectl" << 'FAKE_KUBECTL'
#!/bin/sh
# maintenance-page 선행 조건만 재현한다: Traefik args에 --providers.kubernetescrd가 없는 상태.
# RuntimeClass 조회는 의도적으로 실패시켜 device plugin이 GPU runtime 없이 Sync되지
# 않는지도 확인한다.
case "$*" in
  *"traefik get pods"*)
    echo '["--entrypoints.web.address=:8000"]'
    ;;
  *)
    exit 1
    ;;
esac
FAKE_KUBECTL
  chmod +x "$fake_bin/kubectl"

  if PATH="$fake_bin:$PATH" check_preconditions maintenance-page 2> "$fake_bin/err"; then
    echo "self-test 실패: 선행 조건이 부족한데도 통과로 판정했다" >&2
    exit 1
  fi
  if ! grep -q "providers.kubernetescrd" "$fake_bin/err"; then
    echo "self-test 실패: 실패 사유 메시지가 기대한 내용을 담지 않았다" >&2
    cat "$fake_bin/err" >&2
    exit 1
  fi
  if PATH="$fake_bin:$PATH" check_preconditions nvidia-device-plugin 2> "$fake_bin/err"; then
    echo "self-test 실패: RuntimeClass가 없는데도 device plugin 선행 조건을 통과했다" >&2
    exit 1
  fi
  if ! grep -q "RuntimeClass/nvidia" "$fake_bin/err"; then
    echo "self-test 실패: device plugin RuntimeClass 실패 사유가 없다" >&2
    cat "$fake_bin/err" >&2
    exit 1
  fi
  self_test_public_gateway
  echo "self-test 통과: App별 선행 조건 실패 시 exit 1과 사유 메시지를 확인했다"
}

# public-gateway·maintenance-page 사례. 선언 검사는 실제 argocd/public-gateway.yaml과 로컬 렌더를,
# live 검사는 이관 뒤 정상 상태를 돌려주는 가짜 kubectl을 쓴다. 실제 클러스터를 대신하는 검증이 아니다.
self_test_public_gateway() {
  case_dir=$(mktemp -d "${TMPDIR:-/tmp}/argo-preflight-gateway-XXXXXX")
  err_file="$case_dir/err.txt"

  kubectl kustomize "$repo_dir/$PUBLIC_GATEWAY_SOURCE_PATH" > "$case_dir/rendered.yaml"
  cp "$repo_dir/argocd/public-gateway.yaml" "$case_dir/app.yaml"
  ruby -ryaml -e 'app = YAML.load_file(ARGV[0]); app["spec"]["source"]["path"] = "kustomize/overlays/prod/maintenance-page"; File.write(ARGV[1], YAML.dump(app))' \
    "$case_dir/app.yaml" "$case_dir/app-wrong-path.yaml"
  ruby -ryaml -e 'app = YAML.load_file(ARGV[0]); app["spec"]["syncPolicy"] = { "automated" => { "prune" => true } }; File.write(ARGV[1], YAML.dump(app))' \
    "$case_dir/app.yaml" "$case_dir/app-automated.yaml"

  healthy_bin="$case_dir/bin"
  mkdir "$healthy_bin"
  cat > "$healthy_bin/kubectl" << 'FAKE_HEALTHY'
#!/bin/sh
# 이관 뒤 정상 live 상태만 돌려준다. 그 밖의 호출은 실패시켜 예상하지 않은 조회를 드러낸다.
# FAKE_* 환경 변수로 한 가지씩 비정상 상태를 흉내 낸다. 로컬 렌더(kustomize)만 진짜 kubectl로 넘긴다.
if [ "$1" = "kustomize" ]; then exec "$REAL_KUBECTL" "$@"; fi
case "$*" in
  *"config current-context"*) echo "${FAKE_CONTEXT:-kubernetes-admin@kubernetes}" ;;
  *"config view --minify"*) echo "${FAKE_SERVER:-https://192.0.2.10:6443}" ;;
  *"traefik get pods"*) echo '["--providers.kubernetescrd","--providers.kubernetesgateway"]' ;;
  *"get gateway persona-app"*"metadata.uid"*) echo "${FAKE_LIVE_GATEWAY_UID-00000000-0000-4000-8000-000000000001}" ;;
  *"get gateway persona-app"*"tracking-id"*) echo "${FAKE_TRACKING:-public-gateway:gateway.networking.k8s.io/Gateway:persona-app/persona-app}" ;;
  *"get gateway persona-app"*"Programmed"*) echo "${FAKE_PROGRAMMED:-True}" ;;
  *"get certificate persona-app-tls"*"ownerReferences"*) printf '%s ' "${FAKE_CERT_OWNER:-Gateway/persona-app/00000000-0000-4000-8000-000000000001}" ;;
  *"get certificate persona-app-tls"*"notAfter"*) echo "${FAKE_NOT_AFTER:-2026-12-01T00:00:00Z}" ;;
  *"get certificate persona-app-tls"*"Ready"*) echo "${FAKE_CERT_READY:-True}" ;;
  *"get secret persona-app-tls"*"metadata.uid"*) echo "${FAKE_SECRET_UID-00000000-0000-4000-8000-000000000003}" ;;
  *"diff -f"*) [ -n "${FAKE_DIFF_EXIT:-}" ] && { echo "synthetic diff"; exit "$FAKE_DIFF_EXIT"; }; : ;;
  *"get application public-gateway"*) echo "${FAKE_AUTOMATED:-}" ;;
  *"get crd clusters.postgresql.cnpg.io"*) [ -z "${FAKE_NO_CNPG_CRD:-}" ] || exit 1; echo crd ;;
  *"get deployment cnpg-controller-manager"*) echo "${FAKE_CNPG_AVAILABLE:-True}" ;;
  *"get storageclass local-path"*) echo storageclass ;;
  *"get namespace mafest-data"*) [ -z "${FAKE_NO_MAFEST_NS:-}" ] || exit 1; echo namespace ;;
  *"get secret mafest-db-owner"*|*"get secret mafest-db-runtime"*) echo secret ;;
  *"get secret mafest-ghcr"*) [ -z "${FAKE_NO_PULL_SECRET:-}" ] || exit 1; echo secret ;;
  *"get node k8s-worker"*) echo "${FAKE_WORKER_READY:-True}" ;;
  *"get cluster mafest-db"*) echo "${FAKE_MAFEST_PHASE:-Cluster in healthy state}" ;;
  *"get pods -l k8s-app=cilium"*) echo cilium-abcde ;;
  *"exec cilium-abcde"*) [ -z "${FAKE_CILIUM_BAD:-}" ] || exit 1; echo ok ;;
  *) exit 1 ;;
esac
FAKE_HEALTHY
  chmod +x "$healthy_bin/kubectl"
  REAL_KUBECTL=$(command -v kubectl)
  export REAL_KUBECTL

  expect_failure() {  # 기대 종료 코드, 기대 문구, 명령...
    expected_code="$1"; expected_text="$2"; shift 2
    status=0
    "$@" 2> "$err_file" > /dev/null || status=$?
    if [ "$status" -ne "$expected_code" ] || ! grep -q "$expected_text" "$err_file"; then
      echo "self-test 실패: 기대(exit ${expected_code}, ${expected_text}) 실제(exit ${status})" >&2
      cat "$err_file" >&2
      exit 1
    fi
  }
  live_preconditions() {  # 별도 프로세스에서 선행 조건 입구 하나를 실행한다
    env PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions "$@"
  }

  # 정상 3건: 선언, public-gateway live, maintenance-page live
  check_public_gateway_declaration "$case_dir/app.yaml" "$case_dir/rendered.yaml" ||
    { echo "self-test 실패: 정상 public-gateway 선언을 거부했다" >&2; exit 1; }
  live_preconditions public-gateway > /dev/null ||
    { echo "self-test 실패: 정상 public-gateway live 상태를 거부했다" >&2; exit 1; }
  live_preconditions maintenance-page > /dev/null ||
    { echo "self-test 실패: 정상 maintenance-page 선행 조건을 거부했다" >&2; exit 1; }
  live_preconditions mafest-db > /dev/null ||
    { echo "self-test 실패: 정상 mafest-db 선행 조건을 거부했다" >&2; exit 1; }
  live_preconditions mafest-db-netpol > /dev/null ||
    { echo "self-test 실패: 정상 mafest-db-netpol 선행 조건을 거부했다" >&2; exit 1; }
  # 음성: mafest-db·mafest-db-netpol — operator·namespace·Secret 이름·워커, DB 상태·Cilium
  for mafest_case in "FAKE_NO_CNPG_CRD=1|mafest-db → CRD clusters.postgresql.cnpg.io가 없다" \
    "FAKE_CNPG_AVAILABLE=False|cnpg-controller-manager가 Available=True가 아니다" \
    "FAKE_NO_MAFEST_NS=1|Namespace mafest-data가 없다" \
    "FAKE_NO_PULL_SECRET=1|Secret mafest-ghcr이 없다" \
    "FAKE_WORKER_READY=False|Ready가 아니다 — 두 인스턴스"; do
    expect_failure 1 "${mafest_case#*|}" env "${mafest_case%%|*}" PATH="$healthy_bin:$PATH" \
      sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions mafest-db
  done
  for netpol_case in "FAKE_MAFEST_PHASE=Setting up primary|phase가 healthy가 아니다" \
    "FAKE_CILIUM_BAD=1|cilium-dbg status가 ok가 아니다"; do
    expect_failure 1 "${netpol_case#*|}" env "${netpol_case%%|*}" PATH="$healthy_bin:$PATH" \
      sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions mafest-db-netpol
  done
  # 정상: 기록값을 주고 그 값이 live와 같으면 통과한다.
  env PREFLIGHT_EXPECTED_GATEWAY_UID=00000000-0000-4000-8000-000000000001 PREFLIGHT_EXPECTED_CERT_NOT_AFTER=2026-12-01T00:00:00Z \
    PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway > /dev/null ||
    { echo "self-test 실패: 기록과 같은 live 상태를 거부했다" >&2; exit 1; }

  # 음성: 선언 3건
  expect_failure 1 "선행 조건 표에 없는 app" check_preconditions public-gatway
  expect_failure 1 "source.path가" check_public_gateway_declaration "$case_dir/app-wrong-path.yaml" "$case_dir/rendered.yaml"
  expect_failure 1 "syncPolicy가 있다" check_public_gateway_declaration "$case_dir/app-automated.yaml" "$case_dir/rendered.yaml"
  # 음성: 폐기한 Application은 선행 조건 표에서 빠졌다
  expect_failure 1 "선행 조건 표에 없는 app" check_preconditions persona-app
  # 음성: live — 다른 context, 이관 전 tracking, Gateway 없음·재생성, 소유 관계, Secret 없음, 재발급, 상태, 자동 Sync
  for live_case in "FAKE_CONTEXT=minikube|kube context가 kubernetes-admin@kubernetes가 아니다" \
    "FAKE_TRACKING=persona-app:gateway.networking.k8s.io/Gateway:persona-app/persona-app|소유권 이관(Phase 1)을 먼저" \
    "FAKE_LIVE_GATEWAY_UID=|live Gateway persona-app이 없다" \
    "PREFLIGHT_EXPECTED_GATEWAY_UID=00000000-0000-4000-8000-0000000000ff|그사이 재생성됐다" \
    "FAKE_CERT_OWNER=Gateway/persona-app/00000000-0000-4000-8000-0000000000ff|live Certificate ownerReference가" \
    "FAKE_SECRET_UID=|live TLS Secret persona-app-tls가 없다" \
    "PREFLIGHT_EXPECTED_CERT_NOT_AFTER=2026-09-01T00:00:00Z|재발급 여부를 먼저 확인한다" \
    "FAKE_PROGRAMMED=False|Programmed=True가 아니다" \
    "FAKE_CERT_READY=False|Ready=True가 아니다" \
    "FAKE_AUTOMATED={\"prune\":true}|syncPolicy.automated가 있다"; do
    expect_failure 1 "${live_case#*|}" env "${live_case%%|*}" PATH="$healthy_bin:$PATH" \
      sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway
  done
  # 음성: maintenance-page는 Gateway·인증서가 정상이어야 https Route가 붙는다
  expect_failure 1 "maintenance-page → Gateway persona-app이 Programmed=True가 아니다" \
    env FAKE_PROGRAMMED=False PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions maintenance-page
  # kubectl diff: exit 1(차이 있음)은 정상, exit 2 이상(접속·권한 오류)은 실패
  FAKE_DIFF_EXIT=1 PATH="$healthy_bin:$PATH" run_live_diff "$case_dir/rendered.yaml" "$case_dir/diff.txt" ||
    { echo "self-test 실패: kubectl diff exit 1(차이 있음)을 실패로 처리했다" >&2; exit 1; }
  FAKE_DIFF_EXIT=2 PATH="$healthy_bin:$PATH" run_live_diff "$case_dir/rendered.yaml" "$case_dir/diff.txt" 2> "$err_file" &&
    { echo "self-test 실패: kubectl diff exit 2(오류)를 통과시켰다" >&2; exit 1; }
  grep -q "kubectl diff가 오류로 끝났다(exit 2)" "$err_file" ||
    { echo "self-test 실패: diff 오류 사유가 없다" >&2; cat "$err_file" >&2; exit 1; }

  rm -rf "$case_dir"
  echo "self-test 통과: public-gateway·maintenance-page·mafest-db·mafest-db-netpol 정상 6건·음성 22건, diff 종료 코드 2건"
}

# --- main ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  usage
fi

if [ "$1" = "--self-test" ]; then
  self_test
  exit 0
fi

# self-test가 별도 프로세스에서 선행 조건만 실행해 실제 종료 코드를 확인하는 입구다.
# git fetch·렌더·diff·승인 기록을 하지 않는다.
if [ "$1" = "--check-preconditions" ] && [ $# -eq 2 ]; then
  check_preconditions "$2"
  exit $?
fi

app="$1"
require_tools

if [ ! -f "$repo_dir/argocd/$app.yaml" ]; then
  echo "argocd/$app.yaml이 없다 — Application 이름을 확인하라" >&2
  exit 1
fi

git -C "$repo_dir" fetch origin develop --quiet
sha=$(git -C "$repo_dir" rev-parse origin/develop)
echo "승인 SHA: $sha"

diff_file=$(mktemp "${TMPDIR:-/tmp}/argo-preflight-diff.XXXXXX")
trap 'rm -f "$diff_file"' EXIT HUP INT TERM

if ! git -C "$repo_dir" cat-file -e "$sha:argocd/$app.yaml" 2> /dev/null; then
  # 렌더 오류와 섞이지 않게 먼저 알린다. 선언 브랜치가 develop에 머지되기 전에는 여기서 멈춘다.
  echo "선행 조건 실패: $app → 승인 SHA ${sha}에 argocd/$app.yaml이 없다(선언 머지 전)" >&2
  exit 1
fi
render_at_sha "$app" "$sha" > "$diff_file.rendered"
if [ "$app" = "public-gateway" ]; then
  # Sync할 SHA의 Application 선언과 렌더를 검사한다. 작업 트리 파일이 아니라 승인 SHA 기준이다.
  git -C "$repo_dir" show "$sha:argocd/public-gateway.yaml" > "$diff_file.application"
  check_public_gateway_declaration "$diff_file.application" "$diff_file.rendered" || exit 1
fi
# 여기부터 클러스터에 닿는다. context가 홈 클러스터가 아니면 diff·live 조회를 하지 않는다.
require_expected_context || exit 1
run_live_diff "$diff_file.rendered" "$diff_file" || exit 1
summarize_diff "$diff_file"
echo "전체 diff: $diff_file"
echo

precondition_status=0
check_preconditions "$app" || precondition_status=$?
if [ "$precondition_status" -ne 0 ]; then
  exit "$precondition_status"
fi
echo "선행 조건 통과: $app"

print_next_commands "$app" "$sha"
record_approved_sha "$app" "$sha" "선행조건 통과(Sync 전)"
