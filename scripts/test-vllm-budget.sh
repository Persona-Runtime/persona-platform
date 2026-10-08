#!/usr/bin/env bash
# scripts/measure/vllm_budget.sh를 가짜 kubectl과 로컬 가짜 vLLM(127.0.0.1, python http.server)으로 돌린다.
# 클러스터·실제 vLLM에 닿지 않는다. 확인하는 것:
#   정상(예산 안 → 0), 초과(→ 1), GPU 꺼짐(→ 4), VLLM_BASE_URL 없음(→ 2), vLLM 응답 실패(→ 3),
#   출력에 프롬프트·응답 본문·API 키·토큰 목록이 없음, live 인자는 허용 목록만(--api-key 값 미기록)
set -eu
command -v python3 > /dev/null 2>&1 || { echo "필요한 도구가 없습니다: python3" >&2; exit 1; }
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/vllm-budget-test.XXXXXX")
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2> /dev/null || true; rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

SECRET_PROMPT="SECRET-PROMPT-BODY-합성"
SECRET_REPLY="SECRET-REPLY-BODY"
SECRET_KEY="sk-synthetic-key-should-not-print"

# 합성 요청 본문: answer 1개(긴 것), parse 1개.
python3 - "$work/bodies.jsonl" "$SECRET_PROMPT" << 'PY'
import json, sys
out, secret = sys.argv[1], sys.argv[2]
rows = [
    {"kind": "answer", "id": "a1", "messages": [{"role": "system", "content": "x" * 400 + secret}, {"role": "user", "content": "y" * 200}], "max_tokens": 1024},
    {"kind": "parse", "id": "p1", "messages": [{"role": "user", "content": "z" * 100 + secret}], "max_tokens": 384},
]
with open(out, "w") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

# 가짜 vLLM: 토큰 수 = 메시지 글자 수 / 4. max_model_len은 FAKE_MAX_LEN 파일에서 읽는다.
cat > "$work/server.py" << 'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
state_dir = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def _max_len(self):
        return int(open(f"{state_dir}/max_len").read())
    def do_GET(self):
        if self.path == "/v1/models":
            return self._send(200, {"data": [{"id": "Qwen/Qwen3-4B-Instruct-2507", "max_model_len": self._max_len()}]})
        self._send(404, {})
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if open(f"{state_dir}/mode").read().strip() == "broken":
            return self._send(500, {"error": "synthetic"})
        if self.path == "/tokenize":
            n = sum(len(m["content"]) for m in payload["messages"]) // 4
            return self._send(200, {"count": n, "max_model_len": self._max_len(), "tokens": list(range(n))})
        if self.path == "/v1/chat/completions":
            return self._send(200, {"choices": [{"message": {"content": json.dumps({"ok": True})}, "finish_reason": "stop"}], "note": sys.argv[2]})
        self._send(404, {})
server = HTTPServer(("127.0.0.1", 0), H)
open(f"{state_dir}/port", "w").write(str(server.server_address[1]))
server.serve_forever()
PY
echo 4096 > "$work/max_len"; echo ok > "$work/mode"
python3 "$work/server.py" "$work" "$SECRET_REPLY" &
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { echo "가짜 vLLM이 뜨지 않았다" >&2; exit 1; }
base_url="http://127.0.0.1:$(cat "$work/port")"

mkdir "$work/bin"
cat > "$work/bin/kubectl" << 'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
case "$*" in
  *"config current-context"*) echo kubernetes-admin@kubernetes ;;
  *"get node persona-gpu-01"*) echo "${FAKE_GPU_READY:-True}" ;;
  *"readyReplicas"*) echo "${FAKE_READY:-1}" ;;
  *".spec.replicas"*) echo 1 ;;
  *"containers[?(@.name"*) printf '["--model","/models/x","--served-model-name","Qwen/Qwen3-4B-Instruct-2507","--max-model-len","4096","--api-key=%s","--port","8000"]' "$FAKE_KEY" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$work/bin/kubectl"

run() {  # 기대 종료 코드, 추가 환경...
  local expected="$1"; shift
  : > "$work/calls.log"
  local status=0
  env FAKE_CALLS="$work/calls.log" FAKE_KEY="$SECRET_KEY" VLLM_BUDGET_KUBECTL="$work/bin/kubectl" \
    VLLM_BUDGET_BODIES="$work/bodies.jsonl" VLLM_API_KEY="$SECRET_KEY" "$@" \
    bash "$repo_dir/scripts/measure/vllm_budget.sh" > "$work/out.txt" 2>&1 || status=$?
  if [ "$status" -ne "$expected" ]; then
    echo "테스트 실패: 기대 exit ${expected}, 실제 ${status}" >&2; cat "$work/out.txt" >&2; exit 1
  fi
  for secret in "$SECRET_PROMPT" "$SECRET_REPLY" "$SECRET_KEY" "0, 1, 2, 3"; do
    if grep -qF "$secret" "$work/out.txt"; then echo "테스트 실패: 출력에 본문·키·토큰 목록이 있다" >&2; exit 1; fi
  done
  if grep -E "(^| )(apply|delete|patch|exec|port-forward|scale)( |$)" "$work/calls.log" > /dev/null; then
    echo "테스트 실패: kubectl 변경·exec·port-forward 호출이 있다" >&2; exit 1
  fi
}

run 0 VLLM_BASE_URL="$base_url"
grep -q "| answer | 1 |" "$work/out.txt" || { echo "테스트 실패: 표에 answer가 없다" >&2; cat "$work/out.txt"; exit 1; }
grep -q "예산 안" "$work/out.txt" && grep -q "지원(스키마대로 파싱됨)" "$work/out.txt" || { echo "테스트 실패: 정상 판정이 없다" >&2; exit 1; }
grep -q '"--api-key": "present"' "$work/out.txt" || { echo "테스트 실패: --api-key 존재만 기록해야 한다" >&2; exit 1; }
echo "통과: 정상 → exit 0, 본문·키 미출력"

echo 1100 > "$work/max_len"
run 1 VLLM_BASE_URL="$base_url"
grep -q "초과" "$work/out.txt" || { echo "테스트 실패: 초과 판정이 없다" >&2; exit 1; }
echo 4096 > "$work/max_len"
echo "통과: 예산 초과 → exit 1"

run 4 VLLM_BASE_URL="$base_url" FAKE_GPU_READY=False
grep -q "꺼져 있다" "$work/out.txt" || { echo "테스트 실패: GPU 꺼짐 안내가 없다" >&2; exit 1; }
echo "통과: GPU 꺼짐 → exit 4"

run 2
echo "통과: VLLM_BASE_URL 없음 → exit 2"

echo broken > "$work/mode"
run 3 VLLM_BASE_URL="$base_url"
echo "통과: vLLM 응답 실패 → exit 3"

echo "vLLM 예산 측정 테스트 5건 통과"
