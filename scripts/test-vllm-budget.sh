#!/usr/bin/env bash
# scripts/measure/vllm_budget.sh 를 가짜 kubectl 과 로컬 가짜 vLLM(127.0.0.1, python http.server)으로 돌린다.
# 클러스터·실제 vLLM 에 닿지 않는다. 확인하는 것:
#   정상(→ 0, 범위 한정 PASS), 예산 경계(합 == 한도 → 0, 한도 - 1 → 1), 구조화 실패 4종(→ 3),
#   max_tokens 누락(→ 5, 0 으로 계산하지 않음), 모델·한도 불일치와 manifest 불일치(→ 2), GPU 꺼짐(→ 4),
#   측정 중 restart 증가(→ 6), 출력에 프롬프트·응답 본문·API 키·토큰 목록이 없음, kubectl 쓰기 명령 없음
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
MODEL="Qwen/Qwen3-4B-Instruct-2507"

# 합성 본문·manifest. answer(활성, json_schema) 2개와 실험용 parse 1개. drop 을 주면 answer 하나의
# max_tokens 를 뺀다. 출력: answer 최악 표본의 입력+출력 합(가짜 토크나이저 기준).
make_inputs() {
  python3 - "$work" "$SECRET_PROMPT" "$MODEL" "${1:-}" << 'PY'
import hashlib, json, sys
work, secret, model, drop = sys.argv[1:5]
schema = {"type": "object", "properties": {"answer_template": {"type": "string"}},
          "required": ["answer_template"], "additionalProperties": False}
def body(content, max_tokens, response_format):
    b = {"model": model, "messages": [{"role": "system", "content": "x" * 400 + secret}, {"role": "user", "content": content}],
         "max_tokens": max_tokens, "chat_template_kwargs": {"enable_thinking": False}}
    if response_format:
        b["response_format"] = response_format
    return b
answer_format = {"type": "json_schema", "json_schema": {"name": "mafest_answer", "schema": schema}}
rows = [
    {"kind": "answer", "id": "MOCK_2", "body": body("y" * 200, 1024, answer_format)},
    {"kind": "answer", "id": "LARGE_LIST", "body": body("y" * 800, 1024, answer_format)},
    {"kind": "experimental_parse", "id": "p1", "body": body("z" * 100, 384, {"type": "json_object"})},
]
if drop:
    del rows[0]["body"]["max_tokens"]
canonical = lambda o: json.dumps(o, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
raw = ("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n").encode()
open(f"{work}/bodies.jsonl", "wb").write(raw)
manifest = {
    "format": 1, "model": model, "evidence_source": "fake",
    "mafest": {"sha": "test"}, "prompt": {"prompt_version": "test", "prompt_system_sha256": "0" * 64},
    "kinds": {"answer": {"status": "active", "max_tokens": 1024, "schema": "json_schema:mafest_answer"},
              "parse": {"status": "not_implemented"}, "verify": {"status": "no_llm_call"},
              "experimental_parse": {"status": "experimental", "max_tokens": 384, "schema": "json_object"}},
    "samples": [{"id": r["id"], "kind": r["kind"], "body_sha256": hashlib.sha256(canonical(r["body"])).hexdigest()} for r in rows],
    "bodies_sha256": hashlib.sha256(raw).hexdigest(),
}
json.dump(manifest, open(f"{work}/manifest.json", "w"))
worst = max(rows[:2], key=lambda r: len(r["body"]["messages"][0]["content"]) + len(r["body"]["messages"][1]["content"]))
print(sum(len(m["content"]) for m in worst["body"]["messages"]) // 4 + 1024)
PY
}

# 가짜 vLLM: 토큰 수 = 메시지 글자 수 / 4. max_model_len 과 생성 응답 방식은 상태 파일에서 읽는다.
cat > "$work/server.py" << 'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
state_dir, secret_reply = sys.argv[1], sys.argv[2]
read = lambda name: open(f"{state_dir}/{name}").read().strip()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/v1/models":
            return self._send(200, {"data": [{"id": "Qwen/Qwen3-4B-Instruct-2507", "max_model_len": int(read("served_len"))}]})
        self._send(404, {})
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/tokenize":
            if read("tokenize") == "broken":
                return self._send(500, {"error": secret_reply})
            n = sum(len(m["content"]) for m in payload["messages"]) // 4
            return self._send(200, {"count": n, "tokens": list(range(n))})
        if self.path == "/v1/chat/completions":
            mode = read("chat")
            if mode == "http500":
                return self._send(500, {"error": secret_reply})
            content = {"ok": json.dumps({"answer_template": secret_reply}),
                       "badjson": "{not json " + secret_reply,
                       "schema": json.dumps({"wrong": secret_reply}),
                       "length": json.dumps({"answer_template": secret_reply})}[mode]
            finish = "length" if mode == "length" else "stop"
            return self._send(200, {"choices": [{"message": {"content": content}, "finish_reason": finish}],
                                    "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
        self._send(404, {})
server = HTTPServer(("127.0.0.1", 0), H)
open(f"{state_dir}/port", "w").write(str(server.server_address[1]))
server.serve_forever()
PY
set_state() { echo "$2" > "$work/$1"; }
set_state served_len 4096; set_state tokenize ok; set_state chat ok; set_state restarts 0
python3 "$work/server.py" "$work" "$SECRET_REPLY" &
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { echo "가짜 vLLM 이 뜨지 않았다" >&2; exit 1; }
base_url="http://127.0.0.1:$(cat "$work/port")"

mkdir "$work/bin"
cat > "$work/bin/kubectl" << 'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
restarts=$(cat "$FAKE_STATE/restarts")
# 측정 뒤 restart 가 늘어나는 사례: 세 번째 Pod 조회부터 1 을 더한다(앞 두 번은 측정 전 조회).
if [ "${FAKE_RESTART_BUMP:-}" = 1 ] && [[ "$*" == *"get pods"* ]]; then
  n=$(( $(cat "$FAKE_STATE/pod_calls" 2> /dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_STATE/pod_calls"
  [ "$n" -ge 3 ] && restarts=$((restarts + 1))
fi
case "$*" in
  *"config current-context"*) echo kubernetes-admin@kubernetes ;;
  *"get node persona-gpu-01"*) echo "${FAKE_GPU_READY:-True}" ;;
  *"get pods"*) printf '{"items":[{"status":{"containerStatuses":[{"name":"vllm","ready":true,"restartCount":%s,"imageID":"docker.io/vllm/vllm-openai@sha256:abc","lastState":{}}]}}]}' "$restarts" ;;
  *"get deployment persona-vllm -o json"*) printf '{"spec":{"template":{"spec":{"containers":[{"name":"vllm","command":["vllm","serve","/models/Qwen/Qwen3-4B-Instruct-2507/cdbee75f17c01a7cc42f958dc650907174af0554"],"args":["--served-model-name","Qwen/Qwen3-4B-Instruct-2507","--max-model-len","%s","--api-key=%s","--port","8000"]}]}}}}' "$FAKE_LIVE_LEN" "$FAKE_KEY" ;;
  *"top pod"*) echo "persona-vllm-0 120m 9000Mi" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$work/bin/kubectl"

run() {  # 기대 종료 코드, 추가 환경...
  local expected="$1"; shift
  : > "$work/calls.log"; rm -f "$work/pod_calls"
  local status=0
  env FAKE_CALLS="$work/calls.log" FAKE_STATE="$work" FAKE_KEY="$SECRET_KEY" FAKE_LIVE_LEN="$(cat "$work/served_len")" \
    VLLM_BUDGET_KUBECTL="$work/bin/kubectl" VLLM_BUDGET_BODIES="$work/bodies.jsonl" \
    VLLM_BUDGET_MANIFEST="$work/manifest.json" VLLM_API_KEY="$SECRET_KEY" "$@" \
    bash "$repo_dir/scripts/measure/vllm_budget.sh" > "$work/out.txt" 2>&1 || status=$?
  if [ "$status" -ne "$expected" ]; then
    echo "테스트 실패: 기대 exit ${expected}, 실제 ${status}" >&2; cat "$work/out.txt" >&2; exit 1
  fi
  for secret in "$SECRET_PROMPT" "$SECRET_REPLY" "$SECRET_KEY" "0, 1, 2, 3"; do
    if grep -qF "$secret" "$work/out.txt"; then echo "테스트 실패: 출력에 본문·키·토큰 목록이 있다" >&2; exit 1; fi
  done
  if grep -E "(^| )(apply|delete|patch|exec|port-forward|scale|edit|rollout)( |$)" "$work/calls.log" > /dev/null; then
    echo "테스트 실패: kubectl 변경·exec·port-forward 호출이 있다" >&2; exit 1
  fi
}
expect() { grep -qF "$1" "$work/out.txt" || { echo "테스트 실패: 출력에 '$1' 이 없다" >&2; cat "$work/out.txt" >&2; exit 1; }; }

total=$(make_inputs)

run 0 VLLM_BASE_URL="$base_url"
expect "STATE=PASS_SCOPED"
expect '"--api-key": "present"'
expect "result=OK"
expect "image sha256:abc"
echo "통과: 정상 → exit 0(범위 한정 PASS), 본문·키 미출력"

set_state served_len "$total"
run 0 VLLM_BASE_URL="$base_url"
expect "| answer | LARGE_LIST |"
set_state served_len "$((total - 1))"
run 1 VLLM_BASE_URL="$base_url"
expect "STATE=OVER"
set_state served_len 4096
echo "통과: 예산 경계(합 == 한도 → 0, 한도 - 1 → 1)"

for mode in http500 badjson schema length; do
  set_state chat "$mode"
  run 3 VLLM_BASE_URL="$base_url"
  expect "STATE=RESPONSE_FAIL"
done
set_state chat ok
echo "통과: 구조화 실패 4종(HTTP 500·JSON 깨짐·schema 불일치·finish_reason=length) → exit 3"

make_inputs drop > /dev/null
run 5 VLLM_BASE_URL="$base_url"
expect "| answer | MOCK_2 |"
expect "UNKNOWN_MAX_TOKENS"
expect "STATE=PARTIAL"
make_inputs > /dev/null
echo "통과: max_tokens 누락 → exit 5(0 으로 계산하지 않음)"

run 2 VLLM_BASE_URL="$base_url" FAKE_LIVE_LEN=8192
expect "LIVE_MAX_MODEL_LEN_MISMATCH"
printf '\n' >> "$work/bodies.jsonl"
run 2 VLLM_BASE_URL="$base_url"
expect "BODIES_SHA256_MISMATCH"
make_inputs > /dev/null
echo "통과: live 한도 불일치·manifest 불일치 → exit 2"

run 4 VLLM_BASE_URL="$base_url" FAKE_GPU_READY=False
expect "STATE=NOT_READY"
echo "통과: GPU 꺼짐 → exit 4"

run 2
expect "NO_VLLM_BASE_URL"
echo "통과: VLLM_BASE_URL 없음 → exit 2"

set_state tokenize broken
run 3 VLLM_BASE_URL="$base_url"
set_state tokenize ok
echo "통과: /tokenize 실패 → exit 3"

run 6 VLLM_BASE_URL="$base_url" FAKE_RESTART_BUMP=1
expect "STATE=HALT"
echo "통과: 측정 중 restart 증가 → exit 6"

echo "vLLM 예산 측정 테스트 통과"
