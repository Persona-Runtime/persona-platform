#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 과거 설정을 넣어 회귀 검사가 실패하는지 확인한다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/persona-scheduling.XXXXXX")
# 이 실행이 만든 복사본만 제거하며 원본·클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$repo_dir/bootstrap" "$repo_dir/db" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-persona-app-manifests.sh" "$test_dir/scripts/"
sh "$test_dir/scripts/validate-persona-app-manifests.sh"

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
#
# heredoc로 넘긴 Ruby 소스는 파일이 아니라 stdin이라, 로케일이 UTF-8이 아니면(LC_ALL=C,
# cron 등) US-ASCII로 파싱돼 아래 한글 사례 이름에서 "invalid multibyte char"로 즉시 죽는다.
# 매직 코멘트는 반드시 첫 줄이어야 하며, 고치는 것은 이 소스의 인코딩뿐이다.
# 아래 Encoding.default_external은 다른 문제를 푼다 — 이 스크립트는 한글이 든 매니페스트를
# File.read로 읽고 다시 File.write로 쓰므로, 외부 인코딩이 US-ASCII면 파싱을 넘겨도
# 쓰기에서 Encoding::UndefinedConversionError가 난다.
Encoding.default_external = Encoding::UTF_8

root = ARGV.fetch(0)
# 값 자리에 이 표식을 두면 값을 바꾸는 대신 그 키를 지운다. "빈 값"과 "선언 누락"은 validator가
# 다르게 읽을 수 있으므로(nil·[] 처리) 누락 사례는 실제로 키를 지워 재현한다.
DELETE_KEY = :delete_key
GATEWAY_DEPLOYMENT = "kustomize/base/persona-gateway/deployment.yaml"
GATEWAY_PDB = "kustomize/base/persona-gateway/pdb.yaml"
# 각 사례는 원래 파일로 되돌린 뒤 다음 사례를 실행한다. 검증 실패뿐 아니라 의도한 오류도 확인한다.
cases = [
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "priorityClassName"], "persona-critical", "DB: 커스텀 PriorityClass"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "instances"], 1, "기준선(2)"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "affinity", "nodeSelector"], { "kubernetes.io/hostname" => "k8s-worker1" }, "옛 worker1 전용 nodeSelector"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values"], ["k8s-worker1"], "두 홈 워커(k8s-worker1, k8s-worker2)만 노드 후보"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values"], ["k8s-worker1", "k8s-worker2", "k8s-cp"], "두 홈 워커(k8s-worker1, k8s-worker2)만 노드 후보"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "affinity", "podAntiAffinityType"], "preferred", "preferred로 약화"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "affinity", "topologyKey"], "topology.kubernetes.io/zone", "anti-affinity topologyKey가 다르다"],
  ["kustomize/base/persona-db/cluster.yaml", ["spec", "affinity", "enablePodAntiAffinity"], false, "필수 anti-affinity를 켜야 한다"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "template", "spec", "priorityClassName"], "persona-low", "Gateway: 커스텀 PriorityClass"],
  ["kustomize/base/persona-web/deployment.yaml", ["spec", "template", "spec", "priorityClassName"], "persona-low", "Web: 커스텀 PriorityClass"],
  ["bootstrap/traefik/values.yaml", ["priorityClassName"], "persona-low", "Traefik: 커스텀 PriorityClass"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "strategy", "type"], "Recreate", "Gateway는 RollingUpdate"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "strategy", "rollingUpdate", "maxSurge"], 0, "Gateway maxSurge는 1"],
  ["kustomize/base/persona-gateway/deployment.yaml", ["spec", "strategy", "rollingUpdate", "maxUnavailable"], 1, "Gateway maxUnavailable은 0"],
  # Gateway PodMonitor — 수집 계약을 약화·우회하는 세 가지만 고른다.
  # (1) 간격을 줄여 기준선을 벗어나는 것, (2) selector를 matchExpressions로 바꿔
  # /metrics가 없는 Pod까지 대상에 넣는 것, (3) 포트 이름 대신 숫자를 박아
  # Deployment의 포트 이름과의 연결을 끊는 것.
  ["kustomize/base/persona-gateway/podmonitor.yaml", ["spec", "podMetricsEndpoints", 0, "interval"], "5s", "Gateway PodMonitor scrape interval이 기준선(30s)과 다르다"],
  ["kustomize/base/persona-gateway/podmonitor.yaml", ["spec", "selector"], { "matchExpressions" => [{ "key" => "app.kubernetes.io/part-of", "operator" => "In", "values" => ["persona-platform"] }] }, "matchExpressions로 대상을 넓히지 않는다"],
  ["kustomize/base/persona-gateway/podmonitor.yaml", ["spec", "podMetricsEndpoints", 0, "port"], 8080, "Gateway PodMonitor 포트는 숫자가 아니라 이름(http)이어야 한다"],
  # Gateway HA(replica 2·PDB·hostname 분산) — G-1 이후 기준선이 조용히 약해지는 경로를 막는다.
  # replica 1로 돌아가면 PDB minAvailable 1이 drain을 영원히 막는다.
  [GATEWAY_DEPLOYMENT, ["spec", "replicas"], 1, "Gateway replica가 기준선(2)과 다르다"],
  # PDB 파일은 남아도 kustomization에서 빠지면 렌더되지 않는다 — 실제로 흔한 누락 경로다.
  ["kustomize/base/persona-gateway/kustomization.yaml", ["resources"], ["deployment.yaml", "service.yaml", "podmonitor.yaml"], "persona-app PDB가 정확히 1개(Gateway)여야 한다: 0개"],
  [GATEWAY_PDB, ["spec", "minAvailable"], 2, "Gateway PDB minAvailable은 정수 1이다"],
  [GATEWAY_PDB, ["spec", "minAvailable"], "50%", "Gateway PDB minAvailable은 정수 1이다"],
  # 네임스페이스 전체(part-of) selector — Web Pod까지 묶어 보호 대상이 틀어진다.
  [GATEWAY_PDB, ["spec", "selector"], { "matchLabels" => { "app.kubernetes.io/part-of" => "persona-platform" } }, "Gateway PDB selector는 app.kubernetes.io/name=persona-gateway 하나여야 한다"],
  [GATEWAY_PDB, ["spec", "selector"], {}, "Gateway PDB selector는 app.kubernetes.io/name=persona-gateway 하나여야 한다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints"], DELETE_KEY, "Gateway topologySpreadConstraints가 정확히 1개여야 한다: 0개"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "labelSelector"], {}, "Gateway topology spread labelSelector는 app.kubernetes.io/name=persona-gateway 하나여야 한다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "labelSelector"], { "matchLabels" => { "app.kubernetes.io/part-of" => "persona-platform" } }, "Gateway topology spread labelSelector는 app.kubernetes.io/name=persona-gateway 하나여야 한다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "whenUnsatisfiable"], "ScheduleAnyway", "Gateway topology spread는 DoNotSchedule이다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "maxSkew"], 2, "Gateway topology spread maxSkew는 1이다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "topologyKey"], "topology.kubernetes.io/zone", "Gateway topology spread key는 kubernetes.io/hostname이다"],
  # 워커 하나가 cordon·NotReady일 때 남은 워커로 옮기는 동작을 되돌리는 경로들.
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "nodeTaintsPolicy"], "Ignore", "Gateway topology spread nodeTaintsPolicy는 Honor다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "nodeTaintsPolicy"], DELETE_KEY, "Gateway topology spread nodeTaintsPolicy는 Honor다"],
  [GATEWAY_DEPLOYMENT, ["spec", "template", "spec", "topologySpreadConstraints", 0, "minDomains"], 2, "Gateway topology spread에 minDomains를 두지 않는다"],
  # 적용이 끝나 history/로 옮긴 Job을 다시 연결하면 Job 수는 1이라 개수 검사를 통과한다.
  # 경로 검사가 막는지 본다(완료된 0005 Job을 되살리는 경로).
  ["kustomize/base/persona-migrate/kustomization.yaml", ["resources"], ["history/job-0005-generation-lease.yaml"], "history/의 과거 선언을 활성 렌더에 연결했다"],
]
# migration Job 사례는 **활성 렌더에 연결된 파일**에서 뽑는다. 경로를 고정하면 다음 배포에서
# 다른 Job이 활성화됐을 때 이 검사가 렌더되지 않는 파일을 건드리며 조용히 통과한다.
#
# 기대 문구에 Job 이름이 들어간다. 검증 스크립트가 Job마다 라벨을 따로 붙이기 때문이며,
# 이름 없는 문구로 두면 어느 Job이 걸렸는지 구분하지 못한다.
migrate_base = YAML.load_file(File.join(root, "kustomize/base/persona-migrate/kustomization.yaml"))
(migrate_base["resources"] || []).each do |entry|
  relative_path = File.join("kustomize/base/persona-migrate", entry.to_s)
  job_name = YAML.load_file(File.join(root, relative_path)).dig("metadata", "name")
  cases << [relative_path, ["spec", "template", "spec", "priorityClassName"], "persona-low",
            "migration Job #{job_name}: 커스텀 PriorityClass"]
end
if (migrate_base["resources"] || []).empty?
  # 통과로 세지 않는다. 적용할 migration이 없는 평시 상태이며, Job을 연결하면 사례가 다시 생긴다.
  puts "건너뜀: migration Job PriorityClass — 활성 렌더에 migration Job이 없다"
end

cases.each do |relative_path, keys, value, message|
  path = File.join(root, relative_path)
  original = File.read(path)
  begin
    document = YAML.load(original)
    parent = keys[0...-1].reduce(document) { |node, key| node.fetch(key) }
    if value == DELETE_KEY
      parent.delete(keys.last)
    else
      parent[keys.last] = value
    end
    File.write(path, YAML.dump(document))
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-persona-app-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{message}" if success
    raise "예상과 다른 검사 오류다: #{message}" unless File.read(output_path).include?(message)
    puts "검출: #{message}"
  ensure
    File.write(path, original)
  end
end
puts "스케줄링 음성 테스트 #{cases.length}건 통과"
RUBY
