# local-path 부트스트랩

저장 방식과 공유 저장소 비교는 [트레이드오프 문서](../../../tradeoff/03-input-and-storage.md)에 모았다.

재구축 후 **가장 먼저** 설치한다. Kubernetes 기본 기능이 아니라 별도 컴포넌트다.

## 왜 이 설정이어야 하는가

**`setup` 스크립트의 0777** — 기본값으로 두면 root가 만든 디렉터리를 non-root 컨테이너가
쓰지 못해 CNPG부터 기동에 실패한다. 이전 클러스터에서 확인된 문제이며 반드시 유지한다.

**`nodePathMap`에 `DEFAULT_PATH_FOR_NON_LISTED_NODES`가 없다** — 의도적이다.
볼륨을 만들 수 있는 노드는 `k8s-worker1`, `k8s-worker2`, `persona-gpu-01` 셋뿐이고, 그 외
노드(컨트롤 플레인 등)에서는 프로비저닝이 **실패한다**. 워크로드에 `nodeSelector`를 빠뜨렸을 때
조용히 잘못된 노드에 볼륨이 생기는 것을 막는 안전장치다.

**`persona-gpu-01`은 vLLM 모델 캐시용으로 명시 허용했다.** Git 선언에는 추가됐지만, bootstrap은 Argo 밖이므로 실제 클러스터 반영과 GPU PVC `Bound` 실측 전까지 완료가 아니다. 반영은 control-plane에서
사람이 이 ConfigMap을 적용하는 것이고, 확인 기준은 GPU 노드에 고정한 PVC가 `Bound`되는
것이다. 모델 캐시 PVC·seed Job은 `kustomize/overlays/prod/persona-model-cache`에 선언했지만 적용하지
않았고, vLLM·NetworkPolicy는 아직 배선하지 않았다.

로컬 정적 검사(클러스터를 읽지 않는다):

```sh
sh scripts/validate-local-path-bootstrap.sh   # 허용 노드 3개·경로·기본 경로 부재·StorageClass 기준
bash scripts/test-local-path-bootstrap.sh     # 위 기준을 하나씩 깨는 음성 사례
```

## 반드시 알아야 할 제약

| 제약 | 결과 |
| --- | --- |
| `WaitForFirstConsumer` | 첫 스케줄 시점에 노드가 확정된다. **`nodeSelector`는 첫 배포 전에** 들어가 있어야 한다 |
| `Retain` | PVC 삭제 ≠ 데이터 삭제. PV 오브젝트와 노드 디렉터리를 수동으로 지워야 한다. GPU 모델 캐시도 같다 — 지운 뒤 남은 디렉터리의 옛 모델을 다시 읽지 않게 정리한다 |
| GPU 노드 로컬 디스크 | GPU EC2를 terminate하면 루트 디스크와 함께 모델 캐시가 사라진다. stop/start에는 남는다 |
| `allowVolumeExpansion: false` | PVC 크기는 영구 고정. 나중에 못 늘린다 |
| **용량 미강제** | 요청 용량은 강제되지 않는다. 실제 상한은 앱 설정(`retention.size` 등)뿐이다 |

현재 저장소 책임·복구 및 배치 원칙은 [통합 기획](../../../docs/current-plan.md)을 참고한다.

## 노드 배치

과거의 서비스/관측 전용 노드 표는 폐기했다. 일반 앱은 두 홈 워커가 배치 후보다.
저장소별 최초 노드는 후속 결정이며 기존 PV는 현재 바인딩을 확인해야 한다.
변경 근거는 [공유 워커 비교](../../../tradeoff/02-worker-placement.md)를 따른다.
이 문서 정리로 기존 볼륨·매니페스트가 이동하거나 변경되지는 않는다.
