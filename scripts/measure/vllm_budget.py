"""M3 vLLM 토큰 예산 확인(읽기 전용, 표준 라이브러리만) — vllm_budget.sh가 부른다.

입력
  - live 인자 JSON(vllm_budget.sh가 kubectl get으로 읽은 허용 목록 값)
  - 요청 본문 JSONL(vllm_budget_prompts.py가 mafest 코드로 만든 실제 요청 모양)
  - VLLM_BASE_URL(사람이 연 port-forward·SSH 터널), 필요하면 VLLM_API_KEY(값은 출력하지 않는다)

하는 일
  1) GET /v1/models — 서빙 모델 이름·max_model_len
  2) POST /tokenize — 모델 토크나이저로 각 요청의 입력 토큰 수(chat template 포함)를 센다
  3) 종류별 최대 입력 + max_tokens 가 max_model_len 안인지 표로 낸다
  4) structured output(json_schema) 요청 1회 — 응답이 스키마대로 파싱되는지만 본다

출력에는 프롬프트·응답 본문·토큰 목록을 넣지 않는다. 숫자와 판정만 낸다.
종료 코드: 0 모두 예산 안, 1 초과 있음, 2 설정 오류, 3 vLLM 응답 실패
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict

TIMEOUT_S = 30
KIND_ORDER = ("answer", "parse", "summary", "suggest")
STRUCTURED_SCHEMA = {
    "type": "object",
    "properties": {"ok": {"type": "boolean"}},
    "required": ["ok"],
    "additionalProperties": False,
}


class VllmError(RuntimeError):
    """vLLM 응답 실패(연결·HTTP·형식). 본문은 담지 않는다."""


def call(base_url: str, path: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(base_url.rstrip("/") + path, data=data, method="POST" if data else "GET")
    request.add_header("Content-Type", "application/json")
    api_key = os.environ.get("VLLM_API_KEY")
    if api_key:
        request.add_header("Authorization", f"Bearer {api_key}")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise VllmError(f"{path} HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise VllmError(f"{path} 연결 실패({type(e).__name__})") from None
    except json.JSONDecodeError:
        raise VllmError(f"{path} 응답이 JSON이 아니다") from None


def count_tokens(base_url: str, model: str, row: dict) -> int:
    payload = {"model": model, "messages": row["messages"], "add_generation_prompt": True}
    if row.get("chat_template_kwargs"):
        payload["chat_template_kwargs"] = row["chat_template_kwargs"]
    result = call(base_url, "/tokenize", payload)
    count = result.get("count")
    if not isinstance(count, int):
        raise VllmError("/tokenize 응답에 count가 없다")
    return count


def structured_probe(base_url: str, model: str) -> str:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": "Reply with JSON: ok=true."}],
        "max_tokens": 32,
        "temperature": 0,
        "response_format": {"type": "json_schema", "json_schema": {"name": "m3_probe", "schema": STRUCTURED_SCHEMA}},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    try:
        result = call(base_url, "/v1/chat/completions", body)
        content = result["choices"][0]["message"]["content"]
        parsed = json.loads(content)
    except VllmError as e:
        return f"실패({e})"
    except (KeyError, IndexError, TypeError, json.JSONDecodeError):
        return "실패(응답이 스키마대로 파싱되지 않음)"
    if isinstance(parsed, dict) and isinstance(parsed.get("ok"), bool) and set(parsed) == {"ok"}:
        return "지원(스키마대로 파싱됨)"
    return "실패(스키마와 다른 JSON)"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: vllm_budget.py <live_args.json> <bodies.jsonl>", file=sys.stderr)
        return 2
    base_url = os.environ.get("VLLM_BASE_URL", "")
    if not base_url:
        print("설정 오류: VLLM_BASE_URL이 없다 — port-forward나 SSH 터널을 연 뒤 주소를 준다", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        live = json.load(f)
    with open(sys.argv[2], encoding="utf-8") as f:
        rows = [json.loads(line) for line in f if line.strip()]
    if not rows:
        print("설정 오류: 요청 본문이 0개다", file=sys.stderr)
        return 2

    try:
        models = call(base_url, "/v1/models").get("data") or []
    except VllmError as e:
        print(f"vLLM 응답 실패: {e}", file=sys.stderr)
        return 3
    if not models:
        print("vLLM 응답 실패: /v1/models에 모델이 없다", file=sys.stderr)
        return 3
    model = models[0].get("id")
    served_len = models[0].get("max_model_len")
    live_len = live.get("--max-model-len")
    print(f"모델: {model} · max_model_len(/v1/models)={served_len} · live 인자 --max-model-len={live_len or '없음'}")
    if live.get("--served-model-name") and live["--served-model-name"] != model:
        print(f"주의: live --served-model-name({live['--served-model-name']})과 /v1/models 모델이 다르다")
    budget = served_len if isinstance(served_len, int) else (int(live_len) if live_len else None)
    if budget is None:
        print("vLLM 응답 실패: max_model_len을 알 수 없다", file=sys.stderr)
        return 3
    if live_len and served_len and int(live_len) != served_len:
        print(f"주의: live 인자({live_len})와 서빙 값({served_len})이 다르다 — 서빙 값으로 판정한다")

    per_kind: dict[str, list[tuple[int, int]]] = defaultdict(list)
    try:
        for row in rows:
            per_kind[row["kind"]].append((count_tokens(base_url, model, row), int(row.get("max_tokens") or 0)))
    except VllmError as e:
        print(f"vLLM 응답 실패: {e}", file=sys.stderr)
        return 3

    over = False
    print()
    print("| 종류 | 표본 | 최대 입력 토큰 | max_tokens | 합(최악) | max_model_len | 판정 |")
    print("|---|---|---|---|---|---|---|")
    for kind in [*KIND_ORDER, *sorted(set(per_kind) - set(KIND_ORDER))]:
        samples = per_kind.get(kind)
        if not samples:
            continue
        worst = max(samples, key=lambda s: s[0] + s[1])
        total = worst[0] + worst[1]
        fits = total <= budget
        over |= not fits
        print(f"| {kind} | {len(samples)} | {max(s[0] for s in samples)} | {worst[1]} | {total} | {budget} | {'예산 안' if fits else '초과'} |")
    print("| verify | 0 | — | — | — | — | LLM 호출 없음(코드 검증) |")
    print()
    print(f"structured output(json_schema) 1회: {structured_probe(base_url, model)}")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
