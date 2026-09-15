#!/bin/sh
# 내려받은 chart를 사용해 로컬 렌더만 수행한다. 설치나 네트워크 호출은 하지 않는다.
set -eu
for tool in helm kubectl ruby mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필수 도구 없음: $tool" >&2; exit 1; }
done
[ "$#" -eq 1 ] || { echo "사용법: sh $0 <csi-driver-nfs-4.13.4-chart-directory>" >&2; exit 1; }
chart=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
ruby -E UTF-8 -ryaml -e 'abort "chart version mismatch" unless YAML.load_file(ARGV[0]).values_at("name", "version") == ["csi-driver-nfs", "4.13.4"]' "$chart/Chart.yaml"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/persona-nfs-validate.XXXXXX")
# 이 실행에서 만든 임시 렌더 파일만 정리한다.
trap 'rm -f "$scratch/csi.yaml" "$scratch/storage.yaml"; rmdir "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
helm lint "$chart" -f helm/values/csi-driver-nfs.yaml --strict
helm template csi-driver-nfs "$chart" -n kube-system -f helm/values/csi-driver-nfs.yaml > "$scratch/csi.yaml"
kubectl kustomize kustomize/overlays/prod/nfs-storage > "$scratch/storage.yaml"
ruby -E UTF-8 scripts/validate-nfs-manifests.rb "$scratch/csi.yaml" "$scratch/storage.yaml"
