#!/bin/sh

set -eu

# Sync 통제(2026-09-19) — Argo Application을 Sync하기 전에 사람이 눌러야 하는 확인들을
# 기계적으로 강제한다. 이 스크립트는 읽기만 한다: kubectl get/diff, git fetch/worktree
# (읽기 전용 조회). kubectl apply·argocd app sync는 이 스크립트 안에서 절대 실행하지 않는다
# — 마지막에 사람이 실행할 명령을 "출력"만 한다.
#
# 사용법:
#   scripts/argo-preflight.sh <app>     # persona-app, persona-app-ingress, persona-app-netpol,
#                                        # persona-db, persona-db-netpol, persona-edge 중 하나
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
  source_path=$(app_source_path "$app")
  worktree_dir=$(mktemp -d "${TMPDIR:-/tmp}/argo-preflight-XXXXXX")
  trap 'git -C "'"$repo_dir"'" worktree remove --force "'"$worktree_dir"'" > /dev/null 2>&1 || true' EXIT HUP INT TERM
  git -C "$repo_dir" worktree add --detach --quiet "$worktree_dir" "$sha"
  kubectl kustomize "$worktree_dir/$source_path"
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
          echo "선행 조건 실패: persona-edge → Secret $secret이 없다" >&2
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
  echo
  echo "실행할 명령:"
  if command -v argocd > /dev/null 2>&1; then
    echo "  argocd app sync $app --revision $sha"
  else
    echo "  (argocd CLI 없음) Argo UI → Applications → $app → Sync → Revision에 $sha 입력"
  fi
  echo
  echo "롤백 명령:"
  if [ -n "$previous_sha" ]; then
    if command -v argocd > /dev/null 2>&1; then
      echo "  argocd app sync $app --revision $previous_sha"
    else
      echo "  (argocd CLI 없음) Argo UI → Applications → $app → Sync → Revision에 $previous_sha 입력"
    fi
  else
    echo "  $app의 직전 성공 기록이 deploy/approved-sync.md에 없다 — 수동으로 확인 후 이전 revision을 지정한다"
  fi
}

# --- self-test -----------------------------------------------------------------
# 가짜 kubectl로 "선행 조건 실패 → exit 1"만 재현한다. 실제 클러스터·git 동작은
# 손대지 않는다 — check_preconditions 함수 하나만 직접 부른다.
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
