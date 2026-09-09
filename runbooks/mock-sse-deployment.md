# CPU 모의 SSE 서버 배포·검증 런북

이 런북은 `persona-ops-lab`의 CPU 전용 합성 SSE 서버만 대상으로 한다. GPU, LLM,
Gateway 애플리케이션, 공개 인터넷 노출을 추가하지 않는다. `done`이나 조각 간 지연은
LLM TTFT·생성 성능이 아니다.

## 선언 상태와 금지선

- Argo 배포 경로는 `kustomize/overlays/prod/mock-sse`, Application은
  `argocd/persona-mock-sse.yaml`이다. 테스트 namespace는 Secret보다 먼저
  `bootstrap/namespaces/persona-mock-sse.yaml`로 준비하며 Argo overlay에는 넣지 않는다.
- Deployment는 검증된 linux/amd64 child manifest digest를 직접 고정한다. tag, `latest`,
  또는 parent OCI index digest로 바꾸지 않는다.
- Traefik Service의 HTTP 포트 `80`은 클라이언트가 연결하는 Service 포트이고, Gateway
  listener `8000`은 Traefik의 내부 HTTP entryPoint 포트다.
- 이미지와 registry credential은 Git에 저장하지 않는다. private GHCR package에는
  namespace-local `persona-mock-sse-ghcr` pull Secret만 참조한다.

## 고정 이미지 계약

| 항목 | 값 |
| --- | --- |
| source commit | `77b82d05c309614ea18a3b88507809c47947cf83` |
| GHCR tag | `ghcr.io/persona-runtime/persona-mock-sse:77b82d05c309614ea18a3b88507809c47947cf83` |
| OCI index digest | `sha256:89618ac2adaff3d0caf417288ec258039f54c241a7d12ebc1cf66bddb3d8c978` |
| 배포용 linux/amd64 child manifest | `sha256:c467296f090f3868d32d82dda92ab2aaf75b096bae1ae0a0c1e1fde4bf58666d` |

이 artifact는 non-root UID/GID `10001:10001`, read-only root filesystem, capability 제거,
`250m` CPU/`128Mi` 메모리 상한으로 로컬 검증 및 private GHCR push를 마쳤다. 현재 배포
선언은 위 child manifest를 직접 참조한다. 이 기록을 위해 이미지를 재빌드하거나 재-push하지
않는다.

OCI index에는 amd64 실행 manifest와 그 manifest를 가리키는 attestation manifest가 있다.
arm64 실행 manifest는 없다. 따라서 arm64 Mac의 기본 pull 실패 원인은 amd64 manifest가
아니라 arm64 manifest 부재다. amd64 worker는 index digest도 자동 선택할 수 있지만, 이번
Deployment는 검증 대상을 분명히 하려고 amd64 child manifest를 직접 고정한다.

## 승인된 최초 배포 순서

아래 순서는 namespace, Secret, Application을 처음 만드는 경우에만 별도 승인 후 실행한다.
모든 Kubernetes 명령은 홈 kubeconfig와 context를 함께 명시한다.

### 1. 홈 kubeconfig와 context 확인

```sh
: "${PERSONA_HOME_KUBECONFIG:?set the explicit home kubeconfig path}"
: "${PERSONA_HOME_CONTEXT:?set the home kubeconfig context}"
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" config get-contexts
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" cluster-info
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" get nodes -o wide
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" get gatewayclass,gateway,httproute -A
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" -n traefik get svc,deploy -o wide
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" get applications.argoproj.io -A
```

GatewayClass `traefik`, HTTP entryPoint `8000`, 기존 Gateway 부재, Traefik Service HTTP
port `80`, Argo project/source/destination을 이 단계에서 재확인한다. CRD·추가
controller·기존 Gateway를 만들거나 바꾸지 않는다.

### 2. 테스트 namespace 준비

```sh
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" \
  apply --server-side -f bootstrap/namespaces/persona-mock-sse.yaml
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" \
  get namespace persona-mock-sse
```

### 3. 제한된 Docker 인증 파일에서 GHCR pull Secret 생성

`GHCR_DOCKER_CONFIG`는 새 빈 전용 directory여야 하며 Git working tree 밖에 둔다.
`docker login`은 토큰을 대화형으로 읽어 shell history에 쓰지 않는다.

```sh
: "${GHCR_DOCKER_CONFIG:?set a private local directory for this registry login}"
install -d -m 700 "$GHCR_DOCKER_CONFIG"
docker --config "$GHCR_DOCKER_CONFIG" login ghcr.io
test -s "$GHCR_DOCKER_CONFIG/config.json"
chmod 700 "$GHCR_DOCKER_CONFIG"
chmod 600 "$GHCR_DOCKER_CONFIG/config.json"
ruby -rjson -e 'auth = JSON.parse(File.read(ARGV.fetch(0))).dig("auths", "ghcr.io", "auth"); abort("missing ghcr.io auth") unless auth.is_a?(String) && !auth.empty?' "$GHCR_DOCKER_CONFIG/config.json"
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" -n persona-mock-sse \
  create secret generic persona-mock-sse-ghcr \
  --from-file=.dockerconfigjson="$GHCR_DOCKER_CONFIG/config.json" \
  --type=kubernetes.io/dockerconfigjson --dry-run=client -o yaml | \
  kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" apply -f -
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" -n persona-mock-sse \
  get secret persona-mock-sse-ghcr
```

### 4. 실제 digest와 Argo Git revision/path 확인

고정 digest 변경을 `develop`에 push한 뒤, Argo Application이 `develop`의
`kustomize/overlays/prod/mock-sse`를 읽는지 확인한다.

```sh
sh scripts/validate-mock-sse-manifests.sh
kubectl kustomize kustomize/overlays/prod/mock-sse > /tmp/persona-mock-sse.yaml
rg -n 'REPLACE_WITH|:latest' /tmp/persona-mock-sse.yaml
git fetch origin develop
git show origin/develop:kustomize/base/mock-sse/deployment.yaml
git show origin/develop:kustomize/overlays/prod/mock-sse/kustomization.yaml
```

정적 검증은 성공해야 하며, `rg`는 출력이 없어야 한다. `origin/develop`의 Deployment가 같은
digest를 포함하고 overlay path가 존재하는 것을 확인한다.

### 5. 서버 측 dry-run

```sh
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" \
  apply --dry-run=server -f /tmp/persona-mock-sse.yaml
```

### 6. Application 등록, Diff, 수동 Sync

```sh
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" -n argocd \
  apply --server-side -f argocd/persona-mock-sse.yaml
kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" -n argocd \
  get application persona-mock-sse
argocd app diff persona-mock-sse
argocd app sync persona-mock-sse
```

마지막 두 명령은 별도로 인증된 Argo CLI session에서만 실행한다. Application에는 automated
sync·self-heal·prune이 없다.

## 실제 경로와 종료 검증

승인된 수동 Sync 후 Deployment/Pod/Service, Gateway의 `Accepted`·`Programmed`,
HTTPRoute의 `Accepted`·`ResolvedRefs`를 확인한다. Service 직접 접근, Traefik Service
port-forward, 확인된 Tailscale Serve 진입 경로를 서로 다른 증거로 기록한다.

1. Service: `kubectl --kubeconfig "$PERSONA_HOME_KUBECONFIG" --context "$PERSONA_HOME_CONTEXT" -n persona-mock-sse port-forward service/persona-mock-sse 18080:8080`
2. Traefik: 실제 조회한 Service port `80`을 port-forward한 뒤 같은 `POST /mock/chat` 요청
3. Tailnet: 사전에 확인한 Tailscale Serve 주소로 같은 요청

`curl --no-buffer`로 조각이 완료 시점에 몰리지 않는지, 요청한 수의 `chunk`와 한 번의
`done`을 확인한다. `/healthz`와 `/readyz`는 HTTPRoute에서 404여야 한다.

취소 검증은 `chunks=100`, `interval_ms=1000` 요청에서 첫 조각 뒤 client를 종료하고 Pod
로그의 `outcome=cancelled`로 task 정리를 확인한다. Pod 종료 검증은 단일 replica의 일시
중단 영향을 승인자가 확인한 뒤에만 한다. 짧은 스트림은 15초 termination grace 안에서
`done`으로 완료되어야 하며, 긴 스트림은 서버의 5초 drain 뒤 중단되고 `done`이 없어야 한다.

롤백은 직전 image digest를 Git으로 되돌린 뒤 Argo Diff 및 수동 Sync로 수행한다. 테스트
workload 제거는 prune으로 자동 처리하지 않으며 별도 승인이 필요하다.
