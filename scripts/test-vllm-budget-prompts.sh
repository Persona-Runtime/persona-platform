#!/usr/bin/env bash
# scripts/measure/vllm_budget_prompts.py 를 mafest checkout 으로 돌려 본문·manifest 가 측정기 입력 검사를
# 그대로 통과하는지 본다. 가짜 Evidence(DB 없음)만 쓰고 vLLM·클러스터에는 닿지 않는다.
#   MAFEST_REPO=<mafest checkout> MAFEST_PYTHON=<mafest 의존성 python> bash scripts/test-vllm-budget-prompts.sh
# MAFEST_REPO 가 없으면 "건너뜀"을 출력하고 0 으로 끝낸다(통과로 쓰지 않는다).
set -eu
if [ -z "${MAFEST_REPO:-}" ] || [ ! -d "${MAFEST_REPO:-}/src/mafest" ]; then
  echo "건너뜀: MAFEST_REPO 가 mafest checkout 이 아니다(본문 생성기 smoke 미실행)"
  exit 0
fi
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/vllm-budget-prompts-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

MAFEST_REPO_ROOT="$MAFEST_REPO" PYTHONPATH="$MAFEST_REPO/src" "${MAFEST_PYTHON:-python3}" \
  "$repo_dir/scripts/measure/vllm_budget_prompts.py" --out-dir "$work/out" --model Qwen/Qwen3-4B-Instruct-2507 \
  --include-experimental > "$work/stdout.txt"

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_dir/scripts/measure" "$work/out" << 'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import vllm_budget

out = sys.argv[2]
rows, manifest, problems = vllm_budget.load_inputs(f"{out}/bodies.jsonl", f"{out}/manifest.json")
assert not problems, problems
kinds = manifest["kinds"]
assert kinds["answer"]["status"] == "active" and kinds["answer"]["max_tokens"] > 0, kinds["answer"]
assert kinds["verify"]["status"] == "no_llm_call"
assert all(kinds[k]["status"] == "not_implemented" for k in ("parse", "summary", "suggest"))
assert manifest["evidence_source"] == "fake"
answers = [r for r in rows if r["kind"] == "answer"]
assert {r["id"] for r in answers} | {s["id"] for s in manifest["skipped"]} == {"MOCK_2", "MOCK_4", "LARGE_LIST"}
for row in answers:
    body = row["body"]
    assert body["max_tokens"] == kinds["answer"]["max_tokens"]
    assert vllm_budget.schema_key(body) == kinds["answer"]["schema"]
experimental = {r["kind"] for r in rows} - {"answer"}
assert experimental and all(kinds[k]["status"] == "experimental" for k in experimental), experimental
print("통과: 본문·manifest 가 측정기 입력 검사를 통과하고, answer 는 실제 구조화 요청·출력 상한을 담는다")
PY
grep -q "evidence_source=fake" "$work/stdout.txt"
