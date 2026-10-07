#!/usr/bin/env bash
# scripts/inventory/persona_retire.sh를 가짜 kubectl로 돌려 세 가지를 확인한다. 클러스터에 닿지 않는다.
#   1) 정상 흐름: exit 0, manifest·참조 요약 생성, 지울/지킬 판단 재료가 요약에 나온다
#   2) 실패 전파: context 불일치는 exit 2, required 조회 실패는 exit 1
#   3) 누출 방지: Secret 값을 읽는 호출(-o yaml/json, describe)을 하지 않고, 결과에 공인 IP가 섞이면 exit 3
set -eu
command -v ruby > /dev/null 2>&1 || { echo "필요한 도구가 없습니다: ruby" >&2; exit 1; }
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/inventory-retire-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

mkdir "$work/bin"
cat > "$work/bin/kubectl" << 'FAKE'
#!/usr/bin/env bash
# 합성 응답만 돌려준다. 호출 인자는 calls.log에 남겨 금지 호출이 있었는지 나중에 본다.
echo "$*" >> "$FAKE_CALLS"
args="$*"
case "$args" in
  *"config current-context"*) echo "${FAKE_CONTEXT:-kubernetes-admin@kubernetes}"; exit 0 ;;
  *"config view"*) echo "https://k8s-cp.internal:6443"; exit 0 ;;
esac
# 실패 주입: 이름이 맞는 조회 하나를 실패시킨다.
if [ -n "${FAKE_FAIL:-}" ] && [[ "$args" == *"$FAKE_FAIL"* ]]; then echo "synthetic failure" >&2; exit 1; fi
case "$args" in
  *"get applications.argoproj.io -o json"*)
    echo '{"items":[{"metadata":{"name":"public-gateway"},"status":{"resources":[{"group":"gateway.networking.k8s.io","kind":"Gateway","namespace":"persona-app","name":"persona-app","status":"Synced"}]}}]}' ;;
  *"get httproutes.gateway.networking.k8s.io -A -o json"*)
    echo '{"items":[{"metadata":{"namespace":"persona-app","name":"persona-app-public"},"spec":{"parentRefs":[{"name":"persona-app","sectionName":"https"}],"hostnames":["app.example.invalid"],"rules":[{"backendRefs":[{"name":"persona-web","port":8080}]}]},"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True"}]}]}}]}' ;;
  *"get referencegrants"*"-o json"*)
    echo '{"items":[{"metadata":{"namespace":"persona-edge","name":"persona-app-httproute-to-oauth2-proxy"},"spec":{"from":[{"namespace":"persona-app","kind":"HTTPRoute"}],"to":[{"kind":"Service","name":"oauth2-proxy"}]}}]}' ;;
  *"get networkpolicies -A -o json"*)
    echo '{"items":[{"metadata":{"namespace":"persona-inference","name":"allow-vllm-gateway"},"spec":{"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"persona-app"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"persona-gateway"}}}]}]}}]}' ;;
  *"get pv -o json"*)
    echo "{\"items\":[{\"metadata\":{\"name\":\"pvc-db-1\"},\"spec\":{\"claimRef\":{\"namespace\":\"persona-data\",\"name\":\"persona-db-1\"},\"storageClassName\":\"local-path\",\"persistentVolumeReclaimPolicy\":\"Retain\",\"hostPath\":{\"path\":\"/opt/local-path-provisioner/pvc-db-1\"},\"capacity\":{\"storage\":\"20Gi\"},\"nodeAffinity\":{\"required\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"values\":[\"k8s-worker1\"]}]}]}}},\"status\":{\"phase\":\"Bound\"}},{\"metadata\":{\"name\":\"pvc-model\"},\"spec\":{\"claimRef\":{\"namespace\":\"persona-inference\",\"name\":\"persona-vllm-model-cache\"},\"storageClassName\":\"local-path\",\"persistentVolumeReclaimPolicy\":\"Delete\",\"capacity\":{\"storage\":\"40Gi\"}},\"status\":{\"phase\":\"Bound\"}}]}" ;;
  *"get pods -A -o json"*)
    echo '{"items":[{"metadata":{"namespace":"persona-app"},"spec":{"nodeName":"k8s-worker1","containers":[{"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]},"status":{"phase":"Running"}}]}' ;;
  *"get pvc -A"*)
    printf 'NAMESPACE NAME SC VOLUME PHASE\npersona-data persona-db-1 local-path pvc-db-1 Bound\npersona-inference persona-vllm-model-cache local-path pvc-model Bound\n' ;;
  *"get gateway.gateway.networking.k8s.io persona-app"*)
    printf 'NAME UID PROGRAMMED TRACKING\npersona-app 00000000-0000-4000-8000-000000000001 True public-gateway:gateway.networking.k8s.io/Gateway:persona-app/persona-app\n' ;;
  *"get secret persona-app-tls"*)
    printf 'NAME TYPE UID\npersona-app-tls kubernetes.io/tls 00000000-0000-4000-8000-000000000003\n' ;;
  # 고르지 않은 필드는 원래 안 나온다. 누출 검사를 확인하려고 custom-columns 응답에 값을 섞는다.
  *) printf 'NAME\nsynthetic %s\n' "${FAKE_LEAK:-}" ;;
esac
FAKE
chmod +x "$work/bin/kubectl"

run_inventory() {  # 출력 폴더, 추가 환경 변수...
  local out="$1"
  shift
  : > "$work/calls.log"
  env FAKE_CALLS="$work/calls.log" PERSONA_RETIRE_KUBECTL="$work/bin/kubectl" PERSONA_RETIRE_OUTPUT_ROOT="$out" "$@" \
    bash "$repo_dir/scripts/inventory/persona_retire.sh" > "$work/stdout.txt" 2> "$work/stderr.txt"
}

fail() { echo "테스트 실패: $*" >&2; cat "$work/stderr.txt" >&2 || true; exit 1; }

# 1) 정상 흐름
status=0; run_inventory "$work/ok" || status=$?
[ "$status" -eq 0 ] || fail "정상 흐름이 exit ${status}로 끝났다"
run_dir=$(ls -d "$work/ok"/retire-*)
for file in 00_run_info.txt manifest.tsv 90_references.txt gateway_identity.txt persistent_volumes.txt node_requests.txt; do
  [ -f "$run_dir/$file" ] || fail "${file}이 없다"
done
grep -q "claim=persona-data/persona-db-1" "$run_dir/90_references.txt" || fail "지울 후보 PV가 요약에 없다"
grep -q "reclaim=Retain" "$run_dir/90_references.txt" || fail "PV reclaim 정책이 요약에 없다"
grep -q "claim=persona-inference/persona-vllm-model-cache" "$run_dir/90_references.txt" || fail "지킬 모델 캐시 PV가 요약에 없다"
grep -q "allow-vllm-gateway" "$run_dir/90_references.txt" || fail "persona-app을 가리키는 다른 namespace 정책이 요약에 없다"
grep -q "nfs-shared·NFS CSI 사용: PV 0개 · PVC 0개" "$run_dir/90_references.txt" || fail "NFS 사용 집계가 없다"
echo "통과: 정상 흐름(exit 0, 요약에 지울·지킬 재료)"

# 3-a) Secret 값을 읽는 호출을 하지 않는다
if grep -E "get secret.*-o (yaml|json)|describe|-o json.*secret|get [a-z,]*secret[a-z,]* .*-o (yaml|json)" "$work/calls.log" > /dev/null; then
  fail "Secret 본문을 읽는 호출이 있다"
fi
if grep -E "(^| )(apply|delete|patch|exec|edit|port-forward|scale)( |$)" "$work/calls.log" > /dev/null; then
  fail "변경 호출이 있다"
fi
echo "통과: Secret 본문·변경 호출 없음"

# 2-a) context 불일치는 설정 오류(2)이고 run 디렉터리를 만들지 않는다
status=0; run_inventory "$work/ctx" FAKE_CONTEXT=minikube || status=$?
[ "$status" -eq 2 ] || fail "context 불일치가 exit ${status}였다(기대 2)"
[ ! -d "$work/ctx" ] || [ -z "$(ls -A "$work/ctx" 2> /dev/null)" ] || fail "context 불일치인데 결과를 만들었다"
echo "통과: context 불일치 → exit 2"

# 2-b) required 조회 실패는 exit 1(실패를 빈 값으로 바꾸지 않는다)
status=0; run_inventory "$work/fail" FAKE_FAIL="get pvc -A" || status=$?
[ "$status" -eq 1 ] || fail "required 조회 실패가 exit ${status}였다(기대 1)"
grep -q "^persistent_volume_claims	required	1" "$(ls -d "$work/fail"/retire-*)/manifest.tsv" || fail "manifest에 실패가 남지 않았다"
echo "통과: required 실패 → exit 1"

# 3-b) 결과에 공인 IP가 섞이면 exit 3, 값은 출력하지 않는다
status=0; run_inventory "$work/leak" FAKE_LEAK="203.0.113.7" || status=$?
[ "$status" -eq 3 ] || fail "공인 IP가 섞였는데 exit ${status}였다(기대 3)"
grep -q "203.0.113.7" "$work/stderr.txt" "$work/stdout.txt" && fail "누출 경고가 값 자체를 출력했다"
echo "통과: 공인 IP 누출 → exit 3(값 미출력)"

echo "인벤토리 테스트 5건 통과"
