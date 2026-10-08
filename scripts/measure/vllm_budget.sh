#!/usr/bin/env bash
# M3 vLLM 토큰 예산·구조화 출력 측정 — 읽기 전용. 사람이 CP 에서 실행한다.
#
# 1) kubectl get 으로 persona-inference vLLM 의 live 상태를 읽는다: GPU 노드 Ready, Pod 1/1 Ready 하나.
#    허용 목록 인자·image digest·모델 revision·restart·마지막 종료 사유는 측정하는 Pod 에서 읽는다
#    (Deployment 템플릿이 아니다). 준비가 안 됐으면 4.
# 2) 맥에서 vllm_budget_prompts.py 로 만든 본문(VLLM_BUDGET_BODIES)과 manifest(VLLM_BUDGET_MANIFEST)를 읽어
#    vllm_budget.py 로 /v1/models·/tokenize·실제 구조화 생성(최대 3건, 순차)을 확인한다.
# 3) 끝난 뒤 Pod 를 다시 읽어 전후를 비교한다. 다시 읽지 못함·Pod 교체(UID)·Ready 상실·restart·OOM 증가는
#    성공으로 보지 않고 6 으로 끝낸다. 최종 종료 코드·stdout 의 FINAL_STATE 줄·결과 JSON 의 상태는 항상 같다.
#
# 이 스크립트는 port-forward 를 열지 않는다(get·top·config view 만 보내는 읽기 전용 경계). 터널은 사람이 연다:
#   kubectl -n persona-inference port-forward svc/persona-vllm 18002:8000   # 다른 터미널
#
# 환경변수
#   VLLM_BASE_URL          vLLM 주소(사람이 연 터널). 필수
#   VLLM_BUDGET_BODIES     맥에서 만든 bodies.jsonl. 필수
#   VLLM_BUDGET_MANIFEST   맥에서 만든 manifest.json. 필수
#   VLLM_BUDGET_RESULT     결과 JSON 을 쓸 비공개 경로(선택). 측정을 시작하면 이 경로에 최종 상태가 쓰인다
#   VLLM_BUDGET_APPROVED_MAFEST_SHA  사람이 승인한 mafest SHA. M3 완료 판정에는 manifest 가 evidence_source=db,
#                          깨끗한 작업 트리, 이 SHA 와 같은 mafest SHA 를 가져야 한다. 아니면 진단용(5)
#   VLLM_API_KEY           서버가 --api-key 를 쓰면 준다. 값은 출력하지 않는다
#   VLLM_BUDGET_PROM_URL   Prometheus 터널(선택). 주면 생성 요청 동안 DCGM GPU 메모리를 관측한다
#   VLLM_BUDGET_GENERATE_EXPERIMENTAL=1  실험용 종류도 생성한다(전체 3건 상한 안)
#   VLLM_BUDGET_CONTEXT    kubectl context. 기본 kubernetes-admin@kubernetes
#   VLLM_BUDGET_KUBECTL    kubectl 실행 파일(테스트용). 기본 kubectl
#
# 종료 코드: 0 PASS(범위 한정 포함), 1 한도 초과, 2 실행 불가, 3 응답 실패, 4 GPU 노드·vLLM 준비 안 됨,
#           5 부분 확인·진단용(가짜 Evidence 포함), 6 중단(측정 뒤 Pod 확인 실패·교체·Ready 상실·restart·OOM 증가)
set -u
set -o pipefail
umask 077

CONTEXT="${VLLM_BUDGET_CONTEXT-kubernetes-admin@kubernetes}"
KUBECTL="${VLLM_BUDGET_KUBECTL-kubectl}"
NAMESPACE=persona-inference
SELECTOR=app.kubernetes.io/name=persona-vllm
GPU_NODE=persona-gpu-01
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_RESULT="${VLLM_BUDGET_RESULT-}"

# 이전 실행의 결과가 남아 최종 상태로 오해되지 않게 먼저 지운다.
[ -z "$USER_RESULT" ] || rm -f "$USER_RESULT"

early_exit() {  # 상태 사유 종료코드: 측정 전에 끝나는 경우의 최종 줄
  echo "FINAL_STATE=$1 REASONS=$2 EXIT=$3"
  exit "$3"
}
cannot_run() { early_exit CANNOT_RUN "$*" 2; }
k() { "$KUBECTL" --context="$CONTEXT" --request-timeout=20s "$@"; }

command -v python3 > /dev/null 2>&1 || cannot_run NO_PYTHON3
command -v "$KUBECTL" > /dev/null 2>&1 || cannot_run NO_KUBECTL
[ -n "${VLLM_BASE_URL:-}" ] || cannot_run NO_VLLM_BASE_URL
[ -s "${VLLM_BUDGET_BODIES:-}" ] || cannot_run NO_BODIES
[ -s "${VLLM_BUDGET_MANIFEST:-}" ] || cannot_run NO_MANIFEST
current_context=$("$KUBECTL" config current-context 2> /dev/null || true)
[ "$current_context" = "$CONTEXT" ] || cannot_run WRONG_CONTEXT

work=$(mktemp -d "${TMPDIR:-/tmp}/vllm-budget.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
PY="$SCRIPT_DIR/vllm_budget.py"

# --- 1) live 상태 --------------------------------------------------------------------
gpu_ready=$(k get node "$GPU_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
k -n "$NAMESPACE" get pods -l "$SELECTOR" -o json > "$work/pods_before.json" 2> /dev/null || cannot_run POD_READ_FAILED
read -r pods_ready pods_total <<< "$(python3 "$PY" --pod-state "$work/pods_before.json" 2> /dev/null || echo "0 0")"
if [ "$gpu_ready" != "True" ] || [ "$pods_total" != "1" ] || [ "$pods_ready" != "1" ]; then
  early_exit NOT_READY "GPU_NODE_READY:${gpu_ready:-none},PODS_READY:${pods_ready}/${pods_total}" 4
fi
python3 "$PY" --live "$work/pods_before.json" > "$work/live.json" 2> /dev/null || cannot_run LIVE_PARSE_FAILED
echo "live: $(cat "$work/live.json")"
top_before=$(k -n "$NAMESPACE" top pod -l "$SELECTOR" --no-headers 2> /dev/null | awk '{print "cpu="$2" mem="$3}' || true)
echo "자원(요청 전): ${top_before:-N/A}"

# --- 2) 측정 --------------------------------------------------------------------------
status=0
VLLM_BUDGET_RESULT="$work/result.json" python3 "$PY" "$work/live.json" "$VLLM_BUDGET_BODIES" "$VLLM_BUDGET_MANIFEST" || status=$?

# --- 3) 측정 뒤 Pod 확인과 최종 상태 ----------------------------------------------------------
top_after=$(k -n "$NAMESPACE" top pod -l "$SELECTOR" --no-headers 2> /dev/null | awk '{print "cpu="$2" mem="$3}' || true)
echo "자원(요청 후): ${top_after:-N/A}"
after_file="$work/pods_after.json"
k -n "$NAMESPACE" get pods -l "$SELECTOR" -o json > "$after_file" 2> /dev/null || after_file="-"
final=0
python3 "$PY" --finalize "$work/result.json" "$status" "$work/pods_before.json" "$after_file" ${USER_RESULT:+"$USER_RESULT"} || final=$?
exit "$final"
