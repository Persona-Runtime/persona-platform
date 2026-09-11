# 실행 위치와 로컬 접속 범위

결정일: 2026-09-09. 사용자 요청에 따라 홈 클러스터의 직접 운영은 CP에서 수행한다.

| 위치 | 허용하는 작업 |
| --- | --- |
| 노트북 | 코드·선언 작성, 로컬 테스트/렌더, Git 반영, 이미지 빌드·검증 및 승인된 push |
| 노트북 → 홈 | Prometheus·Grafana·Argo CD 접속. 해당 UI용 loopback port-forward 유지 |
| 홈 CP `k8s-cp` | 클러스터 조회·server dry-run, namespace/Secret/Application 준비, 직접 배포·운영·복구 명령 |
| 홈 Argo CD | Git 선언을 읽어 실제 앱 배포. 허용된 Argo UI에서 Diff·수동 Sync 가능 |

노트북에서 홈을 대상으로 `kubectl apply/delete/rollout`, Helm 설치/변경, Secret 생성이나
SSH 원격 명령을 이용한 배포 자동화를 수행하지 않는다. 홈 운영은 사용자가 CP 터미널에서 실행한다.
SSH 접속 별칭은 CP 터미널에 들어가기 위한 수단이므로 삭제하지 않는다.
일반 서비스에 대한 브라우저 사용과 클러스터 관리 권한 사용은 별개다.

## 유지하는 것

- 로컬의 홈 kubeconfig·Tailscale 연결: Prometheus·Argo CD·Grafana 접속에 필요해 유지.
- `scripts/validate-mock-sse-manifests.sh`: 파일을 로컬 렌더하고 검사할 뿐 홈 API를 호출하지 않으므로 유지.
- GitOps 선언: 실행 위치와 무관하게 Argo가 배포할 원본이므로 유지.
- Gateway dispatcher 등 클러스터 안의 서비스 기능: 로컬 운영 자동화와 별개이며 삭제 대상이 아님.

## 권한과 한계

이 결정은 사용·안내 범위를 정한 것이며 kubeconfig 자격증명의 권한을 축소한 것은 아니다.
기존 관리자 kubeconfig를 보관하면 기술적으로 다른 클러스터 작업도 가능하다.
세 UI 접속만 기술적으로 강제하려면 별도의 최소 권한 자격증명 또는 접속 경로 설계가 필요하다.
이번 정리에서는 kubeconfig 삭제·인증서 폐기·RBAC 변경·Argo 권한 변경을 수행하지 않는다.

운영 명령 안내에는 실행 위치를 표시하고, CP에서는 현재 확인된 context
`kubernetes-admin@kubernetes`를 명시한다. SSH 로그인 가능 여부를 배포 승인으로 간주하지 않는다.
