# Traefik — Gateway API 컨트롤러

## 설치 순서

Gateway API CRD가 **먼저** 있어야 한다. CRD는 단일 소유자 원칙을 지킨다 —
Cilium과 Traefik이 각자 관리하려 들면 Argo sync가 충돌한다.

```bash
# 1) Gateway API CRD (standard channel, 버전 고정)
curl -s https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest \
  | grep '"tag_name"'
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/<TAG>/standard-install.yaml

# 2) PriorityClass
kubectl apply -f ../priorityclasses/priorityclasses.yaml

# 3) Traefik
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm search repo traefik/traefik --versions | head -3
```

## 설치 전에 렌더링을 확인한다

**helm은 알 수 없는 values를 조용히 무시한다.** Cilium에서 이미 겪었다
(`MTU` 변경이 ConfigMap에만 반영되고 파드는 그대로 돌았다).
차트 버전마다 키 이름이 다르므로 설치 전에 실제로 반영되는지 본다.

```bash
helm template traefik traefik/traefik --version <VER> -n traefik -f values.yaml \
  | grep -E 'nodeSelector|priorityClassName|type: ClusterIP|kubernetesGateway' -A2
```

기대한 항목이 안 보이면 그 키는 무시된 것이다. 차트 문서를 확인하고 고친다.

```bash
helm install traefik traefik/traefik --version <VER> \
  -n traefik --create-namespace -f values.yaml
```

## 확정된 선택

| 설정 | 값 | 이유 |
| --- | --- | --- |
| `service.type` | **ClusterIP** | public inbound 0. NodePort/LoadBalancer 금지 |
| `providers.kubernetesGateway` | true | Gateway API만 사용 |
| `providers.kubernetesIngress` / `kubernetesCRD` | false | 진입 경로를 하나로 고정 |
| `gateway.enabled` | false | Gateway 리소스는 우리가 선언·버전관리 |
| `nodeSelector` | `k8s-worker2` | stateless 계층 배치 |
| `priorityClassName` | `persona-low` | 압박 시 관측·데이터보다 먼저 축출 |

## 함정: 스키마 검증은 섹션별로만 걸린다

이 차트는 values 스키마가 있어 최상위의 잘못된 키는 **거부한다**.
`logs`(존재하지 않음, 올바른 키는 `log`와 `accessLog`)는 즉시 에러로 잡혔다.

그러나 **`service:` 섹션에는 `additionalProperties: false`가 없다.**
그래서 `service.type: ClusterIP`는 스키마를 통과한 뒤 **조용히 무시되었고**,
렌더 결과는 기본값 `LoadBalancer`였다. 올바른 키는 **`service.spec.type`**이다.

```
service:
  spec:
    type: ClusterIP     # service.type 이 아니다
```

LoadBalancer로 두면 컨트롤러가 없어 EXTERNAL-IP는 `<pending>`이지만
**NodePort가 함께 할당되어 모든 노드에 포트가 열린다.** 재구축으로 없애려던
ingress-nginx의 NodePort 30080/30443 상태로 그대로 되돌아간다.

**설치 전 `helm template`으로 잡아냈다.** 그냥 설치했다면 `kubectl get svc`를
보고 나서야 알았을 문제다. 스키마가 있는 차트라도 렌더링 확인을 건너뛰지 않는다.

## 검증

```bash
kubectl -n traefik get pods,svc -o wide
kubectl get gatewayclass                       # traefik이 Accepted 상태여야 함
kubectl get crd | grep gateway.networking.k8s.io
```

## Tailnet 노출은 별도 단계

Traefik Service가 ClusterIP이므로 클러스터 밖에서는 보이지 않는다.
노출은 `tailscale serve`가 노드 쪽에서 ClusterIP로 전달하는 방식으로 붙인다
(노드는 kube-proxy를 통해 ClusterIP에 도달할 수 있다).

대안으로 Tailscale Kubernetes Operator를 쓰면 Service 애노테이션만으로 tailnet에
노출할 수 있으나, 컴포넌트가 하나 늘어난다. v1은 Serve 방식으로 간다.
