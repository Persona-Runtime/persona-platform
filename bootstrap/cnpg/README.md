# CloudNativePG operator 설치

operator 설치와 DB Cluster 생성은 **다른 단계**다. operator는 클러스터 전역 자원(CRD,
`cnpg-system` namespace, ClusterRole)을 만들기 때문에 Argo가 관리하지 않고 여기 절차로만 다룬다.
DB Cluster는 `kustomize/base/persona-db/`가 소유하며 Argo가 관리한다.

실행 위치: **홈 CP(`k8s-cp`)**. 노트북에서 실행하지 않는다.
[실행 위치·접속 정책](../../runbooks/execution-locations.md)을 따른다.

## 고정 버전

| 항목 | 값 |
| --- | --- |
| operator | CloudNativePG **v1.30.0** (2026-06-29 릴리스) |
| 설치 매니페스트 | `https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml` |
| 설치 위치 | `cnpg-system` namespace (매니페스트가 직접 만든다) |

## 1. 중복 설치 확인 — 먼저 한다

operator를 두 번 설치하면 CRD와 webhook이 충돌해 기존 Cluster까지 흔들린다.
아래를 **모두** 확인하고, 셋 다 없을 때만 2번으로 넘어간다.

```sh
kubectl --context=kubernetes-admin@kubernetes get crd clusters.postgresql.cnpg.io
kubectl --context=kubernetes-admin@kubernetes -n cnpg-system get deploy
kubectl --context=kubernetes-admin@kubernetes get clusters.postgresql.cnpg.io -A
```

- CRD가 이미 있으면 **설치하지 않는다.** 버전만 확인한다:
  `kubectl -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'`
- 기존 버전이 v1.30.0보다 낮아도 이번 작업에서 업그레이드하지 않는다. 별도 판단이 필요하다.

## 2. 설치 (없을 때만)

```sh
kubectl --context=kubernetes-admin@kubernetes apply --server-side \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml
```

`--server-side`를 쓰는 이유는 CRD가 커서 `kubectl.kubernetes.io/last-applied-configuration`
annotation 크기 제한에 걸리기 때문이다.

## 3. 설치 확인

```sh
kubectl --context=kubernetes-admin@kubernetes -n cnpg-system rollout status deploy/cnpg-controller-manager
kubectl --context=kubernetes-admin@kubernetes get crd | grep cnpg.io
```

`clusters.postgresql.cnpg.io`가 있어야 `persona-db` Application을 Sync할 수 있다.

## 삭제하지 않는 것

operator를 제거하면 CRD가 사라지고 **기존 Cluster 오브젝트가 함께 사라진다.** PVC는
`Retain` 정책이라 디스크에 남지만, 클러스터 재구성 절차가 필요해진다.
operator 제거는 이 문서의 범위가 아니다.
