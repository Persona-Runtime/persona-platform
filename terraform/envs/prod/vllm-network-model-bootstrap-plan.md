# vLLM 네트워크·모델 cache 실행 계획

상태: **2026-09-25 구현 전 결정**. 이 문서는 GPU 인스턴스, Kubernetes Node, PVC,
NetworkPolicy, 모델 다운로드 Job을 아직 만들거나 Sync하지 않는다.

## 한 문장 결론

vLLM은 `persona-inference`에 격리하고, Gateway와 Prometheus만 vLLM Pod의 TCP 8000에
들어오게 한다. 모델은 vLLM이 인터넷에서 직접 받지 않고, GPU Node에 고정되는 local-path
PVC에 별도 seed Job이 고정 revision으로 미리 저장한다.

```text
Gateway ───────────────▶ vLLM :8000      실제 추론
Prometheus ─────────────▶ vLLM :8000      /metrics 수집
model-cache seed Job ───▶ 허용한 model FQDN 최초 다운로드
vLLM ───────────────────▶ model PVC       인터넷 없이 local model path 읽기
```

## 1. 왜 model download를 분리하는가

vLLM image pull은 Node의 container runtime이 수행하지만, 모델 파일 download는 실행 중인 Pod가
수행한다. `persona-inference`가 default-deny이면 이 Pod download는 당연히 차단된다.

vLLM 자체에 model download egress를 계속 열면, 모델이 언제·어디서 바뀌었는지와 추론 Pod의
외부 통신 범위를 함께 관리해야 한다. 대신 download 책임을 짧게 사라지는 seed Job 하나로
분리한다. seed가 성공한 뒤 vLLM은 local path만 읽으므로 steady state에는 외부 model egress가
없다.

이 선택은 seed Job image·고정 model revision·검증 방법을 별도로 정해야 하는 비용을 수용한다.
그러나 vLLM 서비스가 재시작할 때마다 인터넷 상태에 의존하지 않는다는 이점이 더 크다.

## 2. model cache 저장 위치

cache는 `persona-vllm-model-cache` PVC로 둔다.

- StorageClass는 기존 `local-path`다. `WaitForFirstConsumer`이므로 seed Job이 GPU Node에
  스케줄된 뒤에만 그 Node에 PV가 생긴다.
- seed Job과 vLLM Deployment는 같은 GPU Node selector·taint toleration을 사용한다.
- cache PVC는 `ReadWriteOnce`이며, seed Job이 완료된 뒤에만 vLLM이 mount한다. 두 workload를
  동시에 실행하지 않는다.
- vLLM에는 `/models`를 read-only로 mount하고, `/tmp`·runtime cache처럼 쓰기가 필요한 경로는
  `emptyDir`로 분리한다.
- local-path reclaim policy가 `Retain`이므로 Pod 재시작·EC2 stop/start에는 cache가 남을 수
  있다. EC2 terminate나 PVC/PV 수동 정리 뒤에는 다시 seed해야 한다.

현재 local-path ConfigMap은 `k8s-worker1`, `k8s-worker2`만 허용한다. GPU Node 조인 뒤
`persona-gpu-01`과 `/opt/local-path-provisioner`를 추가하는 별도 GitOps 변경이 필요하다.
이 변경 없이는 PVC provisioning이 의도적으로 실패한다. hostPath를 vLLM Pod에 직접 mount해
우회하지 않는다.

## 3. 고정 label 계약

아래 label은 Deployment, Service, NetworkPolicy, PodMonitor가 똑같이 사용한다.

```yaml
app.kubernetes.io/name: persona-vllm
app.kubernetes.io/component: inference
app.kubernetes.io/part-of: persona-platform
```

model seed Job은 `component: model-cache-seed`로 분리한다. seed Job을 vLLM label로 만들면
vLLM용 ingress·metrics policy가 의도치 않게 seed Pod에도 적용될 수 있다.

## 4. 만들 NetworkPolicy

| 위치 | 정책 | 허용 흐름 | 목적 |
| --- | --- | --- | --- |
| `persona-app` | 기존 `allow-gateway` egress 확장 | Gateway → vLLM TCP 8000 | 실제 추론 |
| `persona-inference` | `default-deny` | 없음 | 기본 차단 |
| `persona-inference` | `allow-vllm-gateway` | Gateway Pod → vLLM TCP 8000 | 추론 ingress |
| `persona-inference` | `allow-vllm-metrics` | 실제 Prometheus Pod → vLLM TCP 8000 | `/metrics` scrape |
| `persona-inference` | `allow-vllm-dns` | vLLM Pod → CoreDNS TCP/UDP 53 | 내부 이름 해석 |
| `persona-inference` | `allow-model-seed-dns` | seed Job → CoreDNS TCP/UDP 53 | 최초 download 이름 해석 |
| `persona-inference` | Cilium FQDN egress | seed Job → 실행 시 확인한 model host만 HTTPS | 최초 download |

표준 Kubernetes NetworkPolicy는 IP/Pod/namespace 기준이고 FQDN을 직접 표현하지 못한다.
model download만 CiliumNetworkPolicy의 FQDN 정책으로 별도 선언한다. 실제 다운로드 시 필요한
redirect·artifact host를 합성 seed run에서 먼저 기록한 뒤 허용 목록을 확정한다. 추측한 host
목록이나 `0.0.0.0/0:443`은 넣지 않는다.

### 초안이 실제로 어디에 있는가 (2026-09-25)

위 표 중 `persona-inference` 쪽 다섯 개는 **미적용 매니페스트로 작성했다.**

| 파일 | 상태 |
| --- | --- |
| `bootstrap/namespaces/persona-inference.yaml` | 작성. 이 파일을 가리키는 Application 없음 |
| `kustomize/base/networkpolicy/persona-inference/network-policy.yaml` | 작성. 정책 5개 |
| `kustomize/overlays/prod/persona-inference-netpol/` | 작성. **Argo Application 없음** |
| `kustomize/base/networkpolicy/persona-inference/network-policy-fqdn.yaml.draft` | 배선하지 않음 — 확장자와 `resources` 둘 다에서 제외 |

`kubectl kustomize kustomize/overlays/prod/persona-inference-netpol`로 렌더되고
`scripts/validate-networkpolicy-manifests.sh`가 검사하지만, Argo가 보는 경로가 아니므로
클러스터에는 들어가지 않는다.

**`persona-app`의 Gateway egress는 아직 손대지 않았다.** `allow-gateway`는 살아 있는
`persona-app-netpol` Application이 Sync하는 파일이라, 지금 한 줄을 더하면 다음 Sync에서
그대로 적용된다. 대상이 없어 동작상 무해하지만 "이 Application은 한 종류의 변경만 담는다"는
규약(`argocd/README.md`)과 위 §5의 5단계 순서에 어긋난다. 그래서 **vLLM 배포와 같은 단계에서
넣을 조각을 여기 적어 두고 파일은 그대로 둔다.** `allow-gateway`의 `egress` 목록 끝에 더한다.

```yaml
    # vLLM 추론. 대상은 persona-inference의 vLLM Pod 하나뿐이다.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: persona-inference
          podSelector:
            matchLabels:
              app.kubernetes.io/name: persona-vllm
      ports:
        - protocol: TCP
          port: 8000
```

### Prometheus selector — 문서와 매니페스트가 다르다

이 문서는 "`monitoring` namespace 전체가 아니라 실제 Prometheus Pod label로 고정한다"고
적었다. **작성한 매니페스트는 namespace label만 쓴다.** 일부러 다르게 했으므로 판단이
필요하다.

- namespace만 쓴 이유: Prometheus Pod 라벨은 kube-prometheus-stack 차트가 정하고 이
  저장소가 선언하지 않는다. 차트를 올리면 라벨이 바뀌어 수집이 **조용히** 끊긴다. 그리고
  기존 세 선례(`traefik/allow-ingress-metrics`, `persona-data`의 exporter 허용,
  `persona-app/allow-gateway-metrics`)가 **전부 namespace 라벨만** 쓴다 — 여기만 다르게 하면
  관례가 갈라진다.
- Pod label로 좁히는 쪽의 장점: `monitoring`의 다른 Pod(Grafana·sidecar 등)가 vLLM의 8000에
  닿지 못한다. 문서가 말한 "Target이 DOWN으로 드러나야 한다"는 것도 맞는 요구다.

둘 다 근거가 있다. 지금은 기존 관례를 따랐고, Pod label로 좁히기로 결정하면 **네 정책을 함께**
바꿔야 한다(한 곳만 좁히면 관례가 더 갈라진다).

## 5. 배포·Sync 순서

1. GPU Node 조인 후 Cilium·kube-proxy가 custom taint를 tolerate하는지 확인한다.
2. `persona-gpu-01`용 local-path nodePathMap 변경을 별도 검토·Sync한다.
3. `persona-inference` Namespace(PSA `restricted`), inference NetworkPolicy, model cache PVC,
   seed Job 선언을 렌더한다. 이 단계에서 vLLM image의 securityContext를 server dry-run으로
   검증한다.
4. `persona-inference`의 allow 정책을 sync-wave 0, default-deny를 wave 1로 둔다. 아직
   대상 Pod가 없으므로 서비스 통신에는 영향이 없다.
5. `persona-app-netpol`의 Gateway egress를 수동 Sync한다. 대상 Service가 없어도 기존
   DB·embedding 경로를 바꾸지 않는다.
6. GPU Node에서 seed Job을 한 번 실행한다. 고정 model revision, download 결과 파일 목록,
   PVC bound Node를 기록한다. token·원문은 로그에 남기지 않는다.
7. seed Job이 성공한 뒤 local model path를 쓰는 vLLM Deployment·Service·PodMonitor를 Sync한다.
8. Prometheus Target `UP`, Gateway→vLLM 허용, 외부 namespace→vLLM 차단을 각각 확인한다.

vLLM Deployment보다 정책과 cache seed가 먼저다. cache가 비어 있거나 PodMonitor가 `DOWN`이면
vLLM이 Ready여도 Gateway 설정을 LLM mode로 바꾸지 않는다.

## 6. 완료 판정과 미결 값

완료 판정은 다음을 모두 만족하는 것이다.

- PVC가 `persona-gpu-01`에 Bound이고 seed Job이 지정한 model revision을 끝까지 저장했다.
- vLLM Pod가 외부 model egress 없이 local model path에서 Ready가 됐다.
- Gateway와 Prometheus만 vLLM TCP 8000에 성공한다.
- vLLM·DCGM Target이 `UP`이며, 허용하지 않은 namespace/port 흐름은 Hubble에서 차단된다.

아직 실제값으로 확정하지 않은 항목은 seed Job image·명령, model revision commit, 실제 model
FQDN 목록, Prometheus Pod label, vLLM image의 writable path·non-root 호환성이다. 이 값은
render/server dry-run과 첫 합성 seed run으로 확인한 뒤 매니페스트에 고정한다.
