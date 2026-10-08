#!/usr/bin/env bash
# M3 vLLM 토큰 예산·구조화 출력 측정 — 읽기 전용. 사람이 CP 에서 실행한다.
#
# 1) kubectl get 으로 persona-inference vLLM 의 live 상태를 읽는다: GPU 노드 Ready, Pod 1/1 Ready 하나,
#    허용 목록 인자, image digest, 모델 경로 revision, restart·마지막 종료 사유. 준비가 안 됐으면 4.
# 2) 맥에서 vllm_budget_prompts.py 로 만든 본문(VLLM_BUDGET_BODIES)과 manifest(VLLM_BUDGET_MANIFEST)를 읽어
#    vllm_budget.py 로 /v1/models·/tokenize·실제 구조화 생성(최대 3건, 순차)을 확인한다.
# 3) 끝난 뒤 restart·OOM 을 다시 읽어 늘었으면 6 으로 끝낸다.
#
# 이 스크립트는 port-forward 를 열지 않는다(get·top·config view 만 보내는 읽기 전용 경계). 터널은 사람이 연다:
#   kubectl -n persona-inference port-forward svc/persona-vllm 18002:8000   # 다른 터미널
#
# 환경변수
#   VLLM_BASE_URL          vLLM 주소(사람이 연 터널). 필수
#   VLLM_BUDGET_BODIES     맥에서 만든 bodies.jsonl. 필수
#   VLLM_BUDGET_MANIFEST   맥에서 만든 manifest.json. 필수
#   VLLM_BUDGET_RESULT     결과 JSON 을 쓸 비공개 경로(선택). 없으면 표준 출력만
#   VLLM_API_KEY           서버가 --api-key 를 쓰면 준다. 값은 출력하지 않는다
#   VLLM_BUDGET_PROM_URL   Prometheus 터널(선택). 주면 생성 요청 동안 DCGM GPU 메모리를 관측한다
#   VLLM_BUDGET_GENERATE_EXPERIMENTAL=1  실험용 종류도 생성한다(전체 3건 상한 안)
#   VLLM_BUDGET_CONTEXT    kubectl context. 기본 kubernetes-admin@kubernetes
#   VLLM_BUDGET_KUBECTL    kubectl 실행 파일(테스트용). 기본 kubectl
#
# 종료 코드: 0 PASS(범위 한정 포함), 1 한도 초과, 2 실행 불가, 3 응답 실패, 4 GPU 노드·vLLM 준비 안 됨,
#           5 부분 확인, 6 측정 중 restart·OOM 증가(중단)
set -u
set -o pipefail
umask 077

CONTEXT="${VLLM_BUDGET_CONTEXT-kubernetes-admin@kubernetes}"
KUBECTL="${VLLM_BUDGET_KUBECTL-kubectl}"
NAMESPACE=persona-inference
DEPLOYMENT=persona-vllm
SELECTOR=app.kubernetes.io/name=persona-vllm
GPU_NODE=persona-gpu-01
# 출력·판정에 쓰는 인자만 고른다. --api-key 는 있는지 여부만 기록한다(값을 버린다).
ALLOWED_ARGS="--max-model-len --served-model-name --gpu-memory-utilization --max-num-seqs --max-num-batched-tokens"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cannot_run() { echo "STATE=CANNOT_RUN REASONS=$*"; exit 2; }
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

# Pod 상태 요약: "준비된 수 전체 수 restart 합 마지막 종료 사유들". 본문·env 는 읽지 않는다.
pod_state() {
  k -n "$NAMESPACE" get pods -l "$SELECTOR" -o json 2> /dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items", [])
ready = restarts = 0
reasons = []
for pod in items:
    for status in pod.get("status", {}).get("containerStatuses", []):
        if status.get("name") != "vllm":
            continue
        ready += 1 if status.get("ready") else 0
        restarts += int(status.get("restartCount", 0))
        reason = (status.get("lastState", {}).get("terminated") or {}).get("reason")
        if reason:
            reasons.append(reason)
print(ready, len(items), restarts, ",".join(sorted(reasons)) or "-")
'
}

# --- 1) live 상태 --------------------------------------------------------------------
gpu_ready=$(k get node "$GPU_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
read -r pods_ready pods_total restarts_before reasons_before <<< "$(pod_state || echo "0 0 0 -")"
if [ "$gpu_ready" != "True" ] || [ "$pods_total" != "1" ] || [ "$pods_ready" != "1" ]; then
  echo "STATE=NOT_READY REASONS=GPU_NODE_READY:${gpu_ready:-none},PODS_READY:${pods_ready}/${pods_total} — 측정하지 않는다"
  exit 4
fi

k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json > "$work/deployment.json" 2> /dev/null || cannot_run DEPLOYMENT_READ_FAILED
k -n "$NAMESPACE" get pods -l "$SELECTOR" -o json > "$work/pods.json" 2> /dev/null || cannot_run POD_READ_FAILED
ALLOWED_ARGS="$ALLOWED_ARGS" python3 - "$work/deployment.json" "$work/pods.json" "$restarts_before" "$reasons_before" > "$work/live.json" << 'PY' || cannot_run LIVE_PARSE_FAILED
import json, os, re, sys
deployment = json.load(open(sys.argv[1]))
pods = json.load(open(sys.argv[2])).get("items", [])
container = next(c for c in deployment["spec"]["template"]["spec"]["containers"] if c["name"] == "vllm")
allowed = os.environ["ALLOWED_ARGS"].split()
args = container.get("args", [])
picked = {}
for i, arg in enumerate(args):
    key, _, inline = arg.partition("=")
    if key == "--api-key":
        picked["--api-key"] = "present"
    elif key in allowed:
        picked[key] = inline or (args[i + 1] if i + 1 < len(args) else "")
# 모델 경로(/models/<org>/<name>/<revision>)의 revision 만 남긴다.
revision = None
for part in container.get("command", []) + args:
    match = re.fullmatch(r"/models/[^/]+/[^/]+/([0-9a-f]{7,64})", part)
    if match:
        revision = match.group(1)
image_ids = sorted({s.get("imageID", "") for p in pods for s in p.get("status", {}).get("containerStatuses", []) if s.get("name") == "vllm"})
digest = next((i.split("@", 1)[1] for i in image_ids if "@" in i), None)
json.dump({"args": picked, "image_id": digest, "model_revision": revision,
           "restarts_before": int(sys.argv[3]), "terminated_reasons_before": sys.argv[4]}, sys.stdout)
PY
echo "live: $(cat "$work/live.json")"
top_before=$(k -n "$NAMESPACE" top pod -l "$SELECTOR" --no-headers 2> /dev/null | awk '{print "cpu="$2" mem="$3}' || true)
echo "자원(요청 전): ${top_before:-N/A}"

# --- 2) 측정 --------------------------------------------------------------------------
status=0
python3 "$SCRIPT_DIR/vllm_budget.py" "$work/live.json" "$VLLM_BUDGET_BODIES" "$VLLM_BUDGET_MANIFEST" || status=$?

# --- 3) 측정 뒤 restart·OOM ---------------------------------------------------------------
top_after=$(k -n "$NAMESPACE" top pod -l "$SELECTOR" --no-headers 2> /dev/null | awk '{print "cpu="$2" mem="$3}' || true)
echo "자원(요청 후): ${top_after:-N/A}"
read -r _ready_after _total_after restarts_after reasons_after <<< "$(pod_state || echo "0 0 ${restarts_before} ${reasons_before}")"
echo "restart ${restarts_before} → ${restarts_after} · 마지막 종료 사유 ${reasons_before} → ${reasons_after}"
if [ "$restarts_after" -gt "$restarts_before" ] || { [ "$reasons_after" != "$reasons_before" ] && [[ "$reasons_after" == *OOMKilled* ]]; }; then
  echo "STATE=HALT REASONS=RESTART_OR_OOM_DURING_MEASUREMENT"
  exit 6
fi
exit "$status"
