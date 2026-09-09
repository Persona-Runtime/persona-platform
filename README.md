# persona-platform

AWS와 Kubernetes 실행 환경·배포·보안 정책을 소유한다.
최신 설계는 **[현재 기획과 아키텍처](../docs/current-plan.md)** 하나를 기준으로 한다.

## 지금 하는 작업

홈 현황 확인 → 최소 모니터링 → CPU 모의 서빙·부하 도구 → GPU 절차 준비 → 실제 GPU 서빙·기준선 → 병목 개선 순서다.
Go Gateway·dispatcher·업로드 자동화의 개발/배포는 보류한다. 아래 앱 배치 항목은 후속 제품 목표다.
[AWS GPU Terraform 준비](terraform/envs/prod/README.md)를 추가했다. 아직 실제 AWS 생성·GPU 조인·vLLM 배포는 하지 않았다.
서울 GPU 할당량은 증가 요청 대기 중이며 실제 입력/비용/접근 검토 후 생성 여부를 별도로 승인받는다.
할당량이 승인돼도 홈 준비가 끝날 때까지 EC2는 생성하지 않는다.
2026-09-09 사용자 출력으로 [홈 현황 수집·문서화](docs/cluster-inventory.md)를 완료했다. 노드 3개 Ready, PV/PVC 없음, Gateway/HTTPRoute 없음, argocd namespace의 Application 없음. 다음은 최소 모니터링 설계다.

## 현재 배치 원칙

- 홈 CP 1 + 공용 홈 워커 2 + AWS GPU 워커 1의 단일 Kubernetes 클러스터.
- 웹·Gateway·ingestion·무상태 관측 앱은 두 홈 워커를 공유한다.
- 서비스 전용 워커 / 관측 전용 워커 구분은 없다.
- Postgres·Qdrant·Prometheus·Tempo는 각자의 local-path 볼륨 위치에 제약을 받는다.
- vLLM은 단일 GPU 노드에 배치하며 필수 GPU·네트워크 에이전트도 해당 노드에서 실행한다.
- 웹 2·Traefik 2·Gateway 1 채택. 웹·Traefik은 홈 워커 간 분산 권장, Traefik은 적용 확인.
- 별도 Go dispatcher 1개와 작업별 ingestion Job 채택, 구현·배포 전. 전체 동시 작업 1개 제어와 세부 RBAC는 후속 설계.
- 나머지 앱 개수와 저장소별 최초 노드는 미정이다.
- Tailscale + Cilium VXLAN + kube-proxy, Traefik Gateway API 방향을 유지한다.
- 접속은 Tailnet 전용이다. Tailscale Serve의 호스트 배치는 파드 스케줄링과 별개다.

GPU Operator 사용 여부·드라이버 관리 주체, 최종 자원 수치는 후속 결정이다.
이 README는 설치나 마이그레이션을 실행하라는 지시가 아니다.

## 운영 자료

- [클러스터 실측·설치 기록](docs/cluster-inventory.md)
- [Cilium 운영](bootstrap/cilium/README.md)
- [local-path 운영](bootstrap/local-path/README.md)
- [Traefik 운영](bootstrap/traefik/README.md)
- [설계 트레이드오프 목록](../tradeoff/README.md)
- [추후 확장 후보](../tradeoff/06-future-extensions.md)

배포 선언은 `bootstrap/`, `helm/`, `kustomize/`, `argocd/` 등에서 관리한다.
dispatcher의 별도 Deployment·ServiceAccount·제한된 Role과 ingestion 실행 환경도 platform이 소유한다.
dispatcher 코드·작업 계약은 `persona-gateway`, 실제 처리 코드는 `persona-ingestion`의 책임이다.
이번 문서 정리로 기존 매니페스트·클러스터·PV를 변경하지 않았다.
