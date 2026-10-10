# Grafana 실험 관측 대시보드 (배포 사본)

| ConfigMap | UID | 내용 |
|---|---|---|
| `persona-dashboard-vllm-serving` | `persona-vllm` | vLLM TTFT·처리량·대기열·KV·prefix cache |
| `persona-dashboard-gpu-dcgm` | `persona-gpu` | GPU 사용률·VRAM·온도·전력·클럭 |
| `persona-dashboard-postgres-cnpg` | `persona-cnpg` | mafest-db 상태·연결·트랜잭션·복제 |
| `persona-dashboard-mafest-service` | `persona-mafest` | 검색 상태·LLM 결과·DB 복구·Pod 상태 |

- **정본은 persona-ops-lab `dashboards/`** 이다. 여기 JSON과 `SOURCE.sha256`은 `scripts/check_dashboards.py --export`로 생성한 사본이며 직접 고치지 않는다.
  출처·수정 내역·지표 대응표·실험별 관측 대응표는 ops-lab의 `dashboards/PROVENANCE.md`, `METRICS.md`, `EXPERIMENTS.md`.
- 로딩 방식: monitoring-stack(kube-prometheus-stack 89.2.0)의 Grafana sidecar가 모든 namespace의 라벨 `grafana_dashboard: "1"` ConfigMap을 읽는다
  (렌더로 확인한 차트 기본값: `LABEL=grafana_dashboard`, `LABEL_VALUE=1`, `NAMESPACE=ALL`). 기본 Kubernetes 대시보드(태그 `kubernetes-mixin`)는 덮어쓰지 않는다 — 이 대시보드 UID는 모두 `persona-` 접두사다.
- 연결: `argocd/monitoring-stack.yaml`의 `ref: values` Git source에 `path: kustomize/overlays/prod/grafana-dashboards`를 지정해 같은 Application이 이 ConfigMap도 렌더한다.
  차트 revision(89.2.0)·values 파일·수동 Sync·`ServerSideApply=true`는 그대로다. Grafana는 emptyDir라 Pod가 다시 뜨면 sidecar가 다시 로드한다(PVC 추가 없음).
- 검사: `sh scripts/validate-grafana-dashboards.sh`, 음성 테스트 `sh scripts/test-grafana-dashboards.sh`. 통과는 Grafana 로딩이나 쿼리 결과의 증거가 아니다 — 배포 후 확인 항목이다.

## 배포 요약 (사람이 실행, 상세는 로컬 런북 `runbooks/grafana-dashboards-deploy.md`)
1. 승인 머지 SHA를 정한다(40자, `origin/develop` 조상).
2. 이 Application은 **다중 source**다. Sync 요청에서 **차트 source는 `89.2.0` 그대로 두고 values(Git) source만 승인 SHA를 지정**한다. 앱 전체에 Git SHA 하나를 넘기지 않는다.
3. Sync 뒤 Grafana에서 4개 대시보드가 보이는지, Prometheus Targets의 실제 `job`/`namespace`/`pod`/`gpu`/`model_name` 라벨이 변수에 잡히는지 확인한다.
4. 복구: 이전 승인 SHA의 values source로 다시 Sync하거나, 대시보드가 문제면 `kubectl -n monitoring delete configmap -l app.kubernetes.io/component=experiment-dashboards`(Grafana sidecar가 대시보드를 내린다).
