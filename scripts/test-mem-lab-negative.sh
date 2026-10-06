#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 결함을 넣어 mem-lab 검사가 실패하는지 확인한다.
#
# 왜 필요한가: "검사를 추가했다"와 "그 검사가 결함을 잡는다"는 다르다. 조건이 잘못 쓰인
# 단정은 결함이 있어도 조용히 통과하며, 그 상태는 검사가 아예 없는 것보다 나쁘다 —
# 통과 기록이 안전하다는 증거로 읽힌다. 그래서 각 사례가 **두 가지를 모두** 확인한다.
#   (1) 결함을 넣으면 검사가 실제로 실패하는가
#   (2) 실패한 이유가 기대한 그 이유인가 (엉뚱한 오류로 실패한 것을 검출로 세지 않는다)
#
# 두 계층을 나눠 검사한다.
#   - 정적 검사(validate-mem-lab-declarations.sh): 선언 파일의 텍스트를 본다. 자원 이름과
#     무관하게 걸리지만, 값의 의미는 모른다.
#   - terraform test: 계획된 자원의 실제 값을 본다. 의미를 보지만, 자신이 아는 자원만 본다.
# 마지막 사례가 그 사각지대를 실제로 보여 준다.
#
# 이 스크립트는 AWS에 접속하지 않고 자원을 만들지 않는다(terraform test는 mock_provider를 쓴다).
set -eu

for tool in terraform ruby mktemp cp rm mkdir sed grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-mem-lab.XXXXXX")
# 이 실행이 만든 복사본만 제거한다. 원본 트리와 클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

mkdir -p "$test_dir/terraform/envs" "$test_dir/ansible" "$test_dir/scripts"
# `.terraform`까지 함께 복사된다. 복사본에서 provider를 다시 내려받지 않으려는 것이다.
cp -R "$repo_dir/terraform/envs/mem-lab" "$test_dir/terraform/envs/"
cp -R "$repo_dir/ansible/mem-lab-worker" "$test_dir/ansible/"
cp "$repo_dir/scripts/validate-mem-lab-declarations.sh" "$test_dir/scripts/"

tf_dir="$test_dir/terraform/envs/mem-lab"
playbook_dir="$test_dir/ansible/mem-lab-worker/playbooks"
main_tf="$tf_dir/main.tf"
log="$test_dir/result.log"
backup="$test_dir/backup.orig"
detected=0

# provider가 복사되지 않았다면(원본에서 init을 돌린 적이 없는 깨끗한 clone) 여기서 준비한다.
if [ ! -d "$tf_dir/.terraform" ]; then
  echo "복사본에 provider가 없어 init을 실행한다 (네트워크가 필요하다)"
  (cd "$tf_dir" && terraform init -backend=false -input=false >/dev/null)
fi

run_validator() {
  sh "$test_dir/scripts/validate-mem-lab-declarations.sh" >"$log" 2>&1
}

run_tf_test() {
  (cd "$tf_dir" && terraform test -no-color) >"$log" 2>&1
}

# 먼저 결함이 없는 복사본이 두 검사를 통과하는지 본다. 여기서 실패하면 이후 사례의
# "실패했다"가 결함 때문인지 복사 때문인지 구분할 수 없다.
run_validator || { echo "기준 상태에서 정적 검사가 실패했다" >&2; cat "$log" >&2; exit 1; }
echo "기준: 정적 검사 통과"
run_tf_test || { echo "기준 상태에서 terraform test가 실패했다" >&2; cat "$log" >&2; exit 1; }
echo "기준: terraform test 통과"

# $1 사례 이름, $2 기대 문구, $3 실행할 함수 이름
assert_detected() {
  if "$3"; then
    echo "누락: $1 — 검사가 결함을 놓쳤다(통과했다)" >&2
    exit 1
  fi
  if ! grep -qF "$2" "$log"; then
    echo "오탐: $1 — 검사가 실패했지만 기대한 이유가 아니다" >&2
    echo "기대 문구: $2" >&2
    sed -n '1,40p' "$log" >&2
    exit 1
  fi
  echo "검출: $1"
  detected=$((detected + 1))
}

# ── 정적 검사 계층 ──────────────────────────────────────────────────────────

cp "$main_tf" "$backup"
cat >>"$main_tf" <<'EOF'
resource "aws_vpc_security_group_ingress_rule" "injected_api" {
  security_group_id = aws_security_group.mem.id
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = "0.0.0.0/0"
}
EOF
assert_detected "public API 6443 ingress 추가" "금지된 Kubernetes 포트" run_validator
cp "$backup" "$main_tf"

cat >>"$main_tf" <<'EOF'
resource "aws_vpc_security_group_ingress_rule" "injected_nodeport" {
  security_group_id = aws_security_group.mem.id
  ip_protocol       = "tcp"
  from_port         = 30000
  to_port           = 32767
  cidr_ipv4         = "0.0.0.0/0"
}
EOF
assert_detected "public NodePort 대역 ingress 추가" "금지된 Kubernetes 포트" run_validator
cp "$backup" "$main_tf"

# NodePort 대역 검사가 대역 **안쪽** 부분 구간도 잡는지 따로 본다. 대표값만 보는 검사라면
# 여기서 놓친다.
cat >>"$main_tf" <<'EOF'
resource "aws_vpc_security_group_ingress_rule" "injected_partial_nodeport" {
  security_group_id = aws_security_group.mem.id
  ip_protocol       = "tcp"
  from_port         = 31500
  to_port           = 31501
  cidr_ipv4         = "0.0.0.0/0"
}
EOF
assert_detected "NodePort 대역 안쪽 부분 구간 ingress 추가" "금지된 Kubernetes 포트" run_validator
cp "$backup" "$main_tf"

cat >>"$main_tf" <<'EOF'
resource "aws_instance" "injected_with_user_data" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3a.medium"
  user_data     = "#!/bin/sh\necho placeholder"
}
EOF
assert_detected "user_data 선언 추가" "user_data 또는 iam_instance_profile" run_validator
cp "$backup" "$main_tf"

cat >>"$main_tf" <<'EOF'
resource "aws_instance" "injected_with_profile" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3a.medium"
  iam_instance_profile = "some-profile"
}
EOF
assert_detected "instance profile 선언 추가" "user_data 또는 iam_instance_profile" run_validator
cp "$backup" "$main_tf"
rm -f "$backup"

# 주석으로 적힌 "이 포트를 열지 않는다"를 위반으로 읽지 않는지 확인한다. 이 검사가 없으면
# 위 사례들을 통과시키려고 설명 주석을 지우는 방향으로 흐를 수 있다.
cp "$main_tf" "$backup"
cat >>"$main_tf" <<'EOF'
# 주석 안의 6443, 10250, 8472, 4240, 30000-32767은 위반이 아니다.
EOF
run_validator || { echo "오탐: 주석에 적힌 포트 번호를 위반으로 읽었다" >&2; cat "$log" >&2; exit 1; }
echo "확인: 주석의 포트 번호는 위반으로 읽지 않는다"
cp "$backup" "$main_tf"
rm -f "$backup"

preflight="$playbook_dir/40-join-preflight.yml"
cp "$preflight" "$backup"
cat >>"$preflight" <<'EOF'
# 주입된 사례: 이 트리가 가속기 도구를 전제하기 시작하는 경로다.
    - name: injected accelerator check
      ansible.builtin.command:
        cmd: nvidia-smi --query-gpu=name --format=csv,noheader
      changed_when: false
EOF
assert_detected "playbook에 GPU runtime task 추가" "GPU runtime 토큰" run_validator
cp "$backup" "$preflight"
rm -f "$backup"

# gpu-node를 끌어오는 경로. 토큰 검사만 있으면 내용이 다른 트리에 있어 보이지 않는다.
cp "$preflight" "$backup"
cat >>"$preflight" <<'EOF'
    - name: injected reuse
      ansible.builtin.import_playbook: ../../gpu-node/playbooks/30-gpu-runtime.yml
EOF
assert_detected "gpu-node 트리 참조 추가" "GPU runtime 토큰" run_validator
cp "$backup" "$preflight"
rm -f "$backup"

# `30-` 자리에 파일이 생기는 것이 runtime 단계가 되살아나는 경로다. 내용에는 금지 토큰을
# 넣지 않아, 파일 집합 검사만 걸리는 것을 확인한다.
cat >"$playbook_dir/30-extra-stage.yml" <<'EOF'
---
- name: Injected extra stage
  hosts: mem_lab_nodes
  tasks:
    - name: placeholder
      ansible.builtin.debug:
        msg: injected
EOF
assert_detected "playbook 집합에 30- 단계 추가" "playbook 집합이 기대와 다르다" run_validator
rm -f "$playbook_dir/30-extra-stage.yml"

cp "$preflight" "$backup"
printf '\n  this is not: valid: yaml: at all\n' >>"$preflight"
assert_detected "playbook YAML 훼손" "playbook YAML 파싱에 실패했다" run_validator
cp "$backup" "$preflight"
rm -f "$backup"

# ── terraform test 계층 ─────────────────────────────────────────────────────
#
# 여기서는 **이미 선언된** 자원의 값을 바꾼다. 그것이 terraform test가 볼 수 있는 범위다.

cp "$main_tf" "$backup"
sed 's/from_port         = 22/from_port         = 6443/; s/to_port           = 22/to_port           = 6443/' "$backup" >"$main_tf"
assert_detected "기존 SSH 규칙의 포트를 6443으로 변경" "covers a Kubernetes port" run_tf_test
cp "$backup" "$main_tf"

sed 's/from_port         = 22/from_port         = 30000/; s/to_port           = 22/to_port           = 32767/' "$backup" >"$main_tf"
assert_detected "기존 SSH 규칙의 포트를 NodePort 대역으로 변경" "overlaps the NodePort range" run_tf_test
cp "$backup" "$main_tf"

sed 's/mem_instance_type   = "t3a.medium"/mem_instance_type   = "t3a.large"/' "$backup" >"$main_tf"
assert_detected "인스턴스를 8 GiB(t3a.large)로 변경" "cannot reach MemoryPressure" run_tf_test
cp "$backup" "$main_tf"

sed 's/cpu_credits = "standard"/cpu_credits = "unlimited"/' "$backup" >"$main_tf"
assert_detected "CPU credit을 unlimited로 변경" "CPU credits must stay standard" run_tf_test
cp "$backup" "$main_tf"

sed 's/volume_size           = local.mem_root_volume_gib/volume_size           = 8/' "$backup" >"$main_tf"
assert_detected "루트 볼륨을 30 GiB에서 축소" "Encrypted gp3 30 GiB is required" run_tf_test
cp "$backup" "$main_tf"

sed 's/http_tokens   = "required"/http_tokens   = "optional"/' "$backup" >"$main_tf"
assert_detected "IMDSv2를 optional로 완화" "IMDSv2 required" run_tf_test
cp "$backup" "$main_tf"

sed 's/http_put_response_hop_limit = 1/http_put_response_hop_limit = 2/' "$backup" >"$main_tf"
assert_detected "metadata hop limit을 2로 완화" "hop limit 1" run_tf_test
cp "$backup" "$main_tf"

# 겹침 게이트를 무력화하는 방향. 계산식을 항상 거짓으로 만들면 어떤 후보도 겹침으로
# 보이지 않는다. 기대하는 실패는 단정 실패가 아니라 `expect_failures`의 "막혀야 하는데
# 막히지 않았다"다 — 네 개의 겹침 사례가 전부 그 형태로 걸린다.
sed 's/if local.cidr_start\[var.vpc_cidr\] </if false \&\& local.cidr_start[var.vpc_cidr] </' "$backup" >"$main_tf"
assert_detected "CIDR 겹침 계산을 무력화" "Missing expected failure" run_tf_test
cp "$backup" "$main_tf"

# ── 두 계층이 왜 함께 필요한가 (사각지대를 실제로 보여 준다) ────────────────
#
# 새 **이름**으로 선언된 ingress 자원은 terraform test가 열거할 수 없어 그냥 통과한다.
# 아래는 그것이 실제로 그렇다는 것을 기록으로 남긴다. 이 사례가 통과하는 것은 결함이
# 아니라 terraform test의 한계이며, 그래서 정적 검사를 따로 둔다(위 첫 사례가 같은 결함을
# 잡는다). 이 사례가 어느 날 실패하면 terraform test가 강해졌다는 뜻이고, 그때 정적 검사의
# 필요성을 다시 판단한다.
cat >>"$main_tf" <<'EOF'
resource "aws_vpc_security_group_ingress_rule" "injected_vxlan" {
  security_group_id = aws_security_group.mem.id
  ip_protocol       = "udp"
  from_port         = 8472
  to_port           = 8472
  cidr_ipv4         = "0.0.0.0/0"
}
EOF
if run_tf_test; then
  echo "확인: 새 이름의 ingress 자원은 terraform test가 보지 못한다(알려진 한계) — 정적 검사가 이것을 잡는다"
else
  echo "참고: terraform test가 새 이름의 ingress 자원까지 잡았다. 한계가 사라졌다면 정적 검사와의 역할 분담을 다시 검토한다"
fi
assert_detected "새 이름의 VXLAN 8472 ingress 자원 추가(정적 검사가 잡는다)" "금지된 Kubernetes 포트" run_validator
cp "$backup" "$main_tf"
rm -f "$backup"

# 마지막으로 원복된 복사본이 다시 통과하는지 확인한다. 통과하지 않으면 위 사례 중 하나가
# 복원되지 않은 것이고, 그러면 앞의 검출 결과를 신뢰할 수 없다.
run_validator || { echo "원복 후 정적 검사가 실패했다 — 사례 복원이 불완전하다" >&2; cat "$log" >&2; exit 1; }
run_tf_test || { echo "원복 후 terraform test가 실패했다 — 사례 복원이 불완전하다" >&2; cat "$log" >&2; exit 1; }
echo "원복: 두 검사 모두 다시 통과"

echo "mem-lab 음성 테스트 ${detected}건 통과"
