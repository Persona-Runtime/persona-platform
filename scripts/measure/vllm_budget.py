"""M3 vLLM 토큰 예산·구조화 출력 확인(읽기 전용, 표준 라이브러리만) — vllm_budget.sh 가 부른다.

입력
  - live 정보 JSON: vllm_budget.sh 가 kubectl get 으로 읽은 허용 목록 인자·image digest·모델 revision·Pod 상태
  - 요청 본문 JSONL 과 manifest JSON: 맥에서 vllm_budget_prompts.py 가 mafest 실제 경로로 만든 것
  - VLLM_BASE_URL(사람이 연 터널), 필요하면 VLLM_API_KEY(값은 출력하지 않는다)
  - VLLM_BUDGET_PROM_URL(선택): 사람이 연 Prometheus 터널. 주면 생성 요청 동안 DCGM GPU 메모리를 관측한다
  - VLLM_BUDGET_GENERATE_EXPERIMENTAL=1(선택): 실험용 종류도 생성 요청을 보낸다(전체 3건 상한 안에서)

하는 일
  1) manifest 와 본문이 맞는지 본다(파일 sha256·표본 목록). 어긋나면 실행 불가
  2) GET /v1/models 의 모델 id·max_model_len 이 live 인자와 같은지 본다. 다르면 실행 불가
  3) 표본마다 POST /tokenize 로 입력 토큰(chat template 포함)을 재고, 그 표본의 max_tokens 와 더해 한도와 비교한다
  4) 활성 종류의 서로 다른 구조화 schema 마다 합이 가장 큰 표본 1건을 실제 본문 그대로 생성한다(순차, 재시도 없음)

출력에는 프롬프트·응답 본문·토큰 목록·자격증명을 넣지 않는다. 숫자·표본 id·고정 사유 코드만 낸다.
  - VLLM_BUDGET_APPROVED_MAFEST_SHA: 사람이 승인한 mafest SHA. M3 완료 판정에는 manifest 가 evidence_source=db,
    깨끗한 작업 트리, 이 SHA 와 같은 mafest SHA 를 가져야 한다. 아니면 진단용(5)이다

종료 코드: 0 PASS(범위 한정 포함), 1 한도 초과, 2 실행 불가, 3 응답 실패, 5 부분 확인·진단용
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT_S = 30
#: 생성 요청의 HTTP 대기 상한. 앱의 생성 시한(20초)보다 넉넉히 두고, 지연은 따로 잰다.
GENERATION_TIMEOUT_S = 120
GENERATION_LIMIT_S = 20.0
MAX_GENERATIONS = 3
PROM_INTERVAL_S = 1.0
#: GPU 노드가 하나라 전체 최댓값을 읽는다. 다른 질의가 필요하면 VLLM_BUDGET_DCGM_QUERY 로 바꾼다.
DEFAULT_DCGM_QUERY = "max(DCGM_FI_DEV_FB_USED)"

EXIT_PASS, EXIT_OVER, EXIT_CANNOT_RUN, EXIT_RESPONSE_FAIL, EXIT_PARTIAL = 0, 1, 2, 3, 5


class VllmError(RuntimeError):
    """vLLM 응답 실패(연결·HTTP·형식). 본문은 담지 않는다. code 는 고정 사유 코드다."""

    def __init__(self, code: str, status: int | None = None):
        super().__init__(code)
        self.code = code
        self.status = status


def _request(url: str, payload: dict | None, timeout: float, key: str | None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    request.add_header("Content-Type", "application/json")
    if key:
        request.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as e:
        raise VllmError("HTTP_ERROR", e.code) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise VllmError("CONNECTION_FAILED") from None
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise VllmError("RESPONSE_NOT_JSON") from None


def call(
    base_url: str, path: str, payload: dict | None = None, timeout: float = TIMEOUT_S
) -> dict:
    return _request(
        base_url.rstrip("/") + path, payload, timeout, os.environ.get("VLLM_API_KEY")
    )


# ── 입력 검사 ─────────────────────────────────────────────────────────────────


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical(obj: object) -> bytes:
    return json.dumps(
        obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def load_inputs(
    bodies_path: str, manifest_path: str
) -> tuple[list[dict], dict, list[str]]:
    """(표본, manifest, 어긋난 사유 코드). 사유가 있으면 실행 불가다."""
    with open(bodies_path, "rb") as f:
        raw = f.read()
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    rows = [
        json.loads(line) for line in raw.decode("utf-8").splitlines() if line.strip()
    ]
    problems: list[str] = []
    if manifest.get("bodies_sha256") != _sha256(raw):
        problems.append("BODIES_SHA256_MISMATCH")
    listed = {
        (s.get("id"), s.get("kind")): s.get("body_sha256")
        for s in manifest.get("samples", [])
    }
    actual = {
        (r.get("id"), r.get("kind")): _sha256(_canonical(r.get("body"))) for r in rows
    }
    if listed != actual:
        problems.append("SAMPLE_LIST_MISMATCH")
    kinds = manifest.get("kinds") or {}
    if any(r.get("kind") not in kinds for r in rows):
        problems.append("UNDECLARED_KIND")
    if not rows:
        problems.append("NO_SAMPLES")
    return rows, manifest, problems


def positive_int(value: object) -> int | None:
    return (
        value
        if isinstance(value, int) and not isinstance(value, bool) and value > 0
        else None
    )


# ── 구조화 출력 검사 ──────────────────────────────────────────────────────────

_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


def schema_problem(value: object, schema: dict) -> str | None:
    """요청 schema 의 type·required·properties·additionalProperties·enum·items 만 본다. 어긋나면 고정 사유 코드."""
    expected = schema.get("type")
    if expected is not None:
        types = expected if isinstance(expected, list) else [expected]
        allowed = tuple(t for name in types for t in (_TYPES.get(name, object),))
        if isinstance(value, bool) and "boolean" not in types:
            return "SCHEMA_TYPE"
        if not isinstance(value, allowed):
            return "SCHEMA_TYPE"
    if "enum" in schema and value not in schema["enum"]:
        return "SCHEMA_ENUM"
    if isinstance(value, dict):
        properties = schema.get("properties") or {}
        if any(key not in value for key in schema.get("required", [])):
            return "SCHEMA_REQUIRED"
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            return "SCHEMA_ADDITIONAL"
        for key, sub in properties.items():
            if key in value:
                problem = schema_problem(value[key], sub)
                if problem:
                    return problem
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for item in value:
            problem = schema_problem(item, schema["items"])
            if problem:
                return problem
    return None


def schema_key(body: dict) -> str | None:
    response_format = body.get("response_format") or {}
    if response_format.get("type") == "json_schema":
        return "json_schema:" + str(
            (response_format.get("json_schema") or {}).get("name")
        )
    if response_format.get("type") == "json_object":
        return "json_object"
    return None


def check_content(body: dict, content: object) -> str | None:
    """응답 본문이 요청의 구조화 형식을 지키는지. 지키면 None."""
    if not isinstance(content, str) or not content.strip():
        return "EMPTY_CONTENT"
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        return "CONTENT_NOT_JSON"
    response_format = body.get("response_format") or {}
    if response_format.get("type") == "json_object":
        return None if isinstance(parsed, dict) else "SCHEMA_TYPE"
    schema = (response_format.get("json_schema") or {}).get("schema")
    return schema_problem(parsed, schema) if isinstance(schema, dict) else None


# ── GPU 메모리 관측(선택) ──────────────────────────────────────────────────────


class GpuObserver:
    """사람이 연 Prometheus 터널로 DCGM GPU 메모리(MiB)를 생성 요청 동안만 짧은 주기로 읽는다."""

    def __init__(self, prom_url: str | None):
        self.prom_url = prom_url
        self.values: list[float] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def read(self) -> float | None:
        if not self.prom_url:
            return None
        query = os.environ.get("VLLM_BUDGET_DCGM_QUERY") or DEFAULT_DCGM_QUERY
        url = (
            self.prom_url.rstrip("/")
            + "/api/v1/query?"
            + urllib.parse.urlencode({"query": query})
        )
        try:
            result = _request(url, None, 5, None).get("data", {}).get("result") or []
            return float(result[0]["value"][1]) if result else None
        except (VllmError, KeyError, IndexError, TypeError, ValueError):
            return None

    def __enter__(self):
        self.values = []
        self._stop = threading.Event()
        if self.prom_url:
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        return self

    def _run(self) -> None:
        while not self._stop.is_set():
            value = self.read()
            if value is not None:
                self.values.append(value)
            self._stop.wait(PROM_INTERVAL_S)

    def __exit__(self, *_exc):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=10)
        return False


# ── 측정 ──────────────────────────────────────────────────────────────────────


def check_target(
    base_url: str, live: dict, manifest: dict
) -> tuple[str, int, list[str]]:
    """(서빙 모델 id, max_model_len, 실행 불가 사유). /v1/models 실패는 VllmError."""
    models = call(base_url, "/v1/models").get("data") or []
    if not models:
        raise VllmError("NO_MODEL")
    model = models[0].get("id")
    served_len = positive_int(models[0].get("max_model_len"))
    args = live.get("args") or {}
    problems: list[str] = []
    if served_len is None:
        problems.append("MAX_MODEL_LEN_UNKNOWN")
    live_len = args.get("--max-model-len")
    if live_len is None or not str(live_len).isdigit() or int(live_len) != served_len:
        problems.append("LIVE_MAX_MODEL_LEN_MISMATCH")
    if args.get("--served-model-name") != model:
        problems.append("LIVE_MODEL_NAME_MISMATCH")
    if manifest.get("model") != model:
        problems.append("MANIFEST_MODEL_MISMATCH")
    return model, served_len or 0, problems


def measure_tokens(
    base_url: str, model: str, rows: list[dict], budget: int
) -> list[dict]:
    measured = []
    for row in rows:
        body = row["body"]
        payload = {
            "model": model,
            "messages": body.get("messages"),
            "add_generation_prompt": True,
        }
        if body.get("chat_template_kwargs"):
            payload["chat_template_kwargs"] = body["chat_template_kwargs"]
        count = call(base_url, "/tokenize", payload).get("count")
        if positive_int(count) is None:
            raise VllmError("TOKENIZE_NO_COUNT")
        max_tokens = positive_int(body.get("max_tokens"))
        total = count + max_tokens if max_tokens else None
        measured.append(
            {
                "id": row["id"],
                "kind": row["kind"],
                "input_tokens": count,
                "max_tokens": max_tokens,
                "total": total,
                "headroom": budget - total if total is not None else None,
                "verdict": "UNKNOWN_MAX_TOKENS"
                if total is None
                else ("FITS" if total <= budget else "OVER"),
            }
        )
    return measured


def generate(base_url: str, row: dict, observer: GpuObserver) -> dict:
    body = {key: value for key, value in row["body"].items() if key != "stream"}
    started = time.monotonic()
    result: dict = {"id": row["id"], "kind": row["kind"], "schema": schema_key(body)}
    with observer:
        try:
            response = call(
                base_url, "/v1/chat/completions", body, timeout=GENERATION_TIMEOUT_S
            )
            result["http"] = 200
        except VllmError as e:
            response = None
            result["http"] = e.status
            result["problem"] = e.code
    result["latency_s"] = round(time.monotonic() - started, 3)
    result["over_generation_limit"] = result["latency_s"] > GENERATION_LIMIT_S
    if observer.values:
        result["gpu_fb_used_mib_observed_max"] = max(observer.values)
    if response is None:
        return result
    try:
        choice = response["choices"][0]
        content = choice["message"]["content"]
        result["finish_reason"] = choice.get("finish_reason")
    except (KeyError, IndexError, TypeError):
        result["problem"] = "NO_CHOICE"
        return result
    usage = response.get("usage") or {}
    result["usage"] = {
        k: usage.get(k) for k in ("prompt_tokens", "completion_tokens", "total_tokens")
    }
    if result["finish_reason"] == "length":
        result["problem"] = "FINISH_LENGTH"
    else:
        problem = check_content(body, content)
        if problem:
            result["problem"] = problem
    return result


def pick_generation_targets(
    rows: list[dict], measured: list[dict], kinds: dict, include_experimental: bool
) -> tuple[list[dict], list[str]]:
    """활성(선택 시 실험용) 종류의 서로 다른 schema 마다 합이 가장 큰 표본 1건. (대상, 상한에 걸려 못 보낸 schema)."""
    by_id = {(r["id"], r["kind"]): r for r in rows}
    best: dict[str, tuple[int, dict]] = {}
    for m in measured:
        status = (kinds.get(m["kind"]) or {}).get("status")
        if status != "active" and not (
            include_experimental and status == "experimental"
        ):
            continue
        row = by_id[(m["id"], m["kind"])]
        key = schema_key(row["body"])
        if key is None or m["total"] is None:
            continue
        if key not in best or m["total"] > best[key][0]:
            best[key] = (m["total"], row)
    ordered = sorted(
        best.items(),
        key=lambda item: (kinds[item[1][1]["kind"]].get("status") != "active", item[0]),
    )
    targets = [row for _key, (_total, row) in ordered[:MAX_GENERATIONS]]
    skipped = [key for key, _ in ordered[MAX_GENERATIONS:]]
    return targets, skipped


def provenance_problems(manifest: dict, approved_sha: str | None) -> list[str]:
    """M3 완료로 쓸 수 있는 입력 출처인지. 가짜 Evidence·미승인 SHA·더러운 작업 트리는 진단용이다."""
    problems: list[str] = []
    if manifest.get("evidence_source") != "db":
        problems.append("EVIDENCE_NOT_DB")
    mafest = manifest.get("mafest") or {}
    if mafest.get("dirty") is not False:
        problems.append("MAFEST_TREE_NOT_CLEAN")
    if not approved_sha:
        problems.append("APPROVED_SHA_NOT_GIVEN")
    elif mafest.get("sha") != approved_sha:
        problems.append("MAFEST_SHA_NOT_APPROVED")
    return problems


def decide(
    measured: list[dict],
    generations: list[dict],
    kinds: dict,
    skipped_schemas: list[str],
    provenance: list[str] | None = None,
) -> tuple[int, str, list[str]]:
    """(종료 코드, 상태, 사유 코드). 활성 종류가 모두 확인되지 않거나 입력 출처가 진단용이면 PASS 로 만들지 않는다.

    한도 초과와 응답 실패는 입력 출처와 무관한 사실이라 먼저 판정한다. 출처 문제는 PARTIAL(5)이고,
    가짜 Evidence 면 상태를 DIAGNOSTIC 으로 구분한다."""
    reasons: list[str] = []
    if any(m["verdict"] == "OVER" for m in measured):
        return EXIT_OVER, "OVER", ["INPUT_PLUS_MAX_TOKENS_OVER_LIMIT"]
    failed = [g for g in generations if g.get("problem")]
    if failed:
        return (
            EXIT_RESPONSE_FAIL,
            "RESPONSE_FAIL",
            sorted({g["problem"] for g in failed}),
        )
    active = [k for k, v in kinds.items() if v.get("status") == "active"]
    for kind in active:
        rows = [m for m in measured if m["kind"] == kind]
        if not rows:
            reasons.append(f"NO_SAMPLE:{kind}")
        elif any(m["verdict"] == "UNKNOWN_MAX_TOKENS" for m in rows):
            reasons.append(f"UNKNOWN_MAX_TOKENS:{kind}")
        elif kinds[kind].get("schema") and not any(
            g["kind"] == kind for g in generations
        ):
            reasons.append(f"NOT_GENERATED:{kind}")
    if any(m["verdict"] == "UNKNOWN_MAX_TOKENS" for m in measured):
        reasons.append("UNKNOWN_MAX_TOKENS")
    reasons.extend(f"GENERATION_CAP:{key}" for key in skipped_schemas)
    reasons.extend(provenance or [])
    if reasons:
        state = "DIAGNOSTIC" if "EVIDENCE_NOT_DB" in reasons else "PARTIAL"
        return EXIT_PARTIAL, state, sorted(set(reasons))
    if not active:
        return EXIT_PARTIAL, "PARTIAL", ["NO_ACTIVE_KIND"]
    scoped = sorted(
        k
        for k, v in kinds.items()
        if v.get("status") in {"experimental", "not_implemented"}
    )
    if scoped:
        return EXIT_PASS, "PASS_SCOPED", [f"NOT_ACTIVE:{k}" for k in scoped]
    return EXIT_PASS, "PASS", []


def print_report(
    model: str,
    budget: int,
    live: dict,
    manifest: dict,
    measured: list[dict],
    generations: list[dict],
    state: str,
    reasons: list[str],
) -> None:
    args = live.get("args") or {}
    print(
        f"모델 {model} · max_model_len {budget} · image {live.get('image_id') or 'N/A'} · revision {live.get('model_revision') or 'N/A'}"
    )
    print(
        f"live 인자(허용 목록): {json.dumps(args, ensure_ascii=False, sort_keys=True)}"
    )
    prompt = manifest.get("prompt") or {}
    print(
        f"입력 출처: mafest {manifest.get('mafest', {}).get('sha')} · prompt {prompt.get('prompt_version')} "
        f"{prompt.get('prompt_system_sha256', '')[:12]} · evidence {manifest.get('evidence_source')}"
    )
    print()
    print("| 종류 | 표본 | 입력 | max_tokens | 합 | 한도 | 여유 | 판정 |")
    print("|---|---|---|---|---|---|---|---|")
    for m in measured:
        print(
            f"| {m['kind']} | {m['id']} | {m['input_tokens']} | {m['max_tokens'] or '없음'} | "
            f"{m['total'] if m['total'] is not None else '—'} | {budget} | "
            f"{m['headroom'] if m['headroom'] is not None else '—'} | {m['verdict']} |"
        )
    print()
    print("| 종류 | 상태 | 최악 표본 | 합 |")
    print("|---|---|---|---|")
    for kind, info in (manifest.get("kinds") or {}).items():
        rows = [m for m in measured if m["kind"] == kind and m["total"] is not None]
        worst = max(rows, key=lambda m: m["total"]) if rows else None
        print(
            f"| {kind} | {info.get('status')} | {worst['id'] if worst else '—'} | {worst['total'] if worst else '—'} |"
        )
    print()
    for g in generations:
        usage = g.get("usage") or {}
        print(
            f"생성 {g['kind']}/{g['id']} schema={g['schema']} http={g.get('http')} finish={g.get('finish_reason')} "
            f"prompt_tokens={usage.get('prompt_tokens')} completion_tokens={usage.get('completion_tokens')} "
            f"latency_s={g['latency_s']} over_20s={g['over_generation_limit']} "
            f"gpu_fb_mib_observed_max={g.get('gpu_fb_used_mib_observed_max', 'N/A')} result={g.get('problem', 'OK')}"
        )
    print()
    print(f"MEASURE_STATE={state} REASONS={','.join(reasons) or '-'}")


# ── Pod 기준 live 정보와 측정 뒤 확인 ──────────────────────────────────────────────
#: 출력·판정에 쓰는 인자만 고른다. --api-key 는 있는지 여부만 기록한다(값을 버린다).
ALLOWED_ARGS = (
    "--max-model-len",
    "--served-model-name",
    "--gpu-memory-utilization",
    "--max-num-seqs",
    "--max-num-batched-tokens",
)
MODEL_PATH_RE = re.compile(r"/models/[^/]+/[^/]+/([0-9a-f]{7,64})")
EXIT_HALT = 6
FINAL_STATE_BY_EXIT = {
    EXIT_PASS: "PASS",
    EXIT_OVER: "OVER",
    EXIT_CANNOT_RUN: "CANNOT_RUN",
    EXIT_RESPONSE_FAIL: "RESPONSE_FAIL",
    4: "NOT_READY",
    EXIT_PARTIAL: "PARTIAL",
    EXIT_HALT: "HALT",
}


def pod_summary(pods: dict) -> dict:
    """측정하는 Pod 의 상태와 기동 설정. 인자·모델 revision·image digest 는 Deployment 템플릿이 아니라 Pod 에서 읽는다."""
    items = pods.get("items") or []
    summary: dict = {
        "total": len(items),
        "ready": 0,
        "restarts": 0,
        "terminated_reasons": [],
        "uid": ",".join(sorted(str(p.get("metadata", {}).get("uid")) for p in items)),
        "names": ",".join(
            sorted(str(p.get("metadata", {}).get("name")) for p in items)
        ),
        "args": {},
        "model_revision": None,
        "image_id": None,
    }
    for pod in items:
        container = next(
            (
                c
                for c in pod.get("spec", {}).get("containers", [])
                if c.get("name") == "vllm"
            ),
            None,
        )
        if container and not summary["args"]:
            args = list(container.get("args", []))
            for i, arg in enumerate(args):
                key, _, inline = arg.partition("=")
                if key == "--api-key":
                    summary["args"]["--api-key"] = "present"
                elif key in ALLOWED_ARGS:
                    summary["args"][key] = inline or (
                        args[i + 1] if i + 1 < len(args) else ""
                    )
            for part in [*container.get("command", []), *args]:
                match = MODEL_PATH_RE.fullmatch(part)
                if match:
                    summary["model_revision"] = match.group(1)
        for status in pod.get("status", {}).get("containerStatuses", []):
            if status.get("name") != "vllm":
                continue
            summary["ready"] += 1 if status.get("ready") else 0
            summary["restarts"] += int(status.get("restartCount", 0))
            reason = (status.get("lastState", {}).get("terminated") or {}).get("reason")
            if reason:
                summary["terminated_reasons"].append(reason)
            image_id = status.get("imageID", "")
            if "@" in image_id and not summary["image_id"]:
                summary["image_id"] = image_id.split("@", 1)[1]
    summary["terminated_reasons"] = sorted(summary["terminated_reasons"])
    return summary


def live_info(pods: dict) -> dict:
    s = pod_summary(pods)
    return {
        "args": s["args"],
        "image_id": s["image_id"],
        "model_revision": s["model_revision"],
        "pod": s["names"],
        "pod_uid": s["uid"],
        "restarts_before": s["restarts"],
        "terminated_reasons_before": s["terminated_reasons"],
    }


def halt_reasons(before: dict, after: dict | None) -> list[str]:
    """측정 전후 Pod 를 비교한다. 뒤 상태를 못 읽거나 Pod 가 바뀌었으면 성공으로 보지 않는다."""
    if after is None:
        return ["POST_STATE_UNREADABLE"]
    reasons: list[str] = []
    if after["total"] != 1:
        reasons.append("POD_COUNT_CHANGED")
    if after["uid"] != before["uid"]:
        reasons.append("POD_REPLACED")
    if after["ready"] != 1:
        reasons.append("POD_NOT_READY")
    if after["restarts"] > before["restarts"]:
        reasons.append("RESTART_INCREASED")
    new_oom = after["terminated_reasons"].count("OOMKilled") > before[
        "terminated_reasons"
    ].count("OOMKilled")
    if new_oom:
        reasons.append("OOM_KILLED")
    return reasons


def finalize(
    result_path: str,
    measure_exit: int,
    before_path: str,
    after_path: str,
    out_path: str | None,
) -> int:
    """측정 뒤 Pod 확인을 합쳐 최종 종료 코드·stdout·result.json 상태를 하나로 맞춘다.

    result_path 는 측정기가 쓴 결과다(없으면 종료 코드로 상태를 정한다). 중단 사유가 있으면 상태 HALT, 종료 6 이다.
    """
    with open(before_path, encoding="utf-8") as f:
        before = pod_summary(json.load(f))
    after = None
    if after_path != "-":
        try:
            with open(after_path, encoding="utf-8") as f:
                after = pod_summary(json.load(f))
        except (OSError, ValueError):
            after = None
    result: dict = {}
    if os.path.exists(result_path):
        with open(result_path, encoding="utf-8") as f:
            result = json.load(f)
    measure_state = result.get("state") or FINAL_STATE_BY_EXIT.get(
        measure_exit, "UNKNOWN"
    )
    halt = halt_reasons(before, after)
    if halt:
        final_exit, final_state, final_reasons = EXIT_HALT, "HALT", halt
    else:
        final_exit, final_state = measure_exit, measure_state
        final_reasons = result.get("reasons") or []
    result.update(
        {
            "state": final_state,
            "exit_code": final_exit,
            "reasons": final_reasons,
            "measurement_state": measure_state,
            "measurement_exit_code": measure_exit,
            "pod_before": {
                k: before[k] for k in ("uid", "ready", "restarts", "terminated_reasons")
            },
            "pod_after": (
                {
                    k: after[k]
                    for k in ("uid", "ready", "restarts", "terminated_reasons")
                }
                if after
                else None
            ),
        }
    )
    if out_path:
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
    print(
        f"FINAL_STATE={final_state} REASONS={','.join(final_reasons) or '-'} EXIT={final_exit}"
    )
    return final_exit


def main(argv: list[str]) -> int:
    if argv[:1] == ["--live"] and len(argv) == 2:
        with open(argv[1], encoding="utf-8") as f:
            print(json.dumps(live_info(json.load(f)), ensure_ascii=False))
        return 0
    if argv[:1] == ["--pod-state"] and len(argv) == 2:
        with open(argv[1], encoding="utf-8") as f:
            summary = pod_summary(json.load(f))
        print(summary["ready"], summary["total"])
        return 0
    if argv[:1] == ["--finalize"] and len(argv) in (5, 6):
        return finalize(
            argv[1], int(argv[2]), argv[3], argv[4], argv[5] if len(argv) == 6 else None
        )
    if len(argv) != 3:
        print(
            "usage: vllm_budget.py <live.json> <bodies.jsonl> <manifest.json>",
            file=sys.stderr,
        )
        return EXIT_CANNOT_RUN
    base_url = os.environ.get("VLLM_BASE_URL", "")
    if not base_url:
        print("MEASURE_STATE=CANNOT_RUN REASONS=NO_VLLM_BASE_URL", file=sys.stderr)
        return EXIT_CANNOT_RUN
    with open(argv[0], encoding="utf-8") as f:
        live = json.load(f)
    rows, manifest, problems = load_inputs(argv[1], argv[2])
    if problems:
        print(f"MEASURE_STATE=CANNOT_RUN REASONS={','.join(problems)}")
        return EXIT_CANNOT_RUN
    kinds = manifest["kinds"]
    include_experimental = os.environ.get("VLLM_BUDGET_GENERATE_EXPERIMENTAL") == "1"
    observer = GpuObserver(os.environ.get("VLLM_BUDGET_PROM_URL"))
    result_path = os.environ.get("VLLM_BUDGET_RESULT")
    try:
        model, budget, problems = check_target(base_url, live, manifest)
        if problems:
            print(f"MEASURE_STATE=CANNOT_RUN REASONS={','.join(problems)}")
            return EXIT_CANNOT_RUN
        measured = measure_tokens(base_url, model, rows, budget)
        generations: list[dict] = []
        skipped_schemas: list[str] = []
        if not any(m["verdict"] == "OVER" for m in measured):
            gpu_before = observer.read()
            targets, skipped_schemas = pick_generation_targets(
                rows, measured, kinds, include_experimental
            )
            for row in targets:
                generations.append(generate(base_url, row, observer))
            gpu_after = observer.read()
        else:
            gpu_before = gpu_after = None
    except VllmError as e:
        print(f"MEASURE_STATE=RESPONSE_FAIL REASONS={e.code}")
        return EXIT_RESPONSE_FAIL
    provenance = provenance_problems(
        manifest, os.environ.get("VLLM_BUDGET_APPROVED_MAFEST_SHA")
    )
    code, state, reasons = decide(
        measured, generations, kinds, skipped_schemas, provenance
    )
    print_report(model, budget, live, manifest, measured, generations, state, reasons)
    print(
        f"gpu_fb_used_mib before={gpu_before if gpu_before is not None else 'N/A'} after={gpu_after if gpu_after is not None else 'N/A'}"
    )
    if result_path:
        with open(result_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "state": state,
                    "reasons": reasons,
                    "model": model,
                    "max_model_len": budget,
                    "live": live,
                    "manifest_bodies_sha256": manifest.get("bodies_sha256"),
                    "tokens": measured,
                    "generations": generations,
                    "gpu_fb_used_mib": {"before": gpu_before, "after": gpu_after},
                },
                f,
                ensure_ascii=False,
                indent=2,
            )
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
