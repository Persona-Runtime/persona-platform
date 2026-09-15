# 렌더 결과의 운영 경계를 검사한다. 예외나 입력 누락은 성공으로 숨기지 않는다.
require 'yaml'
require 'open3'

def require_rule(condition, message)
  raise message unless condition
end

def validate(documents)
  sc = documents.find { |d| d['kind'] == 'StorageClass' }
  require_rule(sc && sc.dig('metadata', 'name') == 'nfs-shared', 'SC 이름')
  require_rule(sc.dig('metadata', 'annotations', 'storageclass.kubernetes.io/is-default-class') == 'false', '비기본 SC')
  require_rule(sc['reclaimPolicy'] == 'Retain' && sc.dig('parameters', 'onDelete') == 'retain', '데이터 보존')
  require_rule(sc['provisioner'] == 'nfs.csi.k8s.io', 'NFS 드라이버')
  require_rule(sc.dig('parameters', 'server') == '192.168.50.205' && sc.dig('parameters', 'share') == '/srv/nfs/k8s', '서버 계약')
  require_rule(sc.dig('parameters', 'mountPermissions') == '0', '자동 chmod 금지')
  require_rule(sc['mountOptions'] == ['nfsvers=4.1', 'hard'], '마운트 옵션')
  require_rule(sc['allowVolumeExpansion'] == false, '자동 확장 보류')
  require_rule(documents.none? { |d| d['kind'] == 'CustomResourceDefinition' }, 'CRD 설치 제외')

  workloads = documents.select { |d| ['Deployment', 'DaemonSet'].include?(d['kind']) }
  require_rule(workloads.map { |d| d.dig('metadata', 'name') }.sort == ['csi-nfs-controller', 'csi-nfs-node'], 'CSI 구성 수')
  workloads.each do |workload|
    spec = workload.fetch('spec').fetch('template').fetch('spec')
    terms = spec.dig('affinity', 'nodeAffinity', 'requiredDuringSchedulingIgnoredDuringExecution', 'nodeSelectorTerms')
    expected = [{ 'matchExpressions' => [{ 'key' => 'kubernetes.io/hostname', 'operator' => 'In', 'values' => ['k8s-worker1', 'k8s-worker2'] }] }]
    require_rule(terms == expected, '홈 워커 제한')
    require_rule(spec['hostNetwork'] == true, '워커 IP로 NFS 접근')
    require_rule(spec['priorityClassName'].to_s.empty?, '추가 우선순위 금지')
    require_rule(spec.fetch('containers').none? { |c| c['name'].include?('snapshot') }, 'snapshotter 제외')
  end

  pvc = documents.find { |d| d['kind'] == 'PersistentVolumeClaim' }
  require_rule(pvc && pvc.dig('spec', 'storageClassName') == 'nfs-shared', '테스트 PVC SC')
  require_rule(pvc.dig('spec', 'accessModes') == ['ReadWriteMany'], 'RWX 요청')
  pods = documents.select { |d| d['kind'] == 'Pod' }
  require_rule(pods.length == 2, '테스트 Pod 수')
  pods.each do |pod|
    name = pod.dig('metadata', 'name')
    spec = pod.fetch('spec')
    node = { 'nfs-writer' => 'k8s-worker1', 'nfs-reader' => 'k8s-worker2' }.fetch(name)
    require_rule(spec.dig('nodeSelector', 'kubernetes.io/hostname') == node, '실험 노드')
    require_rule(spec['automountServiceAccountToken'] == false, 'SA 토큰 제외')
    security = spec.fetch('securityContext')
    require_rule(security.values_at('runAsUser', 'runAsGroup') == [10001, 10001] && !security.key?('fsGroup'), 'UID/GID 계약')
    require_rule(spec['restartPolicy'] == 'Never' && spec['activeDeadlineSeconds'] == 120, '테스트 종료 상한')
    container = spec.fetch('containers').fetch(0)
    require_rule(container['image'] == 'docker.io/library/busybox@sha256:7a3ebe5bfd1a4a19797d20b0c0bb39d44393e9a03fd852c0865b0f540d868df0', '테스트 이미지 digest')
    require_rule(container.dig('securityContext', 'allowPrivilegeEscalation') == false && container.dig('securityContext', 'capabilities', 'drop') == ['ALL'], '테스트 권한')
    require_rule(spec.dig('volumes', 0, 'persistentVolumeClaim', 'claimName') == pvc.dig('metadata', 'name'), '동일 PVC')
    if name == 'nfs-reader'
      require_rule(container.dig('volumeMounts', 0, 'readOnly') == true, 'reader 읽기 전용')
    end
  end
  apps = documents.select { |d| d['kind'] == 'Application' }
  require_rule(apps.length == 2, 'Argo 구성 수')
  apps.each { |app| require_rule(!app.fetch('spec').key?('syncPolicy'), '수동 Sync') }
end

paths = ARGV + Dir['tests/nfs/*.yaml'] + ['argocd/csi-driver-nfs.yaml', 'argocd/persona-nfs-storage.yaml']
documents = paths.flat_map { |path| YAML.load_stream(File.read(path)).compact }
validate(documents)
puts '정상 선언 정책 검사 통과'

# 실제 사용한 판정 함수에 결함을 주입한다. 원본 파일은 수정하지 않는다.
mutations = [
  ['StorageClass', '비기본 SC', ->(d) { d['metadata']['annotations']['storageclass.kubernetes.io/is-default-class'] = 'true' }],
  ['StorageClass', '데이터 보존', ->(d) { d['reclaimPolicy'] = 'Delete' }],
  ['StorageClass', '서버 계약', ->(d) { d['parameters']['server'] = 'CHANGE_ME' }],
  ['Deployment', '홈 워커 제한', ->(d) { d['spec']['template']['spec'].delete('affinity') }],
  ['Deployment', '워커 IP로 NFS 접근', ->(d) { d['spec']['template']['spec']['hostNetwork'] = false }],
  ['Pod', '테스트 이미지 digest', ->(d) { d['spec']['containers'][0]['image'] = 'busybox:latest' }],
  ['Pod', 'UID/GID 계약', ->(d) { d['spec']['securityContext']['fsGroup'] = 10001 }],
  ['Application', '수동 Sync', ->(d) { d['spec']['syncPolicy'] = { 'automated' => {} } }]
]
mutations.each do |kind, expected, mutate|
  changed = Marshal.load(Marshal.dump(documents))
  mutate.call(changed.find { |d| d['kind'] == kind })
  begin
    validate(changed)
  rescue StandardError => error
    raise unless error.message == expected
    next
  end
  raise "음성 검사 미검출: #{expected}"
end
puts "음성 검사 #{mutations.length}건 통과"
documents.select { |d| d['kind'] == 'Pod' }.each do |pod|
  script = pod.fetch('spec').fetch('containers').fetch(0).fetch('args').fetch(0)
  _, status = Open3.capture2e('sh', '-n', stdin_data: script)
  require_rule(status.success?, 'Pod 셸 문법')
end
puts 'Pod 셸 문법 검사 통과'
