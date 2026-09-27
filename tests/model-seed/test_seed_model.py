"""seed_model.py 테스트(stdlib unittest, 네트워크·Hugging Face 없음).

규칙: 완료는 명령 종료 코드가 아니라 upstream metadata 대조로 판정한다. 고정 revision과 다른
commit, 빠진 파일, 남는 파일, 크기·sha256·git blob sha1 불일치, 필수 파일 누락, index가 가리키는
shard 누락은 모두 실패이고 최종 경로를 만들지 않는다. 이미 완료된 cache는 다시 받지 않는다.

가짜 API·download는 upstream metadata와 같은 모양(rfilename·size·blob_id·lfs.sha256)을 흉내 낸다.
실행: python3 -m unittest discover -s tests/model-seed -v
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[2] / "kustomize" / "base" / "persona-model-seed-script" / "seed_model.py"
_spec = importlib.util.spec_from_file_location("seed_model", SCRIPT)
assert _spec is not None and _spec.loader is not None
seed_model = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = seed_model
_spec.loader.exec_module(seed_model)

MODEL = "Qwen/Qwen3-4B-Instruct-2507"
REVISION = "cdbee75f17c01a7cc42f958dc650907174af0554"

# 합성 repo: 일반 파일(git blob sha1으로 대조)과 LFS 파일(sha256으로 대조)을 섞는다.
FILES = {
    "config.json": b'{"architectures": ["Qwen3ForCausalLM"]}',
    "generation_config.json": b'{"do_sample": true}',
    "tokenizer_config.json": b'{"model_max_length": 262144}',
    "model.safetensors.index.json": json.dumps(
        {"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}
    ).encode(),
    "tokenizer.json": b"tokenizer-bytes" * 10,
    "model-00001-of-00002.safetensors": b"\x01" * 4096,
    "model-00002-of-00002.safetensors": b"\x02" * 2048,
}
LFS_FILES = {"tokenizer.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"}


def blob_sha1(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def sibling(name: str, data: bytes) -> SimpleNamespace:
    if name in LFS_FILES:
        return SimpleNamespace(rfilename=name, size=len(data), blob_id="lfs-pointer-id",
                               lfs=SimpleNamespace(sha256=hashlib.sha256(data).hexdigest()))
    return SimpleNamespace(rfilename=name, size=len(data), blob_id=blob_sha1(data), lfs=None)


class FakeApi:
    def __init__(self, sha: str = REVISION, files: dict[str, bytes] = FILES) -> None:
        self.sha = sha
        self.files = files

    def model_info(self, repo_id: str, revision: str, files_metadata: bool) -> SimpleNamespace:
        assert files_metadata is True
        return SimpleNamespace(sha=self.sha, siblings=[sibling(n, d) for n, d in self.files.items()])


class FakeDownload:
    """snapshot_download 흉내. 받은 파일을 바꿔 치는 사례를 위해 override를 받는다."""

    def __init__(self, override: dict[str, bytes | None] | None = None) -> None:
        self.override = override or {}
        self.calls = 0

    def __call__(self, repo_id: str, revision: str, local_dir: str) -> str:
        self.calls += 1
        root = Path(local_dir)
        for name, data in {**FILES, **self.override}.items():
            if data is None:
                continue
            (root / name).write_bytes(data)
        (root / ".cache" / "huggingface").mkdir(parents=True)
        (root / ".cache" / "huggingface" / "download.lock").write_text("hub metadata")
        return local_dir


class SeedTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.target = Path(self._tmp.name)
        self.final = self.target / MODEL / REVISION

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_seed(self, api: FakeApi | None = None, download: FakeDownload | None = None) -> dict:
        return seed_model.seed(MODEL, REVISION, self.target, api or FakeApi(), download or FakeDownload())

    def test_verified_download_is_moved_into_place_with_marker_and_manifest(self) -> None:
        report = self.run_seed()

        self.assertEqual(report["result"], "seeded")
        self.assertTrue((self.final / seed_model.MARKER_NAME).is_file())
        manifest = json.loads((self.final / seed_model.MANIFEST_NAME).read_text())
        self.assertEqual(manifest["revision"], REVISION)
        self.assertEqual(len(manifest["files"]), len(FILES))
        self.assertFalse((self.final / ".cache").exists())  # hub 다운로드 metadata는 남기지 않는다
        self.assertFalse((self.target / ".staging" / REVISION).exists())

    def test_existing_marked_cache_is_reverified_not_downloaded_again(self) -> None:
        self.run_seed()
        download = FakeDownload()

        report = self.run_seed(download=download)

        self.assertEqual(report["result"], "already_seeded")
        self.assertEqual(download.calls, 0)

    def test_corrupted_existing_cache_is_not_overwritten(self) -> None:
        self.run_seed()
        (self.final / "config.json").write_bytes(b'{"tampered": true}')

        with self.assertRaisesRegex(seed_model.SeedError, "재검증 실패"):
            self.run_seed()

    def test_upstream_commit_must_equal_pinned_revision(self) -> None:
        with self.assertRaisesRegex(seed_model.SeedError, "요청 revision과 다르다"):
            self.run_seed(api=FakeApi(sha="0" * 40))

    def assert_rejected(self, override: dict[str, bytes | None], fragment: str) -> None:
        with self.assertRaises(seed_model.SeedError) as raised:
            self.run_seed(download=FakeDownload(override))
        self.assertIn(fragment, str(raised.exception))
        self.assertFalse(self.final.exists(), "검증에 실패하면 최종 경로를 만들지 않는다")

    def test_missing_file_is_rejected(self) -> None:
        self.assert_rejected({"tokenizer_config.json": None}, "파일이 없다: tokenizer_config.json")

    def test_unexpected_extra_file_is_rejected(self) -> None:
        self.assert_rejected({"pytorch_model.bin": b"extra"}, "upstream에 없는 파일")

    def test_lfs_sha256_mismatch_with_same_size_is_rejected(self) -> None:
        self.assert_rejected({"model-00002-of-00002.safetensors": b"\x03" * 2048}, "sha256이 다르다")

    def test_regular_file_blob_sha1_mismatch_is_rejected(self) -> None:
        tampered = FILES["generation_config.json"].replace(b"true", b"fals")
        self.assert_rejected({"generation_config.json": tampered}, "git blob sha1이 다르다")

    def test_size_mismatch_is_rejected(self) -> None:
        self.assert_rejected({"model-00001-of-00002.safetensors": b"\x01" * 10}, "크기가 다르다")

    def test_index_shard_missing_from_upstream_list_is_rejected(self) -> None:
        # upstream 목록 자체에서 shard가 빠진 경우: index가 가리키는 파일이 없으면 서빙할 수 없다.
        files = {k: v for k, v in FILES.items() if k != "model-00002-of-00002.safetensors"}
        with self.assertRaisesRegex(seed_model.SeedError, "shard가 없다"):
            self.run_seed(api=FakeApi(files=files), download=FakeDownload({"model-00002-of-00002.safetensors": None}))

    def test_required_file_missing_upstream_is_rejected(self) -> None:
        files = {k: v for k, v in FILES.items() if k != "generation_config.json"}
        with self.assertRaisesRegex(seed_model.SeedError, "필수 파일"):
            self.run_seed(api=FakeApi(files=files), download=FakeDownload({"generation_config.json": None}))

    def test_final_path_without_marker_is_left_for_a_human(self) -> None:
        self.final.mkdir(parents=True)

        with self.assertRaisesRegex(seed_model.SeedError, "완료 marker 없이"):
            self.run_seed()


class MetadataTest(unittest.TestCase):
    def test_metadata_without_hashes_is_rejected(self) -> None:
        for sib in [
            SimpleNamespace(rfilename="a", size=None, blob_id="x", lfs=None),
            SimpleNamespace(rfilename="b", size=1, blob_id=None, lfs=None),
            SimpleNamespace(rfilename="c", size=1, blob_id="x", lfs=SimpleNamespace(sha256=None)),
        ]:
            with self.subTest(file=sib.rfilename), self.assertRaises(seed_model.SeedError):
                seed_model.expected_files_from_siblings([sib])

    def test_git_blob_sha1_matches_git_definition(self) -> None:
        # `printf 'hello\n' | git hash-object --stdin` = ce013625030ba8dba906f756967f9e9ca394464a
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            handle.write(b"hello\n")
        try:
            self.assertEqual(seed_model.git_blob_sha1(Path(handle.name)), "ce013625030ba8dba906f756967f9e9ca394464a")
        finally:
            os.unlink(handle.name)


class ConfigTest(unittest.TestCase):
    def test_revision_must_be_full_commit_hash(self) -> None:
        for revision in ["main", "cdbee75", "v1.0", ""]:
            with self.subTest(revision=revision):
                os.environ.update(MODEL_ID=MODEL, MODEL_REVISION=revision, TARGET_DIR="/models")
                with self.assertRaises(seed_model.SeedError):
                    seed_model.read_config()

    def test_valid_config(self) -> None:
        os.environ.update(MODEL_ID=MODEL, MODEL_REVISION=REVISION, TARGET_DIR="/models")
        self.assertEqual(seed_model.read_config(), (MODEL, REVISION, Path("/models")))


if __name__ == "__main__":
    unittest.main()
