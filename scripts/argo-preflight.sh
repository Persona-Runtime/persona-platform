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
#                                        # cert-manager-issuers 중 하나
#   scripts/argo-preflight.sh --self-test

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
  ruby -ryaml -e '
    app = YAML.load_file(ARGV[0])
    path = app.dig("spec", "source", "path")
    abort "source.path가 없다 — 이 스크립트는 단일 source(kustomize path) Application만 지원한다" if path.nil?
    puts path
  ' "$repo_dir/argocd/$1.yaml"
}

app_namespace() {
  ruby -ryaml -e '
    app = YAML.load_file(ARGV[0])
    puts app.dig("spec", "destination", "namespace")
  ' "$repo_dir/argocd/$1.yaml"
}

# metallb·cert-manager는 spec.source(단수)가 아니라 spec.sources(복수, Helm 차트 + 이
# 저장소의 값 파일 source)를 쓴다 — kustomize path가 아예 없다. 아래 app_helm_* 함수들이
# 그 차트 source에서 render_at_sha가 helm template에 필요한 값을 뽑는다.
app_is_multi_source() {
  ruby -ryaml -e '
    app = YAML.load_file(ARGV[0])
    puts app.dig("spec", "sources").nil? ? "false" : "true"
  ' "$repo_dir/argocd/$1.yaml"
}

app_helm_chart_source() {
  # 인자로 받은 필드(field) 하나만 출력한다 — sources 배열에서 "chart" 키를 가진
  # 항목(Helm 차트 source, 값 파일만 가리키는 source와 구분)을 찾아 그 필드를 읽는다.
  ruby -ryaml -e '
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
  ruby -ryaml -e '
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
# 손대지 않는다 — check_preconditions 함수 하나만 직접 부른다.
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
  rm -f /tmp/argo-preflight-selftest.err
  echo "self-test 통과: 선행 조건 실패 시 exit 1과 사유 메시지를 확인했다"
}

# --- main ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  usage
fi

if [ "$1" = "--self-test" ]; then
  self_test
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

render_at_sha "$app" "$sha" > "$diff_file.rendered"
# kubectl diff는 클러스터 접속이 필요하다 — 실패해도(exit 1은 "차이 있음"을 뜻하므로
# 정상, exit >1이면 접속 실패) 스크립트를 죽이지 않고 결과를 그대로 기록한다.
kubectl diff -f "$diff_file.rendered" > "$diff_file" 2>&1 || true
summarize_diff "$diff_file"
echo "전체 diff: $diff_file"
echo

if ! check_preconditions "$app"; then
  exit 1
fi
echo "선행 조건 통과: $app"

print_next_commands "$app" "$sha"
record_approved_sha "$app" "$sha" "선행조건 통과(Sync 전)"
