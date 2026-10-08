#!/usr/bin/env bash
# M3(문서 35) vLLM 토큰 예산 측정 — 읽기 전용. 사람이 실행한다.
#
# 1) kubectl get으로 persona-inference의 vLLM live 상태·인자(허용 목록만)와 GPU 노드 상태를 읽는다.
#    GPU 노드가 꺼져 있거나 vLLM이 Ready가 아니면 그 사실만 출력하고 4로 끝낸다.
# 2) mafest checkout의 Python 환경으로 실제 요청 본문(answer·L1 parse/summary/suggest)을 만든다(파일로만, 출력 안 함).
# 3) 사람이 연 port-forward·SSH 터널(VLLM_BASE_URL)로 /v1/models·/tokenize·structured 1회를 호출해 표로 낸다.
#
# 이 스크립트는 port-forward를 직접 열지 않는다(get·config view만 보내는 읽기 전용 경계). 예:
#   kubectl -n persona-inference port-forward svc/persona-vllm 18002:8000   # 다른 터미널, 사람이 연다
#   MAFEST_REPO=~/mafest MAFEST_PYTHON=~/mafest/.venv/bin/python VLLM_BASE_URL=http://127.0.0.1:18002 \
#     bash scripts/measure/vllm_budget.sh
#
# 환경변수
#   MAFEST_REPO           mafest checkout(프롬프트 정본). 필수(VLLM_BUDGET_BODIES를 줄 때는 생략 가능)
#   MAFEST_PYTHON         mafest 의존성이 설치된 python. 기본 python3
#   VLLM_BASE_URL         vLLM 주소(사람이 연 터널). 필수
#   VLLM_API_KEY          서버가 --api-key를 쓰면 준다. 값은 출력하지 않는다
#   VLLM_BUDGET_CONTEXT   kubectl context. 기본 kubernetes-admin@kubernetes
#   VLLM_BUDGET_KUBECTL   kubectl 실행 파일(테스트용). 기본 kubectl
#   VLLM_BUDGET_BODIES    미리 만든 본문 JSONL(테스트용). 주면 2)를 건너뛴다
#
# 종료 코드: 0 예산 안, 1 초과 있음, 2 설정 오류, 3 vLLM 응답 실패, 4 GPU 노드·vLLM 꺼짐
set -u
set -o pipefail
umask 077

CONTEXT="${VLLM_BUDGET_CONTEXT-kubernetes-admin@kubernetes}"
KUBECTL="${VLLM_BUDGET_KUBECTL-kubectl}"
MAFEST_PYTHON="${MAFEST_PYTHON-python3}"
NAMESPACE=persona-inference
DEPLOYMENT=persona-vllm
GPU_NODE=persona-gpu-01
# 출력·판정에 쓰는 인자만 고른다. --api-key는 있는지 여부만 기록한다(값을 버린다).
ALLOWED_ARGS="--max-model-len --served-model-name --gpu-memory-utilization --max-num-seqs --max-num-batched-tokens"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

config_error() { echo "설정 오류: $*" >&2; exit 2; }
k() { "$KUBECTL" --context="$CONTEXT" --request-timeout=20s "$@"; }

command -v python3 > /dev/null 2>&1 || config_error "python3가 없다"
command -v "$KUBECTL" > /dev/null 2>&1 || config_error "kubectl이 없다"
[ -n "${VLLM_BASE_URL:-}" ] || config_error "VLLM_BASE_URL이 없다 — port-forward나 SSH 터널을 연 뒤 주소를 준다"
current_context=$("$KUBECTL" config current-context 2> /dev/null || true)
[ "$current_context" = "$CONTEXT" ] || config_error "현재 context(${current_context:-없음})가 ${CONTEXT}가 아니다"

work=$(mktemp -d "${TMPDIR:-/tmp}/vllm-budget.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# --- 1) live 상태 --------------------------------------------------------------------
gpu_ready=$(k get node "$GPU_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
ready=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2> /dev/null || true)
replicas=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2> /dev/null || true)
if [ "$gpu_ready" != "True" ] || [ "${replicas:-0}" = "0" ] || [ "${ready:-0}" = "0" ]; then
  echo "GPU 노드·vLLM이 꺼져 있다: ${GPU_NODE} Ready=${gpu_ready:-없음}, ${DEPLOYMENT} replicas=${replicas:-없음} ready=${ready:-0} — 측정하지 않는다"
  exit 4
fi
raw_args=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="vllm")].args}' 2> /dev/null) || config_error "vLLM 인자를 읽지 못했다"
printf '%s' "$raw_args" | ALLOWED_ARGS="$ALLOWED_ARGS" python3 -c '
import json, os, sys
allowed = os.environ["ALLOWED_ARGS"].split()
args = json.loads(sys.stdin.read() or "[]")
out = {}
for i, arg in enumerate(args):
    key, _, inline = arg.partition("=")
    if key == "--api-key":
        out["--api-key"] = "present"
    elif key in allowed:
        out[key] = inline or (args[i + 1] if i + 1 < len(args) else "")
json.dump(out, sys.stdout)
' > "$work/live_args.json" || config_error "vLLM 인자 해석 실패"
echo "live 인자(허용 목록): $(cat "$work/live_args.json")"

# --- 2) 요청 본문 ---------------------------------------------------------------------
bodies="${VLLM_BUDGET_BODIES-}"
if [ -z "$bodies" ]; then
  [ -n "${MAFEST_REPO:-}" ] && [ -d "${MAFEST_REPO:-}/src/mafest" ] || config_error "MAFEST_REPO가 mafest checkout이 아니다"
  served=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("--served-model-name",""))' "$work/live_args.json")
  bodies="$work/bodies.jsonl"
  MAFEST_REPO_ROOT="$MAFEST_REPO" PYTHONPATH="$MAFEST_REPO/src" \
    "$MAFEST_PYTHON" "$SCRIPT_DIR/vllm_budget_prompts.py" "$bodies" "${served:-model}" || config_error "요청 본문 생성 실패(MAFEST_PYTHON 의존성 확인)"
fi
[ -s "$bodies" ] || config_error "요청 본문 파일이 비었다: $bodies"

# --- 3) 측정 --------------------------------------------------------------------------
python3 "$SCRIPT_DIR/vllm_budget.py" "$work/live_args.json" "$bodies"
