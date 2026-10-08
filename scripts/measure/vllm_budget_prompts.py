"""M3 측정용 요청 본문과 manifest 를 만든다 — 맥에서 mafest checkout 의 Python 환경으로 실행한다.

mafest 의 실제 답변 경로(route → execute_plan → normalize_evidence → system_prompt·user_prompt → build_body)로
요청 본문을 만들고, 출처(mafest SHA·프롬프트 fingerprint·Evidence 출처)를 manifest 에 남긴다. 결과는 사람이
정한 비공개 폴더에만 쓴다(Git 에 올리지 않는다). CP 의 측정기(vllm_budget.py)는 이 두 파일만 읽는다.

  PYTHONPATH=<mafest>/src <mafest-python> vllm_budget_prompts.py --out-dir <비공개 폴더> --model <served id> \\
      [--pg-env <읽기 전용 DSN 환경변수 이름>] [--include-experimental] [--web-repo <mafest-web checkout>]

- answer: 지금 배포되는 유일한 LLM 호출. 공개 예시 MOCK-2·MOCK-4 와 표시 상한(MAX_RECORDS)행을 채우는 대표 큰
  목록 질문 1개를 쓴다. 게이트가 템플릿으로 끝내는 질문은 LLM 을 부르지 않으므로 표본에서 빼고 기록만 한다.
- Evidence: --pg-env 를 주면 그 DSN 으로 실제 러너를 쓴다(권장). 없으면 가짜 커서로 만들고 "fake" 로 표시한다.
  가짜 Evidence 는 실제 행 크기를 대표하지 않는다.
- parse·summary·suggest: mafest 서빙 코드에 아직 없다(not_implemented). --include-experimental 을 주면 커밋된 L1
  실험 요청을 experimental_* 종류로 싣는다(배포 프롬프트가 아니다).
- verify: LLM 호출이 없다(no_llm_call). 요청을 만들지 않는다.

stdout 에는 표본 수·상태만 낸다. 질문·Evidence·본문은 출력하지 않는다.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

from mafest.agent.executor import Runners, execute_plan
from mafest.agent.pg_runner import PostgresViewRunner
from mafest.agent.router import DEFAULT_RULES_YAML_PATH, DEFAULT_TTL_PATHS, route
from mafest.common.paths import repo_root
from mafest.config import Settings
from mafest.infra.db_pool import SingleConnectionPool
from mafest.llm.adapter import normalize_evidence
from mafest.llm.client import DEFAULT_MAX_TOKENS, RESPONSE_SCHEMA, build_body
from mafest.llm.gate import run_gate
from mafest.llm.mock_evidence import FIXTURE_BASE_DATES
from mafest.llm.prompt import (
    MAX_RECORDS,
    PROMPT_VERSION,
    prompt_fingerprint,
    system_prompt,
    user_prompt,
)

#: 공개 예시 질문의 정본 위치(테스트가 정답 조건을 고정한다). 문자열을 여기 다시 적지 않고 읽는다.
PUBLIC_EXAMPLES_FILE = Path("tests/unit/agent/test_public_examples_gate1.py")
PUBLIC_EXAMPLE_NAMES = ("MOCK_2", "MOCK_4")
#: 표시 상한(MAX_RECORDS)행을 채우는 넓은 목록 질문. 국내 ETF 는 행이 많아 상한까지 찬다.
LARGE_LIST_QUESTION = f"순자산 큰 국내 ETF {MAX_RECORDS}개"
L1_REQUEST_DIR = Path("data/eval/llm_l1/requests")
L1_EXPERIMENTAL = {
    "parse": "parse_dev.jsonl",
    "summary": "summary.jsonl",
    "suggest": "suggest.jsonl",
}


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical(obj: object) -> bytes:
    return json.dumps(
        obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=False
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _repo_state(repo: Path) -> dict:
    sha = _git(repo, "rev-parse", "HEAD")
    return {
        "sha": sha or "N/A",
        "dirty": bool(_git(repo, "status", "--porcelain")) if sha else None,
    }


def public_examples(root: Path) -> dict[str, str]:
    """테스트 파일의 모듈 상수에서 공개 예시 질문을 읽는다."""
    tree = ast.parse((root / PUBLIC_EXAMPLES_FILE).read_text(encoding="utf-8"))
    found: dict[str, str] = {}
    for node in tree.body:
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
        ):
            name = node.targets[0].id
            if name in PUBLIC_EXAMPLE_NAMES and isinstance(node.value, ast.Constant):
                found[name] = node.value.value
    missing = set(PUBLIC_EXAMPLE_NAMES) - set(found)
    if missing:
        raise SystemExit(f"공개 예시 질문을 찾지 못했다: {sorted(missing)}")
    return found


class _FakeCursor:
    """실 DB 가 없을 때의 가짜 커서. 빈 목록 조건이면 0행, 그 밖에는 한 행을 돌려준다."""

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def execute(self, _query, params=()):
        self.empty = any(
            isinstance(value, list) and not value for value in (params or ())
        )

    def fetchone(self):
        return {"result": 0.42, 0: "0"}

    def fetchall(self):
        if getattr(self, "empty", False):
            return []
        return [
            {"product_id": "KR7000000001", "product_name": "가짜", "_total_count": 1}
        ]


class _FakeConnection:
    autocommit = True

    def cursor(self, **_kwargs):
        return _FakeCursor()

    def close(self):
        pass


def make_runners(pg_env: str | None) -> tuple[Runners, str]:
    """(러너, evidence_source). DSN 값은 출력하지 않는다."""
    if pg_env is None:
        pg = PostgresViewRunner(
            dsn="fake", pool=SingleConnectionPool(_FakeConnection())
        )
        return Runners(pg=pg, base_dates=FIXTURE_BASE_DATES), "fake"
    dsn = os.environ.get(pg_env)
    if not dsn:
        raise SystemExit(f"환경변수 {pg_env} 가 비어 있다")
    from mafest.agent.entity_runner import EntityLookupRunner
    from mafest.bootstrap import read_base_dates_for_dsn_env

    runners = Runners(
        pg=PostgresViewRunner(dsn),
        entity=EntityLookupRunner(dsn),
        base_dates=read_base_dates_for_dsn_env(pg_env),
    )
    return runners, "db"


def answer_samples(
    questions: dict[str, str], runners: Runners, model: str, settings: Settings
) -> tuple[list[dict], list[dict]]:
    """(LLM 을 부르는 표본, 게이트가 템플릿으로 끝내 빠진 표본)."""
    system = system_prompt()
    samples: list[dict] = []
    skipped: list[dict] = []
    for sample_id, question in questions.items():
        plan = route(sample_id, question, DEFAULT_TTL_PATHS, DEFAULT_RULES_YAML_PATH)
        evidence = normalize_evidence(json.loads(execute_plan(plan, runners).to_json()))
        if run_gate(evidence, question):
            skipped.append({"id": sample_id, "reason": "GATE_TEMPLATE"})
            continue
        body = build_body(
            system,
            user_prompt(evidence, question),
            model=model,
            structured=settings.llm_structured,
            send_thinking_off=settings.llm_send_thinking_off,
        )
        record_count = sum(len(d.records) for d in evidence.domains)
        samples.append(
            {"kind": "answer", "id": sample_id, "body": body, "records": record_count}
        )
    return samples, skipped


def experimental_samples(root: Path, model: str) -> tuple[list[dict], dict]:
    """커밋된 L1 실험 요청(배포 프롬프트 아님)과 그 출처."""
    manifest_path = root / L1_REQUEST_DIR / "request_manifest.json"
    source = (
        json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest_path.exists()
        else {}
    )
    samples: list[dict] = []
    for kind, filename in L1_EXPERIMENTAL.items():
        path = root / L1_REQUEST_DIR / filename
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            body = dict(row["body"])
            body["model"] = model
            body.pop("stream", None)
            samples.append(
                {"kind": f"experimental_{kind}", "id": str(row.get("id")), "body": body}
            )
    provenance = {
        "request_manifest_sha256": _sha256(manifest_path.read_bytes())
        if manifest_path.exists()
        else "N/A",
        "work_head": source.get("work_head", "N/A"),
        "main_sha": source.get("main_sha", "N/A"),
        "prompt_sha256": source.get("prompt_sha256", {}),
    }
    return samples, provenance


def schema_key(body: dict) -> str | None:
    """구조화 출력 종류: json_schema 면 이름, json_object 면 그 이름, 없으면 None."""
    response_format = body.get("response_format") or {}
    if response_format.get("type") == "json_schema":
        return "json_schema:" + str(
            (response_format.get("json_schema") or {}).get("name")
        )
    if response_format.get("type") == "json_object":
        return "json_object"
    return None


def kind_table(
    samples: list[dict], include_experimental: bool, provenance: dict | None
) -> dict:
    kinds: dict[str, dict] = {
        "answer": {
            "status": "active",
            "max_tokens": DEFAULT_MAX_TOKENS,
            "schema": "json_schema:mafest_answer",
            "schema_sha256": _sha256(_canonical(RESPONSE_SCHEMA)),
        },
        "parse": {"status": "not_implemented"},
        "summary": {"status": "not_implemented"},
        "suggest": {"status": "not_implemented"},
        "verify": {"status": "no_llm_call"},
    }
    if include_experimental:
        for kind in L1_EXPERIMENTAL:
            rows = [s for s in samples if s["kind"] == f"experimental_{kind}"]
            if rows:
                first = rows[0]["body"]
                kinds[f"experimental_{kind}"] = {
                    "status": "experimental",
                    "max_tokens": first.get("max_tokens"),
                    "schema": schema_key(first),
                    "source": provenance,
                }
    return kinds


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument(
        "--model",
        required=True,
        help="vLLM served model id(/v1/models 의 id 와 같아야 한다)",
    )
    parser.add_argument(
        "--pg-env", help="읽기 전용 DSN 이 든 환경변수 이름(값은 출력하지 않는다)"
    )
    parser.add_argument("--include-experimental", action="store_true")
    parser.add_argument("--web-repo", type=Path)
    args = parser.parse_args(argv)

    root = Path(os.environ.get("MAFEST_REPO_ROOT") or repo_root())
    settings = Settings.from_env(os.environ)
    runners, evidence_source = make_runners(args.pg_env)
    questions = public_examples(root)
    questions["LARGE_LIST"] = LARGE_LIST_QUESTION
    samples, skipped = answer_samples(questions, runners, args.model, settings)
    provenance = None
    if args.include_experimental:
        experimental, provenance = experimental_samples(root, args.model)
        samples.extend(experimental)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(args.out_dir, 0o700)
    bodies_path = args.out_dir / "bodies.jsonl"
    lines = [
        json.dumps(
            {"kind": s["kind"], "id": s["id"], "body": s["body"]}, ensure_ascii=False
        )
        for s in samples
    ]
    bodies_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    manifest = {
        "format": 1,
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "mafest": _repo_state(root),
        "web_fixture": _repo_state(args.web_repo)
        if args.web_repo
        else {"sha": "N/A", "dirty": None},
        "prompt": prompt_fingerprint(),
        "settings": {
            "llm_structured": settings.llm_structured,
            "llm_send_thinking_off": settings.llm_send_thinking_off,
            "max_prompt_records": MAX_RECORDS,
            "llm_timeout_s": settings.llm_timeout_s,
        },
        "evidence_source": evidence_source,
        "model": args.model,
        "kinds": kind_table(samples, args.include_experimental, provenance),
        "samples": [
            {
                "id": s["id"],
                "kind": s["kind"],
                "body_sha256": _sha256(_canonical(s["body"])),
                **({"records": s["records"]} if "records" in s else {}),
            }
            for s in samples
        ],
        "skipped": skipped,
        "bodies_sha256": _sha256(bodies_path.read_bytes()),
    }
    (args.out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    counts = {
        kind: sum(1 for s in samples if s["kind"] == kind)
        for kind in dict.fromkeys(s["kind"] for s in samples)
    }
    print(
        f"evidence_source={evidence_source} samples={counts} skipped={len(skipped)} prompt_version={PROMPT_VERSION}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
