"""M3 측정용 요청 본문 생성기 — mafest checkout의 Python 환경에서 실행한다(vllm_budget.sh가 부른다).

mafest 코드가 실제로 보내는 모양 그대로 Chat Completions 본문을 만들어 JSONL로 쓴다. 본문은 화면에 내지 않는다.
  - answer: system_prompt() + user_prompt(ev, question) → client.build_body(). Evidence는 오프라인 mock 전부와,
            각 mock의 레코드를 프롬프트 상한(MAX_RECORDS)까지 늘린 최대 크기 표본이다(DB 없이 상한을 본다).
  - parse·summary·suggest(L1): data/eval/llm_l1/requests/*.jsonl에 커밋된 본문 그대로.
  - verify: LLM을 부르지 않는다(검증은 코드만) — 표본 없음.

usage: python vllm_budget_prompts.py <out.jsonl> <served-model-name>
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

from mafest.common.paths import data_path
from mafest.llm.adapter import normalize_evidence
from mafest.llm.client import DEFAULT_MAX_TOKENS, build_body
from mafest.llm.mock_evidence import MOCKS, mock
from mafest.llm.prompt import MAX_RECORDS, system_prompt, user_prompt

# mock마다 그 Evidence가 답하는 질문 꼴. 프롬프트 길이에는 질문 한 줄만 보탠다.
QUESTION = "조건에 맞는 상품을 비교해서 알려줘"
L1_FILES = {"parse": "parse_dev.jsonl", "summary": "summary.jsonl", "suggest": "suggest.jsonl"}


def widened(raw: dict) -> dict:
    """레코드가 있는 도메인을 MAX_RECORDS개까지 복제한 Evidence(프롬프트 최대 크기 표본)."""
    out = copy.deepcopy(raw)
    for domain in out.get("domain_results", []):
        records = domain.get("records") or []
        if not records:
            continue
        grown = []
        for i in range(MAX_RECORDS):
            record = copy.deepcopy(records[i % len(records)])
            record["ref_id"] = f"E{i + 1}"
            grown.append(record)
        domain["records"] = grown
    return out


def main() -> int:
    out_path, model = Path(sys.argv[1]), sys.argv[2]
    rows: list[dict] = []
    system = system_prompt()
    for name in sorted(MOCKS):
        raw = mock(name)
        for label, sample in ((name, raw), (f"{name}@max{MAX_RECORDS}", widened(raw))):
            body = build_body(system, user_prompt(normalize_evidence(sample), QUESTION), model=model)
            rows.append({"kind": "answer", "id": label, "messages": body["messages"],
                         "max_tokens": body.get("max_tokens", DEFAULT_MAX_TOKENS),
                         "chat_template_kwargs": body.get("chat_template_kwargs")})
    for kind, filename in L1_FILES.items():
        path = data_path("eval", "llm_l1", "requests", filename)
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
            if not line.strip():
                continue
            body = json.loads(line)["body"]
            rows.append({"kind": kind, "id": f"{kind}#{index + 1}", "messages": body["messages"],
                         "max_tokens": body.get("max_tokens"),
                         "chat_template_kwargs": body.get("chat_template_kwargs")})
    with out_path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"요청 본문 {len(rows)}개 생성(본문은 출력하지 않음)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
