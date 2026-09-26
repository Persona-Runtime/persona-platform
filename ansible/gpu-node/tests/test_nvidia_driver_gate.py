"""nvidia_driver_gate.py 테스트(stdlib unittest, host·네트워크 없음).

규칙: 기준선은 Ubuntu nvidia-driver-580-server의 정확한 package version이다. R580이 이미
정상(요청 version 설치 + 적재 + 실행 중 kernel용 DKMS)이면 재설치하지 않는다. driver가 전혀
없으면 설치한다. 다른 branch·다른 patch·미적재·DKMS 불일치는 바꾸지 않고 멈춘다. 580을 가리키는
Ubuntu 570-server 전환 package는 drift로만 보고한다.

입력 예시는 형식을 보이기 위한 합성 값이다. 실제 host 출력 형식은 설치 당일 확인한다.
실행: python3 -m unittest discover -s ansible/gpu-node/tests -v
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "files" / "nvidia_driver_gate.py"
_spec = importlib.util.spec_from_file_location("nvidia_driver_gate", SCRIPT)
assert _spec is not None and _spec.loader is not None
gate = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = gate
_spec.loader.exec_module(gate)

PACKAGE = "580.95.05-0ubuntu0.24.04.2"
KERNEL = "6.8.0-1015-aws"
DPKG_R580 = "nvidia-driver-580-server\thi \t580.95.05-0ubuntu0.24.04.2\tnvidia-dkms-580-server, libnvidia-compute-580-server\n"
DPKG_TRANSITIONAL_570 = "nvidia-driver-570-server\tii \t580.95.05-0ubuntu0.24.04.2\tnvidia-driver-580-server\n"
DKMS_R580 = f"nvidia/580.95.05, {KERNEL}, x86_64: installed\n"


def decide(
    dpkg: str = DPKG_R580,
    smi_rc: int = 0,
    smi: str = "580.95.05\n",
    dkms: str = DKMS_R580,
    package: str = PACKAGE,
    kernel: str = KERNEL,
) -> dict:
    return gate.decide(package, dpkg, smi_rc, smi, dkms, kernel)


class HealthyR580Test(unittest.TestCase):
    def test_r580_with_dkms_is_left_alone(self) -> None:
        report = decide()

        self.assertEqual(report["state"], "healthy")
        self.assertEqual(report["action"], "skip_install")
        self.assertEqual(report["reasons"], [])

    def test_old_dkms_status_format_is_understood(self) -> None:
        report = decide(dkms=f"nvidia, 580.95.05, {KERNEL}, x86_64: installed\n")

        self.assertEqual(report["state"], "healthy")

    def test_ubuntu_570_transitional_package_is_drift_not_block(self) -> None:
        report = decide(dpkg=DPKG_R580 + DPKG_TRANSITIONAL_570)

        self.assertEqual(report["state"], "healthy")
        self.assertTrue(any("전환 package" in d for d in report["drift"]))


class NotInstalledTest(unittest.TestCase):
    def test_clean_host_gets_install(self) -> None:
        report = decide(dpkg="", smi_rc=127, smi="", dkms="")

        self.assertEqual(report["state"], "not_installed")
        self.assertEqual(report["action"], "install")

    def test_removed_package_with_leftover_config_counts_as_not_installed(self) -> None:
        leftover = "nvidia-driver-580-server\trc \t580.95.05-0ubuntu0.24.04.2\t\n"

        self.assertEqual(decide(dpkg=leftover, smi_rc=127, smi="", dkms="")["state"], "not_installed")

    def test_driver_loaded_without_package_is_blocked(self) -> None:
        report = decide(dpkg="", smi_rc=0, smi="580.95.05\n", dkms="")

        self.assertEqual(report["state"], "blocked")
        self.assertTrue(any("출처 미상" in r for r in report["reasons"]))


class OtherBranchTest(unittest.TestCase):
    def test_real_r570_driver_is_blocked(self) -> None:
        dpkg = "cuda-drivers-570\tii \t570.211.01-0ubuntu1\t\nnvidia-driver-570-server\tii \t570.211.01-0ubuntu1\tnvidia-dkms-570-server\n"
        report = decide(dpkg=dpkg, smi="570.211.01\n", dkms=f"nvidia/570.211.01, {KERNEL}, x86_64: installed\n")

        self.assertEqual(report["state"], "blocked")
        self.assertTrue(any("기준선이 아닌 driver package" in r for r in report["reasons"]))

    def test_open_kernel_module_flavor_is_not_the_baseline(self) -> None:
        dpkg = "nvidia-driver-580-server-open\tii \t580.95.05-0ubuntu0.24.04.2\t\n"

        self.assertEqual(decide(dpkg=dpkg)["state"], "blocked")

    def test_r580_package_with_different_patch_is_blocked(self) -> None:
        dpkg = "nvidia-driver-580-server\tii \t580.82.07-0ubuntu0.24.04.1\tnvidia-dkms-580-server\n"
        report = decide(dpkg=dpkg, smi="580.82.07\n", dkms=f"nvidia/580.82.07, {KERNEL}, x86_64: installed\n")

        self.assertEqual(report["state"], "blocked")
        self.assertTrue(any("patch를 자동으로 바꾸지 않는다" in r for r in report["reasons"]))


class UnhealthyR580Test(unittest.TestCase):
    def test_installed_but_not_loaded_is_blocked(self) -> None:
        report = decide(smi_rc=9, smi="")

        self.assertEqual(report["state"], "blocked")
        self.assertTrue(any("적재돼 있지 않다" in r for r in report["reasons"]))

    def test_dkms_built_for_another_kernel_is_blocked(self) -> None:
        report = decide(dkms="nvidia/580.95.05, 6.8.0-1012-aws, x86_64: installed\n")

        self.assertEqual(report["state"], "blocked")
        self.assertTrue(any("DKMS" in r for r in report["reasons"]))

    def test_dkms_not_installed_state_is_blocked(self) -> None:
        self.assertEqual(decide(dkms=f"nvidia/580.95.05, {KERNEL}, x86_64: built\n")["state"], "blocked")


class InputValidationTest(unittest.TestCase):
    def test_package_version_must_be_exact_r580(self) -> None:
        for package in ["", "580", "580-server", "570.211.01-0ubuntu1", "latest", "580.95.05"]:
            with self.subTest(package=package), self.assertRaises(gate.GateInputError):
                decide(package=package)

    def test_two_field_upstream_version_is_accepted(self) -> None:
        dpkg = "nvidia-driver-580-server\tii \t580.82-0ubuntu1\t\n"
        report = decide(dpkg=dpkg, package="580.82-0ubuntu1", smi="580.82\n", dkms=f"nvidia/580.82, {KERNEL}, x86_64: installed\n")

        self.assertEqual(report["state"], "healthy")


class CommandLineTest(unittest.TestCase):
    def run_gate(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False)

    def test_exit_codes(self) -> None:
        healthy = self.run_gate(
            "--package-version", PACKAGE, "--dpkg-output", DPKG_R580, "--nvidia-smi-rc", "0",
            "--nvidia-smi-output", "580.95.05", "--dkms-output", DKMS_R580, "--kernel", KERNEL,
        )
        blocked = self.run_gate(
            "--package-version", PACKAGE, "--dpkg-output", DPKG_R580, "--nvidia-smi-rc", "9",
            "--dkms-output", DKMS_R580, "--kernel", KERNEL,
        )
        invalid = self.run_gate("--package-version", "570", "--nvidia-smi-rc", "0", "--kernel", KERNEL)

        self.assertEqual(healthy.returncode, gate.EXIT_OK)
        self.assertEqual(json.loads(healthy.stdout)["action"], "skip_install")
        self.assertEqual(blocked.returncode, gate.EXIT_BLOCKED)
        self.assertEqual(invalid.returncode, gate.EXIT_PARSE_ERROR)


if __name__ == "__main__":
    unittest.main()
