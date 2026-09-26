#!/usr/bin/env python3
"""GPU worker의 Kubernetes 버전이 클러스터에 Join해도 되는 범위인지 판정한다.

Ansible controller에서 실행한다(playbook이 `delegate_to: localhost`로 부른다). 표준 라이브러리만
쓰고 네트워크·클러스터를 호출하지 않는다 — 입력은 사람이 읽어 넘긴 값과 GPU host에서 읽은 출력이다.

두 모드가 있다.

- ``package``: 10-base가 설치할 deb package version(예: ``1.36.2-1.1``)의 형식과 minor를 검사한다.
  저장소에 그 값이 실제로 있는지는 playbook이 ``apt-cache madison`` 출력으로 따로 확인한다.
- ``join``: Join 직전에 GPU kubeadm·kubelet, API server, control-plane kubelet 버전을 받아
  API server 기준 skew를 판정하고 네 값의 patch를 모두 보고한다.

기준이 API server인 이유: Kubernetes version skew 정책에서 kubelet은 kube-apiserver보다 새
버전이면 안 되고, kubeadm join은 클러스터와 같은 minor를 쓴다. control-plane kubelet은 API
server와 patch가 다를 수 있으므로(예: API v1.36.4, CP kubelet v1.36.2) 비교 기준이 아니라
drift 기록 대상이다.

종료 코드: 0 통과, 1 skew 위반, 2 입력 파싱 실패. 결과는 항상 JSON 한 줄로 stdout에 출력한다 —
실패할 때도 네 버전을 보여 줘 drift를 숨기지 않기 위해서다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import NamedTuple

EXIT_OK = 0
EXIT_SKEW_VIOLATION = 1
EXIT_PARSE_ERROR = 2

# `kubeadm version -o short`는 "v1.36.2", `kubelet --version`은 "Kubernetes v1.36.2"를 낸다.
# 앞뒤 공백과 "Kubernetes " 접두사만 허용한다. pre-release·build 접미사(-rc.1, +abc)는 받지 않는다 —
# 운영 Join 대상이 아니고, 비교 규칙을 정하지 않은 값을 추측해 해석하지 않는다.
KUBERNETES_VERSION = re.compile(r"^\s*(?:Kubernetes\s+)?v(\d+)\.(\d+)\.(\d+)\s*$")
# pkgs.k8s.io deb version: "<major>.<minor>.<patch>-<debian revision>" (예: 1.36.2-1.1).
# revision은 apt가 보여 준 그대로 받되, 형식이 다르면 거부한다.
PACKAGE_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)-[0-9][0-9A-Za-z.+~]*$")
MINOR = re.compile(r"^(\d+)\.(\d+)$")


class Version(NamedTuple):
    major: int
    minor: int
    patch: int

    def text(self) -> str:
        return f"v{self.major}.{self.minor}.{self.patch}"

    def same_minor(self, other: Version) -> bool:
        return (self.major, self.minor) == (other.major, other.minor)


class VersionParseError(ValueError):
    """입력이 약속한 형식이 아니다. 무엇을 받았는지 메시지에 남긴다."""


def parse_kubernetes_version(value: str, label: str) -> Version:
    match = KUBERNETES_VERSION.match(value)
    if match is None:
        raise VersionParseError(f"{label}: Kubernetes 버전 형식(vMAJOR.MINOR.PATCH)이 아니다: {value!r}")
    return Version(*(int(part) for part in match.groups()))


def parse_package_version(value: str) -> Version:
    match = PACKAGE_VERSION.match(value.strip())
    if match is None:
        raise VersionParseError(
            f"package version이 deb 형식(MAJOR.MINOR.PATCH-REVISION)이 아니다: {value!r}"
        )
    return Version(*(int(part) for part in match.groups()))


def parse_minor(value: str) -> tuple[int, int]:
    match = MINOR.match(value.strip())
    if match is None:
        raise VersionParseError(f"gpu_kubernetes_minor 형식(MAJOR.MINOR)이 아니다: {value!r}")
    return int(match.group(1)), int(match.group(2))


def check_package(minor: str, package_version: str) -> dict[str, object]:
    """10-base 입력 검사. 형식이 맞고 major.minor가 저장소 minor와 같아야 한다."""
    wanted = parse_minor(minor)
    version = parse_package_version(package_version)
    violations = []
    if (version.major, version.minor) != wanted:
        violations.append(
            f"package version {package_version}의 minor가 gpu_kubernetes_minor {minor}와 다르다"
        )
    return {
        "mode": "package",
        "package_version": package_version.strip(),
        "package_kubernetes_version": version.text(),
        "violations": violations,
        "ok": not violations,
    }


def check_join(
    api_server: str, control_plane_kubelet: str, gpu_kubeadm: str, gpu_kubelet: str
) -> dict[str, object]:
    """Join 직전 판정. 위반(violations)은 Join을 막고, drift는 기록만 한다."""
    api = parse_kubernetes_version(api_server, "api_server_version")
    cp_kubelet = parse_kubernetes_version(control_plane_kubelet, "control_plane_kubelet_version")
    kubeadm = parse_kubernetes_version(gpu_kubeadm, "GPU kubeadm")
    kubelet = parse_kubernetes_version(gpu_kubelet, "GPU kubelet")

    violations = []
    if not kubeadm.same_minor(api):
        violations.append(f"GPU kubeadm {kubeadm.text()}의 minor가 API server {api.text()}와 다르다")
    if not kubelet.same_minor(api):
        violations.append(f"GPU kubelet {kubelet.text()}의 minor가 API server {api.text()}와 다르다")
    elif kubelet.patch > api.patch:
        violations.append(
            f"GPU kubelet {kubelet.text()}이 API server {api.text()}보다 새 patch다 — "
            "kubelet은 API server보다 새 버전이면 안 된다"
        )

    # 통과를 막지 않지만 보고서에서 사라지면 안 되는 차이.
    drift = []
    if cp_kubelet != api:
        drift.append(
            f"control-plane kubelet {cp_kubelet.text()}과 API server {api.text()}의 patch가 다르다"
        )
    if kubelet != cp_kubelet:
        drift.append(f"GPU kubelet {kubelet.text()}과 control-plane kubelet {cp_kubelet.text()}이 다르다")
    if kubeadm != kubelet:
        drift.append(f"GPU kubeadm {kubeadm.text()}과 GPU kubelet {kubelet.text()}이 다르다")

    return {
        "mode": "join",
        "api_server": api.text(),
        "control_plane_kubelet": cp_kubelet.text(),
        "gpu_kubeadm": kubeadm.text(),
        "gpu_kubelet": kubelet.text(),
        "patches": {
            "api_server": api.patch,
            "control_plane_kubelet": cp_kubelet.patch,
            "gpu_kubeadm": kubeadm.patch,
            "gpu_kubelet": kubelet.patch,
        },
        "violations": violations,
        "drift": drift,
        "ok": not violations,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    modes = parser.add_subparsers(dest="mode", required=True)
    package = modes.add_parser("package", help="10-base 설치 package version 검사")
    package.add_argument("--minor", required=True)
    package.add_argument("--package-version", required=True)
    join = modes.add_parser("join", help="Join 직전 API server 기준 skew 판정")
    join.add_argument("--api-server", required=True)
    join.add_argument("--cp-kubelet", required=True)
    join.add_argument("--gpu-kubeadm", required=True)
    join.add_argument("--gpu-kubelet", required=True)
    args = parser.parse_args(argv)

    try:
        if args.mode == "package":
            report = check_package(args.minor, args.package_version)
        else:
            report = check_join(args.api_server, args.cp_kubelet, args.gpu_kubeadm, args.gpu_kubelet)
    except VersionParseError as error:
        print(json.dumps({"mode": args.mode, "ok": False, "parse_error": str(error)}, ensure_ascii=False))
        return EXIT_PARSE_ERROR

    print(json.dumps(report, ensure_ascii=False))
    return EXIT_OK if report["ok"] else EXIT_SKEW_VIOLATION


if __name__ == "__main__":
    sys.exit(main())
