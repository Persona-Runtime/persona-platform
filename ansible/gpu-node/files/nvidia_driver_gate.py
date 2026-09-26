#!/usr/bin/env python3
"""GPU host의 NVIDIA driver 상태를 R580 기준선과 대조해 할 일을 정한다.

Ansible controller에서 실행한다(30-gpu-runtime이 `delegate_to: localhost`로 부른다). 표준
라이브러리만 쓰고 host·네트워크를 호출하지 않는다 — 입력은 host에서 읽은 명령 출력과, 사람이
`apt-cache madison nvidia-driver-580-server`에서 골라 넘긴 package version이다.

기준선: Ubuntu `nvidia-driver-580-server`를 정확한 package version으로 설치하고 DKMS가 실행 중인
kernel에 module을 만든 상태. 판정 결과(`state`)는 셋 중 하나다.

- ``healthy``: 요청한 version이 설치돼 있고, 적재된 driver와 DKMS module이 그 version이며
  실행 중인 kernel용으로 설치돼 있다 → **재설치·재부팅 없이** Toolkit·containerd만 검증한다.
- ``not_installed``: NVIDIA driver package도, 적재된 driver도, DKMS module도 없다 → 설치한다.
- ``blocked``: 그 밖의 모든 상태(다른 branch, 다른 patch, driver 미적재, DKMS 불일치, 출처를 모르는
  driver) → 아무것도 바꾸지 않고 멈춘다. 자동으로 전환·재설치하지 않는다 — driver 교체는 재부팅을
  동반하므로 사람이 원인을 보고 결정한다.

R570(`cuda-drivers-570`·`nvidia-driver-570-server`) 전환 경로는 폐기했다. Ubuntu 24.04의
`nvidia-driver-570-server`는 `nvidia-driver-580-server`를 의존하는 전환 package이므로, 그것이
설치돼 있어도 580을 가리키기만 하면 driver 불일치가 아니라 drift로 보고한다.

종료 코드: 0 할 일이 정해짐(healthy·not_installed), 1 blocked, 2 입력 형식 오류. 결과는 항상
JSON 한 줄로 stdout에 출력한다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

EXIT_OK = 0
EXIT_BLOCKED = 1
EXIT_PARSE_ERROR = 2

DRIVER_BRANCH = "580"
DRIVER_PACKAGE = f"nvidia-driver-{DRIVER_BRANCH}-server"

# Ubuntu package version: "<upstream>-<revision>" (예: 580.95.05-0ubuntu0.24.04.2). upstream은
# nvidia-smi가 보여 주는 driver version과 같다(580.95.05, 일부 release는 580.82처럼 두 칸).
PACKAGE_VERSION = re.compile(rf"^({DRIVER_BRANCH}\.\d+(?:\.\d+)?)-[0-9][0-9A-Za-z.+~]*$")
# nvidia-driver-<branch>, -server, -open, -server-open 변형을 모두 driver package로 본다.
DRIVER_PACKAGE_NAME = re.compile(r"^nvidia-driver-(\d+)(-server)?(-open)?$")
# `dkms status` 두 형식: "nvidia/580.95.05, 6.8.0-1015-aws, x86_64: installed"(새 형식)와
# "nvidia, 580.95.05, 6.8.0-1015-aws, x86_64: installed"(옛 형식).
DKMS_LINE = re.compile(
    r"^nvidia(?:/|,\s*)(?P<version>[0-9.]+),\s*(?P<kernel>[^,]+),\s*[^:]+:\s*(?P<state>.+)$"
)


class GateInputError(ValueError):
    """입력이 약속한 형식이 아니다."""


def parse_package_version(value: str) -> str:
    """package version에서 upstream driver version을 꺼낸다. 580 branch가 아니면 거부한다."""
    match = PACKAGE_VERSION.match(value.strip())
    if match is None:
        raise GateInputError(
            f"nvidia_driver_package_version은 {DRIVER_PACKAGE}의 정확한 package version이어야 한다"
            f"(예: 580.95.05-0ubuntu0.24.04.2): {value!r}"
        )
    return match.group(1)


def parse_installed_packages(dpkg_output: str) -> list[dict[str, str]]:
    """`dpkg-query -W -f='${Package}\\t${db:Status-Abbrev}\\t${Version}\\t${Depends}\\n'` 출력.

    설치된 것(상태가 ii 또는 hold된 hi)만 돌려준다. 제거됐지만 설정이 남은 rc 등은 무시한다.
    """
    packages = []
    for line in dpkg_output.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            raise GateInputError(f"dpkg-query 출력 형식이 아니다: {line!r}")
        name, status, version = fields[0].strip(), fields[1].strip(), fields[2].strip()
        depends = fields[3].strip() if len(fields) > 3 else ""
        if status[:2] in {"ii", "hi"} and DRIVER_PACKAGE_NAME.match(name):
            packages.append({"name": name, "version": version, "depends": depends})
    return packages


def parse_dkms(dkms_output: str) -> list[dict[str, str]]:
    modules = []
    for line in dkms_output.splitlines():
        match = DKMS_LINE.match(line.strip())
        if match:
            modules.append({key: match.group(key).strip() for key in ("version", "kernel", "state")})
    return modules


def decide(
    package_version: str,
    dpkg_output: str,
    nvidia_smi_rc: int,
    nvidia_smi_output: str,
    dkms_output: str,
    kernel: str,
) -> dict[str, object]:
    expected = parse_package_version(package_version)
    installed = parse_installed_packages(dpkg_output)
    loaded = [line.strip() for line in nvidia_smi_output.splitlines() if line.strip()]
    dkms = parse_dkms(dkms_output)
    kernel = kernel.strip()

    reasons: list[str] = []
    drift: list[str] = []
    baseline = next((p for p in installed if p["name"] == DRIVER_PACKAGE), None)
    for package in installed:
        if package is baseline:
            continue
        # Ubuntu의 570-server처럼 580-server를 의존하는 전환 package는 driver를 따로 설치하지 않는다.
        if DRIVER_PACKAGE in package["depends"]:
            drift.append(
                f"{package['name']} {package['version']}은 {DRIVER_PACKAGE}로 이어지는 전환 package다"
            )
        else:
            reasons.append(
                f"기준선이 아닌 driver package가 설치돼 있다: {package['name']} {package['version']}"
            )

    if baseline is None:
        if nvidia_smi_rc == 0 and loaded:
            reasons.append(f"package 없이 driver가 적재돼 있다(출처 미상): {', '.join(loaded)}")
        if dkms:
            reasons.append(f"package 없이 DKMS nvidia module이 남아 있다: {dkms}")
        state = "not_installed" if not reasons else "blocked"
    else:
        if baseline["version"] != package_version.strip():
            reasons.append(
                f"{DRIVER_PACKAGE} {baseline['version']}이 설치돼 있어 요청 version "
                f"{package_version.strip()}과 다르다 — patch를 자동으로 바꾸지 않는다"
            )
        if nvidia_smi_rc != 0 or not loaded:
            reasons.append("driver가 적재돼 있지 않다(nvidia-smi 실패) — 재부팅 대기나 module 적재 실패")
        elif any(version != expected for version in loaded):
            reasons.append(f"적재된 driver {', '.join(loaded)}이 기대 version {expected}과 다르다")
        built = [
            m for m in dkms
            if m["version"] == expected and m["kernel"] == kernel and m["state"].startswith("installed")
        ]
        if not built:
            reasons.append(
                f"실행 중인 kernel {kernel}용 DKMS nvidia/{expected} module이 installed 상태가 아니다: {dkms}"
            )
        state = "healthy" if not reasons else "blocked"

    return {
        "state": state,
        "action": {"healthy": "skip_install", "not_installed": "install", "blocked": "stop"}[state],
        "requested_package_version": package_version.strip(),
        "expected_driver_version": expected,
        "installed_driver_packages": installed,
        "loaded_driver_versions": loaded,
        "dkms_modules": dkms,
        "kernel": kernel,
        "reasons": reasons,
        "drift": drift,
        "ok": state != "blocked",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--dpkg-output", default="")
    parser.add_argument("--nvidia-smi-rc", type=int, required=True)
    parser.add_argument("--nvidia-smi-output", default="")
    parser.add_argument("--dkms-output", default="")
    parser.add_argument("--kernel", required=True)
    args = parser.parse_args(argv)

    try:
        report = decide(
            args.package_version,
            args.dpkg_output,
            args.nvidia_smi_rc,
            args.nvidia_smi_output,
            args.dkms_output,
            args.kernel,
        )
    except GateInputError as error:
        print(json.dumps({"state": "invalid", "ok": False, "parse_error": str(error)}, ensure_ascii=False))
        return EXIT_PARSE_ERROR

    print(json.dumps(report, ensure_ascii=False))
    return EXIT_OK if report["ok"] else EXIT_BLOCKED


if __name__ == "__main__":
    sys.exit(main())
