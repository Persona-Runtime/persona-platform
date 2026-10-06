#!/bin/sh
# mem-lab 노드 선언의 정적 검사. 클러스터나 AWS에 접속하지 않고 파일만 읽는다.
#
# 이 스크립트가 막는 두 가지:
#   (1) public security group에 Kubernetes 포트가 열리는 것
#   (2) ansible/mem-lab-worker에 GPU runtime이 들어오는 것
#
# 왜 `terraform test`와 따로 두는가: `terraform test`는 자신이 아는 자원만 셀 수 있어서,
# **새 이름으로 선언된** ingress 자원을 보지 못한다. 반면 이 스크립트는 선언 파일의 텍스트를
# 보므로 자원 이름과 무관하게 걸린다. 두 검사는 서로의 사각지대를 덮는다.
#
# root를 스크립트 위치 기준으로 구한다. 그래서 이 파일을 복사본 트리의 scripts/에 넣고
# 실행하면 그 복사본을 검사한다 — scripts/test-mem-lab-negative.sh가 그 방식을 쓴다.
set -eu

for tool in ruby grep sed sort ls; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tf_dir="$root/terraform/envs/mem-lab"
ansible_dir="$root/ansible/mem-lab-worker"
playbook_dir="$ansible_dir/playbooks"
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

[ -d "$tf_dir" ] || { echo "대상이 없습니다: $tf_dir" >&2; exit 1; }
[ -d "$playbook_dir" ] || { echo "대상이 없습니다: $playbook_dir" >&2; exit 1; }

# ── (1) public Kubernetes port ───────────────────────────────────────────────
#
# API 6443, kubelet 10250, Cilium VXLAN 8472, health 4240, NodePort 30000-32767.
# 마지막 대역은 정확히 그 범위만 잡도록 네 조각으로 쓴다. 넓게 쓰면 gp3 iops(3000) 같은
# 무관한 숫자를 오검출한다.
#
# `\b`는 BSD grep에서 보장되지 않아 쓰지 않는다. 대신 앞뒤가 숫자가 아닌 것을 직접 쓴다 —
# 그래야 41641의 일부나 소수점 뒤 숫자를 잘못 집지 않는다.
forbidden_ports='(^|[^0-9])(6443|10250|8472|4240|3[01][0-9][0-9][0-9]|32[0-6][0-9][0-9]|327[0-5][0-9]|3276[0-7])([^0-9]|$)'

# 주석을 지우고 검사한다. 이 저장소의 선언에는 "이 포트를 열지 않는다"는 설명이 주석으로
# 들어 있고, 그 설명 자체를 위반으로 읽으면 검사가 쓸모없어진다. 따옴표 안의 `#`는 없다.
#
# tests/는 제외한다. tests/safety.tftest.hcl은 이 포트들이 열렸는지 **판정하는** 쪽이라
# 단정식에 숫자가 들어 있는 것이 정상이다.
port_hits=''
for f in "$tf_dir"/*.tf; do
  [ -f "$f" ] || continue
  found=$(sed 's/#.*$//' "$f" | grep -nE "$forbidden_ports" || true)
  if [ -n "$found" ]; then
    port_hits="$port_hits
  $(basename "$f"):
$found"
  fi
done
if [ -n "$port_hits" ]; then
  fail "금지된 Kubernetes 포트가 mem-lab Terraform 선언에 있다 (API 6443 / kubelet 10250 / VXLAN 8472 / health 4240 / NodePort 30000-32767). 이 트래픽은 tailnet 안에서만 흐른다:$port_hits"
fi

# user_data와 instance profile. 둘 다 `terraform test`의 plan 단계에서는 unknown이라
# 단정할 수 없어(직접 확인했다) 여기서 텍스트로 본다. 이 방식은 새로 추가된 자원에도 걸린다.
secret_surface_hits=''
for f in "$tf_dir"/*.tf; do
  [ -f "$f" ] || continue
  found=$(sed 's/#.*$//' "$f" | grep -nE 'user_data|iam_instance_profile' || true)
  if [ -n "$found" ]; then
    secret_surface_hits="$secret_surface_hits
  $(basename "$f"):
$found"
  fi
done
if [ -n "$secret_surface_hits" ]; then
  fail "user_data 또는 iam_instance_profile 선언이 mem-lab Terraform에 있다. user_data는 IMDS로 평문 조회되고 state에도 남아 auth key·join token을 둘 자리가 아니며, instance profile은 이 노드에 AWS API 권한을 준다:$secret_surface_hits"
fi

# ── (2) GPU runtime ─────────────────────────────────────────────────────────
#
# playbooks/는 host에서 실제로 실행되는 내용이라 가장 좁게 막는다. 아래 토큰이 하나라도
# 있으면 이 트리가 가속기 노드 준비를 겸하기 시작했다는 뜻이고, 그러면 "무엇이 빠져서
# 실패했는가"를 이 노드와 가속기 노드 사이에서 구분할 수 없게 된다.
runtime_hits=$(grep -rniE 'nvidia|cuda|gpu|device-plugin' "$playbook_dir" || true)
if [ -n "$runtime_hits" ]; then
  fail "GPU runtime 토큰이 mem-lab playbook에 있다. 이 노드에는 가속기가 없고, ansible/gpu-node를 재사용하지 않는 것이 이 트리의 전제다:
$runtime_hits"
fi

# 트리 전체(README 포함)에서는 **설치·사용 도구 이름**만 막는다. 산문에서 "이 노드는
# 가속기 노드가 아니다"를 설명하는 것은 필요한 문서이므로 일반 낱말은 허용하고, 아래
# 이름들은 언급 자체가 설치로 가는 첫 걸음이라 허용하지 않는다.
artifact_hits=$(grep -rniE 'nvidia-smi|nvidia-ctk|nvidia-driver|nvidia-container-toolkit|libnvidia|nvidia\.com/gpu' "$ansible_dir" || true)
if [ -n "$artifact_hits" ]; then
  fail "GPU runtime 설치·사용 도구 이름이 mem-lab Ansible 트리에 있다:
$artifact_hits"
fi

# playbook 집합을 고정한다. gpu-node의 `30-` 자리는 의도적으로 비어 있고, 거기에 파일이
# 생기는 것이 GPU runtime 단계가 되살아나는 경로다. 파일을 더하거나 빼려면 이 목록도 함께
# 고쳐야 하므로, 조용히 늘어나지 않는다.
expected_playbooks='00-preflight.yml 10-base.yml 20-tailscale.yml 40-join-preflight.yml'
actual_playbooks=$(ls "$playbook_dir" | sort | tr '\n' ' ' | sed 's/ *$//')
if [ "$actual_playbooks" != "$expected_playbooks" ]; then
  fail "mem-lab playbook 집합이 기대와 다르다.
  기대: $expected_playbooks
  실제: $actual_playbooks"
fi

# ansible/gpu-node를 import·include로 끌어오는 경로도 막는다. 토큰 검사가 파일 내용은
# 보지만, 다른 트리를 참조하면 그 내용이 이 트리 밖에 있어 보이지 않는다.
#
# playbooks/로 한정한다. README는 "그 트리를 재사용하지 않는다"를 설명해야 하고, 그 설명을
# 위반으로 읽으면 분리 이유를 문서에 적을 수 없게 된다. 실제로 끌어오는 것은 playbook이다.
reuse_hits=$(grep -rn 'gpu-node' "$playbook_dir" || true)
if [ -n "$reuse_hits" ]; then
  fail "ansible/gpu-node를 참조한다. 그 트리를 재사용하지 않는 것이 이 디렉터리의 전제다:
$reuse_hits"
fi

# ── YAML 파싱 ────────────────────────────────────────────────────────────────
#
# 개발 환경에 ansible이 없어 `--syntax-check`를 돌릴 수 없다. 그 대신 최소한 YAML로
# 읽히는지는 확인한다. **이것은 syntax-check가 아니다** — 모듈 이름과 인자가 맞는지는
# 검사하지 않는다.
for f in "$playbook_dir"/*.yml; do
  ruby -ryaml -e '
    Encoding.default_external = Encoding::UTF_8
    path = ARGV.fetch(0)
    doc = YAML.load_file(path)
    abort "playbook이 play 목록이 아니다: #{path}" unless doc.is_a?(Array) && !doc.empty?
    doc.each do |play|
      abort "play에 tasks가 없다: #{path}" unless play.is_a?(Hash) && play.key?("tasks")
    end
  ' "$f" || fail "playbook YAML 파싱에 실패했다: $(basename "$f")"
done

if [ "$failures" -gt 0 ]; then
  echo "mem-lab 선언 검사 실패: ${failures}건" >&2
  exit 1
fi
echo "mem-lab 선언 검사 통과 (public Kubernetes port 없음 / GPU runtime 없음 / playbook 집합 일치 / YAML 파싱 가능)"
