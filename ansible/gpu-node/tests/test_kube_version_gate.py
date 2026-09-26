"""kube_version_gate.py 테스트(stdlib unittest, 네트워크·클러스터 없음).

규칙: Join 판정의 기준은 API server다. GPU kubeadm·kubelet은 API server와 minor가 같아야 하고,
GPU kubelet은 API server보다 새 patch면 안 된다. control-plane kubelet과의 차이는 실패가 아니라
drift로 보고한다. 형식이 약속과 다른 입력은 추측하지 않고 거부한다.

실행: python3 -m unittest discover -s ansible/gpu-node/tests -v
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "files" / "kube_version_gate.py"
_spec = importlib.util.spec_from_file_location("kube_version_gate", SCRIPT)
assert _spec is not None and _spec.loader is not None
gate = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = gate
_spec.loader.exec_module(gate)

# 2026-09-26 관측값: API server와 control-plane kubelet의 patch가 이미 다르다.
API_SERVER = "v1.36.4"
CP_KUBELET = "v1.36.2"


class ParseKubernetesVersionTest(unittest.TestCase):
    def test_accepts_kubeadm_and_kubelet_output_forms(self) -> None:
        self.assertEqual(gate.parse_kubernetes_version("v1.36.4", "x"), gate.Version(1, 36, 4))
        self.assertEqual(
            gate.parse_kubernetes_version("Kubernetes v1.36.2\n", "x"), gate.Version(1, 36, 2)
        )

    def test_rejects_values_it_would_have_to_guess(self) -> None:
        for value in ["", "1.36.4", "v1.36", "v1.36.x", "v1.36.4-rc.1", "v1.36.4+abc", "v1.36.2 v1.36.3"]:
            with self.subTest(value=value), self.assertRaises(gate.VersionParseError):
                gate.parse_kubernetes_version(value, "input")

    def test_patch_is_compared_as_a_number_not_a_substring(self) -> None:
        # 이전 gate는 "v1.36.2" in stdout 비교라 v1.36.21도 통과시켰다.
        self.assertEqual(gate.parse_kubernetes_version("v1.36.21", "x").patch, 21)


class CheckPackageTest(unittest.TestCase):
    def test_accepts_apt_style_version_with_matching_minor(self) -> None:
        report = gate.check_package("1.36", "1.36.2-1.1")

        self.assertTrue(report["ok"])
        self.assertEqual(report["package_kubernetes_version"], "v1.36.2")

    def test_rejects_version_from_another_minor(self) -> None:
        report = gate.check_package("1.36", "1.37.0-1.1")

        self.assertFalse(report["ok"])
        self.assertIn("minor", report["violations"][0])

    def test_rejects_malformed_package_or_minor(self) -> None:
        for minor, package in [("1.36", "1.36.2"), ("1.36", "v1.36.2-1.1"), ("1.36", "latest"), ("v1.36", "1.36.2-1.1")]:
            with self.subTest(minor=minor, package=package), self.assertRaises(gate.VersionParseError):
                gate.check_package(minor, package)


class CheckJoinTest(unittest.TestCase):
    def test_same_patch_as_control_plane_kubelet_passes_and_reports_cp_drift(self) -> None:
        report = gate.check_join(API_SERVER, CP_KUBELET, "v1.36.2", "Kubernetes v1.36.2")

        self.assertTrue(report["ok"])
        self.assertEqual(report["violations"], [])
        self.assertEqual(
            report["patches"],
            {"api_server": 4, "control_plane_kubelet": 2, "gpu_kubeadm": 2, "gpu_kubelet": 2},
        )
        # CP 내부의 patch 차이를 숨기지 않는다.
        self.assertTrue(any("control-plane kubelet v1.36.2과 API server v1.36.4" in d for d in report["drift"]))

    def test_same_patch_as_api_server_passes(self) -> None:
        report = gate.check_join(API_SERVER, CP_KUBELET, "v1.36.4", "Kubernetes v1.36.4")

        self.assertTrue(report["ok"])
        self.assertTrue(any("GPU kubelet v1.36.4과 control-plane kubelet v1.36.2" in d for d in report["drift"]))

    def test_gpu_kubelet_newer_patch_than_api_server_fails(self) -> None:
        report = gate.check_join(API_SERVER, CP_KUBELET, "v1.36.4", "Kubernetes v1.36.5")

        self.assertFalse(report["ok"])
        self.assertTrue(any("보다 새 patch" in v for v in report["violations"]))
        # 실패해도 네 patch는 모두 보고한다.
        self.assertEqual(report["patches"]["gpu_kubelet"], 5)

    def test_minor_mismatch_fails_for_kubeadm_and_kubelet(self) -> None:
        kubeadm_off = gate.check_join(API_SERVER, CP_KUBELET, "v1.37.0", "Kubernetes v1.36.2")
        kubelet_off = gate.check_join(API_SERVER, CP_KUBELET, "v1.36.2", "Kubernetes v1.35.9")

        self.assertTrue(any("GPU kubeadm" in v for v in kubeadm_off["violations"]))
        self.assertTrue(any("GPU kubelet" in v for v in kubelet_off["violations"]))

    def test_kubeadm_kubelet_difference_is_drift_not_violation(self) -> None:
        report = gate.check_join(API_SERVER, CP_KUBELET, "v1.36.3", "Kubernetes v1.36.2")

        self.assertTrue(report["ok"])
        self.assertTrue(any("GPU kubeadm v1.36.3과 GPU kubelet v1.36.2" in d for d in report["drift"]))

    def test_malformed_input_is_a_parse_error(self) -> None:
        with self.assertRaises(gate.VersionParseError):
            gate.check_join("", CP_KUBELET, "v1.36.2", "Kubernetes v1.36.2")


class CommandLineTest(unittest.TestCase):
    def run_gate(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False
        )

    def test_exit_codes_and_json_report(self) -> None:
        passing = self.run_gate(
            "join", "--api-server", API_SERVER, "--cp-kubelet", CP_KUBELET,
            "--gpu-kubeadm", "v1.36.2", "--gpu-kubelet", "Kubernetes v1.36.2",
        )
        newer = self.run_gate(
            "join", "--api-server", API_SERVER, "--cp-kubelet", CP_KUBELET,
            "--gpu-kubeadm", "v1.36.5", "--gpu-kubelet", "Kubernetes v1.36.5",
        )
        malformed = self.run_gate("package", "--minor", "1.36", "--package-version", "1.36")

        self.assertEqual(passing.returncode, gate.EXIT_OK)
        self.assertTrue(json.loads(passing.stdout)["ok"])
        self.assertEqual(newer.returncode, gate.EXIT_SKEW_VIOLATION)
        self.assertEqual(json.loads(newer.stdout)["patches"]["gpu_kubelet"], 5)
        self.assertEqual(malformed.returncode, gate.EXIT_PARSE_ERROR)
        self.assertIn("parse_error", json.loads(malformed.stdout))


if __name__ == "__main__":
    unittest.main()
