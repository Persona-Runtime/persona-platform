#!/bin/sh

set -eu

# Sync 통제(2026-09-19) — Argo Application을 Sync하기 전에 사람이 눌러야 하는 확인들을
# 기계적으로 강제한다. 이 스크립트는 읽기만 한다: kubectl get/diff, git fetch/worktree
# (읽기 전용 조회). kubectl apply·argocd app sync는 이 스크립트 안에서 절대 실행하지 않는다
# — 마지막에 사람이 실행할 명령을 "출력"만 한다.
#
# 사용법:
#   scripts/argo-preflight.sh <app>     # persona-app, persona-app-ingress, persona-app-netpol,
#                                        # persona-db, persona-db-netpol, persona-edge,
#                                        # metallb, metallb-config, cert-manager,
#                                        # cert-manager-issuers, gpu-runtime, dcgm-exporter,
#                                        # nvidia-device-plugin, public-gateway 중 하나
#   scripts/argo-preflight.sh --self-test
#   PHASE0_RUN_DIR=... scripts/argo-preflight.sh --check-phase0 public-gateway   # 클러스터 없이 선언·Phase 0만
#
# live 조회 전에 kube context가 PREFLIGHT_KUBE_CONTEXT(기본 kubernetes-admin@kubernetes)인지 확인한다.
#
# public-gateway는 Phase 0 수집 결과 하나를 명시해야 한다(다른 run 파일을 섞지 않기 위해).
#   PHASE0_RUN_DIR=runbooks/transition/phase0/out/<run-id> scripts/argo-preflight.sh public-gateway
# 이 값이 없거나 입력이 불완전하면 APPLY BLOCKED로 exit 2 한다(일반 선행 조건 실패는 exit 1).

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
approved_sync_file="$repo_dir/deploy/approved-sync.md"

usage() {
  echo "사용법: $0 <app> | $0 --self-test | $0 --check-phase0 public-gateway" >&2
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
# Gateway persona-app은 기존 객체를 같은 UID로 넘겨받아야 한다(runbooks/transition/phase1/README.md).
# Gateway가 한 번이라도 삭제되면 gateway-shim이 만든 Certificate가 ownerReference로 함께 지워질 수
# 있으므로, Sync 명령을 출력하기 전에 아래 세 가지를 모두 확인한다.
#   (1) 선언: Application path·destination, 자동 Sync·finalizer 없음, 렌더는 Gateway 하나뿐
#   (2) Phase 0 입력: 명시한 run 하나의 수집 결과가 완전하고 이관을 막는 상태가 없음
#   (3) live: Gateway·Certificate·HTTPRoute가 지금 정상이고 원 Application에 자동 Sync가 없음
PUBLIC_GATEWAY_SOURCE_PATH="kustomize/overlays/prod/public-gateway"
PHASE0_BLOCKED_EXIT=2
# 이관 전 Gateway가 가져야 하는 Argo tracking-id(annotation 방식, <app>:<group>/<Kind>:<ns>/<name>).
# 이관 후 기대값은 public-gateway:gateway.networking.k8s.io/Gateway:persona-app/persona-app이다.
GATEWAY_TRACKING_ID_BEFORE="persona-app:gateway.networking.k8s.io/Gateway:persona-app/persona-app"
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

# Phase 0 수집 파일 하나가 성공한 조회인지 본다. collect.sh는 파일 꼬리에 exit_code를 남긴다.
phase0_query_succeeded() {
  file="$1/$2.txt"
  [ -f "$file" ] && grep -qx '# exit_code: 0' "$file"
}

# custom-columns 출력의 첫 데이터 행에서 열 이름($3)의 값을 꺼낸다. 주석(#)과 빈 줄은 건너뛴다.
phase0_column() {
  awk -v column="$3" '
    /^#/ || NF == 0 { next }
    !header { for (i = 1; i <= NF; i++) index_of[$i] = i; header = 1; next }
    { if (column in index_of) print $(index_of[column]); exit }
  ' "$1/$2.txt"
}

# (2) $1 = Phase 0 run 디렉터리(out/<run-id>). 입력이 없거나 이관을 막는 상태면 APPLY BLOCKED(2).
check_phase0_inputs_for_gateway() {
  run_dir="$1"
  blocked() { echo "APPLY BLOCKED: public-gateway → $1" >&2; return "$PHASE0_BLOCKED_EXIT"; }

  if [ -z "$run_dir" ]; then
    blocked "PHASE0_RUN_DIR가 없다 — runbooks/transition/phase0/out/<run-id> 하나를 명시한다"
    return
  fi
  [ -d "$run_dir" ] || { blocked "Phase 0 run 디렉터리가 없다: $run_dir"; return; }
  # 디렉터리 이름과 수집기가 기록한 run_id가 같아야 한 run의 파일만 읽는다는 것이 보장된다.
  # 다른 run의 파일을 복사해 넣거나 디렉터리 이름을 바꾸면 여기서 막힌다.
  recorded_run_id=$(awk -F'\t' '$1 == "# run_id" { print $2 }' "$run_dir/00_run_info.txt" 2> /dev/null || true)
  if [ -z "$recorded_run_id" ] || [ "$recorded_run_id" != "$(basename "$run_dir")" ]; then
    blocked "00_run_info.txt의 run_id(${recorded_run_id:-없음})가 디렉터리 이름 $(basename "$run_dir")과 다르다"
    return
  fi
  # 이 검사가 읽지 않는 파일까지 포함해 required 조회가 하나라도 실패한 run은 쓰지 않는다.
  # optional 실패(예: CP에 checkout이 없어 git rev-parse 실패)는 Phase 1 입력이 아니므로 허용한다.
  required_failures=$(awk -F'\t' '$1 == "# required_failures" { print $2 }' "$run_dir/manifest.tsv" 2> /dev/null || true)
  if [ "$required_failures" != "0" ]; then
    blocked "manifest.tsv의 required_failures가 0이 아니다(실제: ${required_failures:-없음}) — run 전체를 다시 수집한다"
    return
  fi
  for query in phase1_gateway_uid phase1_certificate argocd_resource_tracking \
    argo_applications argo_application_resources ns_persona-app_ingress_and_policies \
    ns_persona-app_secret_names kube_context_server; do
    phase0_query_succeeded "$run_dir" "$query" || { blocked "필수 Phase 0 조회가 없거나 실패했다: ${query}.txt"; return; }
  done

  gateway_uid=$(phase0_column "$run_dir" phase1_gateway_uid UID)
  gateway_programmed=$(phase0_column "$run_dir" phase1_gateway_uid PROGRAMMED)
  if [ -z "$gateway_uid" ] || [ "$gateway_uid" = "<none>" ] || [ "$gateway_programmed" != "True" ]; then
    blocked "Phase 0 Gateway UID·Programmed가 비었거나 정상이 아니다(UID=${gateway_uid:-없음}, Programmed=${gateway_programmed:-없음})"
    return
  fi
  cert_uid=$(phase0_column "$run_dir" phase1_certificate UID)
  # TLS Secret은 이름·type·UID만 수집돼 있다(값 없음). Sync 직전 live UID와 비교할 기준이다.
  tls_secret_uid=$(awk '!/^#/ && $2 == "persona-app-tls" { print $4; exit }' "$run_dir/ns_persona-app_secret_names.txt")
  # 수집 당시 context가 가리킨 API server. live 조회 전에 지금 context의 server와 같은지 본다.
  phase0_api_server=$(awk -F'\t' '!/^#/ && NF >= 2 { print $2; exit }' "$run_dir/kube_context_server.txt")
  if [ -z "$tls_secret_uid" ] || [ -z "$phase0_api_server" ]; then
    blocked "Phase 0에서 TLS Secret UID 또는 API server를 읽지 못했다(secret_uid=${tls_secret_uid:-없음}, server=${phase0_api_server:-없음})"
    return
  fi
  cert_ready=$(phase0_column "$run_dir" phase1_certificate READY)
  cert_not_after=$(phase0_column "$run_dir" phase1_certificate NOT_AFTER)
  cert_secret=$(phase0_column "$run_dir" phase1_certificate SECRET)
  if [ "$cert_ready" != "True" ] || [ -z "$cert_not_after" ] || [ "$cert_not_after" = "<none>" ] || [ "$cert_secret" != "persona-app-tls" ]; then
    blocked "Phase 0 Certificate가 Ready·notAfter·secretName 조건을 만족하지 않는다(Ready=${cert_ready:-없음}, notAfter=${cert_not_after:-없음}, secret=${cert_secret:-없음})"
    return
  fi
  # 원 Application이 자동 prune이면 Git에서 Gateway가 빠지는 순간 삭제될 수 있다.
  persona_app_sync_policy=$(awk -F'\t' '$1 == "persona-app" { for (i = 2; i <= NF; i++) if ($i ~ /^syncPolicy=/) print $i }' "$run_dir/argo_applications.txt")
  case "$persona_app_sync_policy" in
    "") blocked "Phase 0 argo_applications.txt에 persona-app 행이 없다"; return ;;
    *automated*) blocked "Phase 0에서 persona-app에 syncPolicy.automated가 있다 — 별도 승인 전 이관 금지"; return ;;
  esac
  # Gateway를 추적하는 Application이 persona-app 하나여야 "한 소유자 → 다른 소유자" 이동이 된다.
  gateway_trackers=$(awk -F'\t' '
    /^APP\t/ { app = $2; next }
    $2 == "Gateway" && $3 == "persona-app" && $4 == "persona-app" { print app }
  ' "$run_dir/argo_application_resources.txt" | sort -u | tr '\n' ' ')
  if [ "$gateway_trackers" != "persona-app " ]; then
    blocked "Phase 0에서 Gateway persona-app을 추적하는 Application이 persona-app 하나가 아니다(실제: ${gateway_trackers:-없음})"
    return
  fi
  # Gateway의 실제 tracking-id와 Certificate의 소유자를 같은 run의 전체 객체에서 확인한다.
  # - tracking-id가 이관 전 기대값이 아니면 이미 다른 Application이 손댄 상태라 런북 순서가 맞지 않는다.
  # - Certificate ownerReference가 이 Gateway(같은 UID)가 아니면 "Gateway 삭제 = 인증서 삭제" 판단이
  #   달라지므로 런북 보호 판단을 다시 해야 한다.
  # 사유는 임시 파일로 받는다. Phase 0 결과 폴더에는 아무것도 쓰지 않는다.
  ownership_err=$(mktemp "${TMPDIR:-/tmp}/argo-preflight-ownership.XXXXXX")
  if ! ruby -ryaml -e '# encoding: utf-8
    path, expected_tracking, gateway_uid, cert_uid = ARGV
    body = File.readlines(path).reject { |line| line.start_with?("#") }.join
    items = (YAML.safe_load(body) || {}).fetch("items", [])
    find = lambda { |kind, name| items.find { |o| o["kind"] == kind && o.dig("metadata", "name") == name } }
    gateway = find.call("Gateway", "persona-app") or abort("Gateway persona-app이 없다")
    abort("Gateway UID가 phase1_gateway_uid.txt와 다르다") unless gateway.dig("metadata", "uid") == gateway_uid
    tracking = gateway.dig("metadata", "annotations", "argocd.argoproj.io/tracking-id")
    abort("Gateway tracking-id가 이관 전 기대값이 아니다(실제: #{tracking.inspect})") unless tracking == expected_tracking
    cert = find.call("Certificate", "persona-app-tls") or abort("Certificate persona-app-tls가 없다")
    abort("Certificate UID가 phase1_certificate.txt와 다르다") unless cert.dig("metadata", "uid") == cert_uid
    owners = (cert.dig("metadata", "ownerReferences") || []).map { |o| [o["kind"], o["name"], o["uid"]] }
    abort("Certificate ownerReference가 Gateway persona-app 하나가 아니다(실제: #{owners})") unless owners == [["Gateway", "persona-app", gateway_uid]]
  ' "$run_dir/ns_persona-app_ingress_and_policies.txt" "$GATEWAY_TRACKING_ID_BEFORE" "$gateway_uid" "$cert_uid" 2> "$ownership_err"; then
    reason=$(cat "$ownership_err")
    rm -f "$ownership_err"
    blocked "Phase 0 소유 관계가 예상과 다르다: ${reason}"
    return
  fi
  rm -f "$ownership_err"
  # argocd-cm에 키가 없으면 빈 본문(exit 0)이다. 수집 실패가 아니라 "키 미설정"이며,
  # Argo CD 3.x 기본값은 annotation이다(위 tracking-id 확인으로 실제 동작도 본다).
  tracking_method=$(awk '!/^#/ && NF { print; exit }' "$run_dir/argocd_resource_tracking.txt")
  echo "Phase 0 입력 확인: run=$(basename "$run_dir") gateway_uid=$gateway_uid cert_uid=$cert_uid tls_secret_uid=$tls_secret_uid api_server=$phase0_api_server cert_not_after=$cert_not_after resourceTrackingMethod=${tracking_method:-키 미설정(annotation tracking-id 확인)}"
}

# live 조회 전에 kube context가 홈 클러스터인지 본다. 다른 context(예: 맥의 minikube)에서 실행하면
# Gateway가 없다는 실패나, 우연히 같은 이름 객체의 "통과"를 홈 클러스터 결과로 오해할 수 있다.
# context 이름은 kubeconfig마다 같을 수 있으므로 그 context가 가리키는 API server URL도 본다.
# $1 = 기대 API server(public-gateway는 Phase 0 run의 kube_context_server.txt 값). 비어 있으면
# PREFLIGHT_KUBE_SERVER를 쓰고, 그것도 없으면 이름만 확인한다(다른 앱의 기존 동작 유지).
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

# (3) live 상태. Phase 0 이후 상태가 바뀌었을 수 있으므로 Sync 직전에 다시 읽는다(읽기 전용).
# check_phase0_inputs_for_gateway가 먼저 실행돼 gateway_uid·cert_uid(Phase 0 값)를 채워 둔다.
check_live_gateway_state() {
  # --check-preconditions처럼 main의 가드를 거치지 않는 입구에서도 다른 클러스터를 읽지 않게 한다.
  require_expected_context "$phase0_api_server" || return 1
  # 이름이 같아도 UID가 다르면 Phase 0 이후 재생성된 객체다. 그 상태에서 이관하면 안 된다.
  live_gateway_uid=$(kubectl -n persona-app get gateway persona-app -o jsonpath='{.metadata.uid}' 2> /dev/null || true)
  live_cert_uid=$(kubectl -n persona-app get certificate persona-app-tls -o jsonpath='{.metadata.uid}' 2> /dev/null || true)
  if [ "$live_gateway_uid" != "$gateway_uid" ] || [ "$live_cert_uid" != "$cert_uid" ]; then
    echo "선행 조건 실패: public-gateway → live UID가 Phase 0와 다르다(Gateway ${live_gateway_uid:-없음} vs ${gateway_uid}, Certificate ${live_cert_uid:-없음} vs ${cert_uid})" >&2
    return 1
  fi
  # TLS Secret은 metadata.uid만 읽는다. 값(data)은 조회하지 않는다.
  live_secret_uid=$(kubectl -n persona-app get secret persona-app-tls -o jsonpath='{.metadata.uid}' 2> /dev/null || true)
  if [ "$live_secret_uid" != "$tls_secret_uid" ]; then
    echo "선행 조건 실패: public-gateway → live TLS Secret UID가 Phase 0와 다르다(${live_secret_uid:-없음} vs ${tls_secret_uid})" >&2
    return 1
  fi
  # 소유 관계는 Phase 0 파일이 아니라 Sync 직전 live 값으로 다시 본다. 그사이 다른 Application이
  # Gateway를 Sync했거나 Certificate가 다시 만들어졌으면 런북의 보호 판단이 맞지 않는다.
  live_tracking=$(kubectl -n persona-app get gateway persona-app \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2> /dev/null || true)
  if [ "$live_tracking" != "$GATEWAY_TRACKING_ID_BEFORE" ]; then
    echo "선행 조건 실패: public-gateway → live Gateway tracking-id가 이관 전 기대값이 아니다(실제: ${live_tracking:-없음})" >&2
    return 1
  fi
  live_cert_owners=$(kubectl -n persona-app get certificate persona-app-tls \
    -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name}/{.uid}{" "}{end}' 2> /dev/null || true)
  if [ "$live_cert_owners" != "Gateway/persona-app/${live_gateway_uid} " ]; then
    echo "선행 조건 실패: public-gateway → live Certificate ownerReference가 현재 Gateway 하나가 아니다(실제: ${live_cert_owners:-없음})" >&2
    return 1
  fi
  # 인증서가 갱신되면 notAfter가 바뀐다. 갱신 자체는 정상일 수 있지만 이관 전후 비교 기준이 바뀌므로
  # 조용히 넘기지 않는다. 런북 1단계 capture before에서 새 값을 확인한 뒤
  # PHASE1_EXPECTED_CERT_NOT_AFTER로 명시적으로 기준을 바꿔야 통과한다.
  expected_not_after="${PHASE1_EXPECTED_CERT_NOT_AFTER:-$cert_not_after}"
  live_not_after=$(kubectl -n persona-app get certificate persona-app-tls -o jsonpath='{.status.notAfter}' 2> /dev/null || true)
  if [ "$live_not_after" != "$expected_not_after" ]; then
    echo "선행 조건 실패: public-gateway → live Certificate notAfter가 기준과 다르다(실제 ${live_not_after:-없음}, 기준 ${expected_not_after}) — capture before로 확인한 뒤 PHASE1_EXPECTED_CERT_NOT_AFTER로 기준을 명시한다" >&2
    return 1
  fi
  programmed=$(kubectl -n persona-app get gateway persona-app \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2> /dev/null || true)
  if [ "$programmed" != "True" ]; then
    echo "선행 조건 실패: public-gateway → live Gateway persona-app이 Programmed=True가 아니다(실제: ${programmed:-없음})" >&2
    return 1
  fi
  ready=$(kubectl -n persona-app get certificate persona-app-tls \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
  if [ "$ready" != "True" ]; then
    echo "선행 조건 실패: public-gateway → live Certificate persona-app-tls가 Ready=True가 아니다(실제: ${ready:-없음})" >&2
    return 1
  fi
  for route in persona-app persona-app-public; do
    route_state=$(kubectl -n persona-app get httproute "$route" \
      -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}/{.status.parents[*].conditions[?(@.type=="ResolvedRefs")].status}' 2> /dev/null || true)
    if [ "$route_state" != "True/True" ]; then
      echo "선행 조건 실패: public-gateway → live HTTPRoute ${route}의 Accepted/ResolvedRefs가 True/True가 아니다(실제: ${route_state:-없음})" >&2
      return 1
    fi
  done
  # 조회 실패를 "automated 없음"으로 읽지 않도록 종료 코드를 따로 본다.
  if ! automated=$(kubectl -n argocd get application persona-app -o jsonpath='{.spec.syncPolicy.automated}' 2> /dev/null); then
    echo "선행 조건 실패: public-gateway → live Application persona-app을 읽지 못했다" >&2
    return 1
  fi
  if [ -n "$automated" ]; then
    echo "선행 조건 실패: public-gateway → live persona-app에 syncPolicy.automated가 있다" >&2
    return 1
  fi
}

# --- 4. 선행 조건 -------------------------------------------------------------
# 실패하면 "어떤 조건인지"를 stderr에 적고 exit 1 한다. 이 함수 하나가 이 스크립트의
# 핵심이라 --self-test가 직접 이 함수를 부른다(fake kubectl로).
check_preconditions() {
  app="$1"
  case "$app" in
    persona-app)
      args=$(kubectl -n traefik get pods -l app.kubernetes.io/name=traefik \
        -o jsonpath='{.items[0].spec.containers[0].args}' 2> /dev/null || true)
      case "$args" in
        *--providers.kubernetescrd*) : ;;
        *)
          echo "선행 조건 실패: persona-app → Traefik Pod args에 --providers.kubernetescrd가 없다" >&2
          return 1
          ;;
      esac
      ;;
    public-gateway)
      # Phase 0 입력이 먼저다. 입력이 없으면 live가 정상이어도 APPLY BLOCKED로 끝낸다.
      check_phase0_inputs_for_gateway "${PHASE0_RUN_DIR:-}" || return $?
      check_live_gateway_state || return 1
      ;;
    persona-app-ingress)
      ready=$(kubectl -n persona-app get certificate persona-app-tls \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
      if [ "$ready" != "True" ]; then
        echo "선행 조건 실패: persona-app-ingress → Certificate persona-app-tls가 Ready=True가 아니다(실제: ${ready:-없음})" >&2
        return 1
      fi
      if ! kubectl -n persona-edge get service oauth2-proxy > /dev/null 2>&1; then
        echo "선행 조건 실패: persona-app-ingress → Service oauth2-proxy.persona-edge가 없다" >&2
        return 1
      fi
      if [ -z "$(kubectl -n persona-edge get referencegrant -o name 2> /dev/null || true)" ]; then
        echo "선행 조건 실패: persona-app-ingress → persona-edge에 ReferenceGrant가 없다" >&2
        return 1
      fi
      ;;
    persona-edge)
      for secret in oauth2-proxy cloudflare-dns-token; do
        if ! kubectl -n persona-edge get secret "$secret" > /dev/null 2>&1; then
          echo "선행 조건 실패: persona-edge → Secret ${secret}이 없다" >&2
          return 1
        fi
      done
      ;;
    persona-app-netpol | persona-db-netpol)
      target_ns=$(app_namespace "$app")
      cilium_pod=$(kubectl -n kube-system get pods -l k8s-app=cilium \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2> /dev/null || true)
      if [ -z "$cilium_pod" ]; then
        echo "선행 조건 실패: $app → Running 상태인 cilium Pod를 못 찾았다" >&2
        return 1
      fi
      if ! kubectl -n kube-system exec "$cilium_pod" -c cilium-agent -- cilium-dbg status --brief > /dev/null 2>&1; then
        echo "선행 조건 실패: $app → cilium-dbg status가 ok가 아니다" >&2
        return 1
      fi
      not_ready=$(kubectl -n "$target_ns" get pods \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2> /dev/null \
        | grep -vc '^True$' || true)
      if [ "${not_ready:-0}" -ne 0 ]; then
        echo "선행 조건 실패: $app → $target_ns 네임스페이스에 Ready가 아닌 Pod가 있다" >&2
        return 1
      fi
      ;;
    persona-db)
      phase=$(kubectl -n persona-data get cluster persona-db -o jsonpath='{.status.phase}' 2> /dev/null || true)
      case "$phase" in
        *[Hh]ealthy*) : ;;
        *)
          echo "선행 조건 실패: persona-db → Cluster persona-db phase가 healthy가 아니다(실제: ${phase:-없음})" >&2
          return 1
          ;;
      esac
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
# 손대지 않는다 — check_preconditions 함수 하나만 직접 부른다. persona-app의 Traefik
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
# persona-app 선행 조건만 재현한다: Traefik args에 --providers.kubernetescrd가 없는 상태.
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

  if PATH="$fake_bin:$PATH" check_preconditions persona-app 2> /tmp/argo-preflight-selftest.err; then
    echo "self-test 실패: 선행 조건이 부족한데도 통과로 판정했다" >&2
    exit 1
  fi
  if ! grep -q "providers.kubernetescrd" /tmp/argo-preflight-selftest.err; then
    echo "self-test 실패: 실패 사유 메시지가 기대한 내용을 담지 않았다" >&2
    cat /tmp/argo-preflight-selftest.err >&2
    exit 1
  fi
  if PATH="$fake_bin:$PATH" check_preconditions nvidia-device-plugin 2> /tmp/argo-preflight-selftest.err; then
    echo "self-test 실패: RuntimeClass가 없는데도 device plugin 선행 조건을 통과했다" >&2
    exit 1
  fi
  if ! grep -q "RuntimeClass/nvidia" /tmp/argo-preflight-selftest.err; then
    echo "self-test 실패: device plugin RuntimeClass 실패 사유가 없다" >&2
    cat /tmp/argo-preflight-selftest.err >&2
    exit 1
  fi
  rm -f /tmp/argo-preflight-selftest.err
  self_test_public_gateway
  echo "self-test 통과: App별 선행 조건 실패 시 exit 1과 사유 메시지를 확인했다"
}

# public-gateway 사례. 선언 검사는 실제 argocd/public-gateway.yaml과 로컬 렌더를, Phase 0 입력은
# collect.sh 출력 형식을 흉내 낸 합성 파일을, live 검사는 정상 상태를 돌려주는 가짜 kubectl을 쓴다.
# 실제 클러스터·Phase 0 결과를 대신하는 검증이 아니다.
self_test_public_gateway() {
  case_dir=$(mktemp -d "${TMPDIR:-/tmp}/argo-preflight-gateway-XXXXXX")
  err_file="$case_dir/err.txt"

  kubectl kustomize "$repo_dir/$PUBLIC_GATEWAY_SOURCE_PATH" > "$case_dir/rendered.yaml"
  cp "$repo_dir/argocd/public-gateway.yaml" "$case_dir/app.yaml"
  ruby -ryaml -e 'app = YAML.load_file(ARGV[0]); app["spec"]["source"]["path"] = "kustomize/overlays/prod/persona-app"; File.write(ARGV[1], YAML.dump(app))' \
    "$case_dir/app.yaml" "$case_dir/app-wrong-path.yaml"
  ruby -ryaml -e 'app = YAML.load_file(ARGV[0]); app["spec"]["syncPolicy"] = { "automated" => { "prune" => true } }; File.write(ARGV[1], YAML.dump(app))' \
    "$case_dir/app.yaml" "$case_dir/app-automated.yaml"

  # 실제 collect.sh 출력 형식을 따른다(phase0-20261004T085218Z에서 확인한 모양):
  # manifest 꼬리의 실패 건수, argocd-cm 키가 없을 때의 빈 본문(exit 0), optional git 실패,
  # 같은 run의 Gateway·Certificate 전체 객체(-o yaml).
  run_id="phase0-20261004T000000Z"
  run_dir="$case_dir/out/$run_id"
  gateway_uid_fixture="00000000-0000-4000-8000-000000000001"
  cert_uid_fixture="00000000-0000-4000-8000-000000000002"
  mkdir -p "$run_dir"
  printf '# phase0 collect run\n# run_id\t%s\n' "$run_id" > "$run_dir/00_run_info.txt"
  write_manifest() {  # required 실패 수
    printf '# run_id\t%s\nname\tclass\texit_code\nphase1_gateway_uid\trequired\t0\ngit_rev_parse_origin_develop\toptional\t128\n# required_failures\t%s\n# optional_failures\t1\n' \
      "$run_id" "$1" > "$run_dir/manifest.tsv"
  }
  write_manifest 0
  write_query() {  # 이름, 본문 — collect.sh처럼 머리말과 exit_code 꼬리를 붙인다
    printf '# command: synthetic\n# collected_at: 2026-10-04T00:00:00Z\n# class: required\n\n%s\n\n# exit_code: 0\n' "$2" > "$run_dir/$1.txt"
  }
  write_ingress_objects() {  # Gateway tracking-id
    write_query ns_persona-app_ingress_and_policies "apiVersion: v1
items:
- kind: Gateway
  metadata:
    name: persona-app
    namespace: persona-app
    uid: ${gateway_uid_fixture}
    annotations:
      argocd.argoproj.io/tracking-id: $1
- kind: Certificate
  metadata:
    name: persona-app-tls
    namespace: persona-app
    uid: ${cert_uid_fixture}
    ownerReferences:
    - kind: Gateway
      name: persona-app
      uid: ${gateway_uid_fixture}
kind: List"
  }
  write_query phase1_gateway_uid "NAME          UID                                    CLASS     PROGRAMMED
persona-app   ${gateway_uid_fixture}   traefik   True"
  write_query phase1_certificate "NAME              UID                                    READY   NOT_AFTER              RENEWAL                SECRET
persona-app-tls   ${cert_uid_fixture}   True    2026-12-01T00:00:00Z   2026-11-01T00:00:00Z   persona-app-tls"
  write_query argocd_resource_tracking ""
  write_query ns_persona-app_secret_names "NAMESPACE     NAME              TYPE                UID
persona-app   persona-app-tls   kubernetes.io/tls   00000000-0000-4000-8000-000000000003"
  write_query kube_context_server "$(printf 'kubernetes\thttps://192.0.2.10:6443')"
  write_query argo_applications "$(printf 'persona-app\tproject=default\tpath=kustomize/overlays/prod/persona-app\tsyncPolicy=\tsync=Synced')"
  write_query argo_application_resources "$(printf 'APP\tpersona-app\n  gateway.networking.k8s.io\tGateway\tpersona-app\tpersona-app\tsync=Synced\thealth=')"
  write_ingress_objects "$GATEWAY_TRACKING_ID_BEFORE"

  healthy_bin="$case_dir/bin"
  mkdir "$healthy_bin"
  cat > "$healthy_bin/kubectl" << 'FAKE_HEALTHY'
#!/bin/sh
# 정상 live 상태만 돌려준다. 그 밖의 호출은 실패시켜 예상하지 않은 조회를 드러낸다.
# FAKE_LIVE_GATEWAY_UID로 Phase 0 이후 재생성된 Gateway(UID 변경)를 흉내 낸다.
# 로컬 렌더(kustomize)만 진짜 kubectl로 넘긴다. --check-phase0가 클러스터에 닿지 않는다는 것도 함께 본다.
if [ "$1" = "kustomize" ]; then exec "$REAL_KUBECTL" "$@"; fi
case "$*" in
  *"config current-context"*) echo "${FAKE_CONTEXT:-kubernetes-admin@kubernetes}" ;;
  *"config view --minify"*) echo "${FAKE_SERVER:-https://192.0.2.10:6443}" ;;
  *"get gateway persona-app"*"metadata.uid"*) echo "${FAKE_LIVE_GATEWAY_UID:-00000000-0000-4000-8000-000000000001}" ;;
  *"get gateway persona-app"*"tracking-id"*) echo "${FAKE_TRACKING:-persona-app:gateway.networking.k8s.io/Gateway:persona-app/persona-app}" ;;
  *"get certificate persona-app-tls"*"metadata.uid"*) echo 00000000-0000-4000-8000-000000000002 ;;
  *"get certificate persona-app-tls"*"ownerReferences"*) printf '%s ' "${FAKE_CERT_OWNER:-Gateway/persona-app/00000000-0000-4000-8000-000000000001}" ;;
  *"get certificate persona-app-tls"*"notAfter"*) echo "${FAKE_NOT_AFTER:-2026-12-01T00:00:00Z}" ;;
  *"get secret persona-app-tls"*"metadata.uid"*) echo "${FAKE_SECRET_UID:-00000000-0000-4000-8000-000000000003}" ;;
  *"diff -f"*) [ -n "${FAKE_DIFF_EXIT:-}" ] && { echo "synthetic diff"; exit "$FAKE_DIFF_EXIT"; }; : ;;
  *"get gateway persona-app"*) echo True ;;
  *"get certificate persona-app-tls"*) echo True ;;
  *"get httproute"*) echo True/True ;;
  *"get application persona-app"*) : ;;
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
  preflight_entry() {  # 별도 프로세스에서 입구 하나를 실행한다
    env PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" "$@"
  }

  # 정상: 선언·Phase 0 입력(빈 tracking 본문·optional 실패 포함)·live가 모두 맞으면 통과한다.
  check_public_gateway_declaration "$case_dir/app.yaml" "$case_dir/rendered.yaml" ||
    { echo "self-test 실패: 정상 public-gateway 선언을 거부했다" >&2; exit 1; }
  PHASE0_RUN_DIR="$run_dir" PATH="$healthy_bin:$PATH" check_preconditions public-gateway > /dev/null ||
    { echo "self-test 실패: 정상 Phase 0 입력·live 상태를 거부했다" >&2; exit 1; }
  PHASE0_RUN_DIR="$run_dir" preflight_entry --check-phase0 public-gateway > /dev/null ||
    { echo "self-test 실패: --check-phase0가 정상 선언·Phase 0 입력을 거부했다" >&2; exit 1; }
  PATH="$healthy_bin:$PATH" require_expected_context ||
    { echo "self-test 실패: 기대 context를 거부했다" >&2; exit 1; }

  # 음성: 선언 3건
  expect_failure 1 "선행 조건 표에 없는 app" check_preconditions public-gatway
  expect_failure 1 "source.path가" check_public_gateway_declaration "$case_dir/app-wrong-path.yaml" "$case_dir/rendered.yaml"
  expect_failure 1 "syncPolicy가 있다" check_public_gateway_declaration "$case_dir/app-automated.yaml" "$case_dir/rendered.yaml"
  # 음성: live 2건 — 다른 context(맥의 minikube 등), Phase 0 이후 Gateway 재생성(UID 변경)
  FAKE_CONTEXT=minikube PATH="$healthy_bin:$PATH" require_expected_context 2> "$err_file" &&
    { echo "self-test 실패: minikube context를 통과시켰다" >&2; exit 1; }
  grep -q "kube context가 kubernetes-admin@kubernetes가 아니다" "$err_file" ||
    { echo "self-test 실패: context 불일치 사유가 없다" >&2; cat "$err_file" >&2; exit 1; }
  expect_failure 1 "live UID가 Phase 0와 다르다" \
    env PHASE0_RUN_DIR="$run_dir" FAKE_LIVE_GATEWAY_UID=00000000-0000-4000-8000-0000000000ff PATH="$healthy_bin:$PATH" \
    sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway
  # 음성: live 소유권·기준값 5건 — Sync 직전 live 값이 Phase 0와 달라진 경우
  for live_case in "FAKE_SERVER=https://127.0.0.1:8443|API server가" \
    "FAKE_TRACKING=public-gateway:gateway.networking.k8s.io/Gateway:persona-app/persona-app|live Gateway tracking-id가" \
    "FAKE_CERT_OWNER=Gateway/persona-app/00000000-0000-4000-8000-0000000000ff|live Certificate ownerReference가" \
    "FAKE_SECRET_UID=00000000-0000-4000-8000-0000000000ee|live TLS Secret UID가" \
    "FAKE_NOT_AFTER=2027-03-01T00:00:00Z|live Certificate notAfter가 기준과 다르다"; do
    expect_failure 1 "${live_case#*|}" \
      env "${live_case%%|*}" PHASE0_RUN_DIR="$run_dir" PATH="$healthy_bin:$PATH" \
      sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway
  done
  # 정상: 갱신된 notAfter도 capture before 뒤 기준을 명시하면 통과한다.
  env FAKE_NOT_AFTER=2027-03-01T00:00:00Z PHASE1_EXPECTED_CERT_NOT_AFTER=2027-03-01T00:00:00Z \
    PHASE0_RUN_DIR="$run_dir" PATH="$healthy_bin:$PATH" \
    sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway > /dev/null 2>&1 ||
    { echo "self-test 실패: 명시한 notAfter 기준을 거부했다" >&2; exit 1; }
  # kubectl diff: exit 1(차이 있음)은 정상, exit 2 이상(접속·권한 오류)은 실패
  FAKE_DIFF_EXIT=1 PATH="$healthy_bin:$PATH" run_live_diff "$case_dir/rendered.yaml" "$case_dir/diff.txt" ||
    { echo "self-test 실패: kubectl diff exit 1(차이 있음)을 실패로 처리했다" >&2; exit 1; }
  FAKE_DIFF_EXIT=2 PATH="$healthy_bin:$PATH" run_live_diff "$case_dir/rendered.yaml" "$case_dir/diff.txt" 2> "$err_file" &&
    { echo "self-test 실패: kubectl diff exit 2(오류)를 통과시켰다" >&2; exit 1; }
  grep -q "kubectl diff가 오류로 끝났다(exit 2)" "$err_file" ||
    { echo "self-test 실패: diff 오류 사유가 없다" >&2; cat "$err_file" >&2; exit 1; }

  # 음성: Phase 0 입력 4건 — run 미지정, required 실패가 있는 run, tracking-id가 다른 Application, 필수 파일 누락
  expect_failure "$PHASE0_BLOCKED_EXIT" "APPLY BLOCKED: public-gateway → PHASE0_RUN_DIR가 없다" \
    env PHASE0_RUN_DIR= PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway
  write_manifest 1
  expect_failure "$PHASE0_BLOCKED_EXIT" "required_failures가 0이 아니다" \
    env PHASE0_RUN_DIR="$run_dir" PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-phase0 public-gateway
  write_manifest 0
  write_ingress_objects "public-gateway:gateway.networking.k8s.io/Gateway:persona-app/persona-app"
  expect_failure "$PHASE0_BLOCKED_EXIT" "Gateway tracking-id가 이관 전 기대값이 아니다" \
    env PHASE0_RUN_DIR="$run_dir" PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-phase0 public-gateway
  write_ingress_objects "$GATEWAY_TRACKING_ID_BEFORE"
  rm "$run_dir/phase1_certificate.txt"
  expect_failure "$PHASE0_BLOCKED_EXIT" "필수 Phase 0 조회가 없거나 실패했다: phase1_certificate.txt" \
    env PHASE0_RUN_DIR="$run_dir" PATH="$healthy_bin:$PATH" sh "$repo_dir/scripts/argo-preflight.sh" --check-preconditions public-gateway

  rm -rf "$case_dir"
  echo "self-test 통과: public-gateway 정상 6건·음성 15건"
}

# --- main ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  usage
fi

if [ "$1" = "--self-test" ]; then
  self_test
  exit 0
fi

# self-test가 별도 프로세스에서 선행 조건만 실행해 실제 종료 코드(2 = APPLY BLOCKED)를 확인하는 입구다.
# git fetch·렌더·diff·승인 기록을 하지 않는다.
if [ "$1" = "--check-preconditions" ] && [ $# -eq 2 ]; then
  check_preconditions "$2"
  exit $?
fi

# 클러스터·fetch 없이 작업 트리의 public-gateway 선언과 지정한 Phase 0 run 하나만 검사하는 입구다.
# 머지 전이거나 홈 context가 없는 곳(예: 맥)에서 "실제 run 파싱"까지만 확인할 때 쓴다.
# live 상태·승인 SHA 렌더를 대신하지 않으므로 통과해도 Sync 명령을 출력하거나 승인 기록을 남기지 않는다.
if [ "$1" = "--check-phase0" ] && [ $# -eq 2 ]; then
  if [ "$2" != "public-gateway" ]; then
    echo "--check-phase0는 public-gateway만 지원한다(실제: $2)" >&2
    exit 1
  fi
  require_tools
  offline_render=$(mktemp "${TMPDIR:-/tmp}/argo-preflight-offline.XXXXXX")
  trap 'rm -f "$offline_render"' EXIT HUP INT TERM
  kubectl kustomize "$repo_dir/$PUBLIC_GATEWAY_SOURCE_PATH" > "$offline_render"
  check_public_gateway_declaration "$repo_dir/argocd/public-gateway.yaml" "$offline_render" || exit 1
  echo "선언 확인(작업 트리): argocd/public-gateway.yaml, $PUBLIC_GATEWAY_SOURCE_PATH 렌더 = Gateway 1개"
  check_phase0_inputs_for_gateway "${PHASE0_RUN_DIR:-}" || exit $?
  echo "Phase 0 입력 검사 통과(live 조회 안 함 — Sync 전 홈 context에서 public-gateway 전체 preflight 필요)"
  exit 0
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

if [ "$app" = "public-gateway" ] && ! git -C "$repo_dir" cat-file -e "$sha:argocd/public-gateway.yaml" 2> /dev/null; then
  # 렌더 오류와 섞이지 않게 먼저 알린다. 선언 브랜치가 develop에 머지되기 전에는 여기서 멈춘다.
  echo "선행 조건 실패: public-gateway → 승인 SHA ${sha}에 argocd/public-gateway.yaml이 없다(선언 머지 전)" >&2
  exit 1
fi
render_at_sha "$app" "$sha" > "$diff_file.rendered"
if [ "$app" = "public-gateway" ]; then
  # Sync할 SHA의 Application 선언과 렌더를 검사한다. 작업 트리 파일이 아니라 승인 SHA 기준이다.
  git -C "$repo_dir" show "$sha:argocd/public-gateway.yaml" > "$diff_file.application"
  check_public_gateway_declaration "$diff_file.application" "$diff_file.rendered" || exit 1
fi
# 여기부터 클러스터에 닿는다. context(이름·API server)가 홈 클러스터가 아니면 diff·live 조회를 하지 않는다.
# public-gateway는 Phase 0 입력을 먼저 확인해 그 run이 기록한 API server를 기대값으로 쓴다.
expected_server=""
if [ "$app" = "public-gateway" ]; then
  check_phase0_inputs_for_gateway "${PHASE0_RUN_DIR:-}" || exit $?
  expected_server="$phase0_api_server"
fi
require_expected_context "$expected_server" || exit 1
run_live_diff "$diff_file.rendered" "$diff_file" || exit 1
summarize_diff "$diff_file"
echo "전체 diff: $diff_file"
echo

# 종료 코드를 그대로 전달한다. 1 = 선행 조건 실패, 2 = APPLY BLOCKED(public-gateway의 Phase 0 입력 부족).
precondition_status=0
check_preconditions "$app" || precondition_status=$?
if [ "$precondition_status" -ne 0 ]; then
  exit "$precondition_status"
fi
echo "선행 조건 통과: $app"

print_next_commands "$app" "$sha"
record_approved_sha "$app" "$sha" "선행조건 통과(Sync 전)"
