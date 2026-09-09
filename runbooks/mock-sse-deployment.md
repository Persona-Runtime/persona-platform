# CPU 모의 SSE 서버 배포·검증 런북

이 런북은 `persona-ops-lab`의 CPU 전용 합성 SSE 서버만 대상으로 한다. GPU, LLM,
Gateway 애플리케이션, 공개 인터넷 노출을 추가하지 않는다. `done`이나 조각 간 지연은
LLM TTFT·생성 성능이 아니다.

## 선언 상태와 금지선

- Argo 배포 경로는 `kustomize/overlays/prod/mock-sse`, Application은
  `argocd/persona-mock-sse.yaml`이다. 테스트 namespace는 Secret보다 먼저
  `bootstrap/namespaces/persona-mock-sse.yaml`로 준비하며 Argo overlay에는 넣지 않는다.
- Deployment의 이미지 placeholder는 실제 linux/amd64 GHCR manifest digest가 기록되기
  전까지 배포 금지 상태다. tag만 지정하거나 `latest`를 쓰지 않는다.
- Traefik Service의 HTTP 포트 `80`은 클라이언트가 연결하는 Service 포트이고, Gateway
  listener `8000`은 Traefik의 내부 HTTP entryPoint 포트다.
- 이미지와 registry credential은 Git에 저장하지 않는다. private GHCR package에는
  namespace-local `persona-mock-sse-ghcr` pull Secret만 참조한다.

## 이미지 계약과 로컬 확인

먼저 `persona-ops-lab`의 모의 서버 변경을 검토·커밋한다. dirty working tree를 배포
artifact의 출처로 사용하지 않는다.

```sh
export MOCK_SSE_REV="$(git -C ../persona-ops-lab rev-parse HEAD)"
cd ../persona-ops-lab
docker buildx build --platform linux/amd64 --load --tag persona-mock-sse:local .
docker run --rm --read-only --user 10001:10001 \
  --name persona-mock-sse-local -p 18080:8080 persona-mock-sse:local
```

별도 터미널에서 health/readiness와 SSE 계약을 확인하고, 장기 스트림 동안 `docker stats
persona-mock-sse-local`을 여러 번 기록해 idle·peak CPU/메모리를 남긴다. 현재
`50m/64Mi` request 및 `250m/128Mi` limit은 그 관측과 홈 worker allocatable을 근거로만
조정한다.

```sh
curl --fail http://127.0.0.1:18080/healthz
curl --fail http://127.0.0.1:18080/readyz
curl --no-buffer --fail-with-body -X POST http://127.0.0.1:18080/mock/chat \
  -H 'Content-Type: application/json' \
  --data '{"chunks":2,"interval_ms":100}'
```

`chunk` 두 개가 순서대로 오고 `done`이 한 번만 와야 한다. `--read-only`가 실패하면
이미지 원인을 해결한다. root filesystem을 writable로 바꾸는 것은 원인이 확인되고 별도
검토된 경우에만 허용한다.

검증된 source revision만 private GHCR로 push하고 registry가 보고한 manifest digest를
Deployment placeholder에 기록한다.

```sh
docker buildx build --platform linux/amd64 --push \
  --tag "ghcr.io/persona-runtime/persona-mock-sse:${MOCK_SSE_REV}" .
docker buildx imagetools inspect \
  "ghcr.io/persona-runtime/persona-mock-sse:${MOCK_SSE_REV}"
```

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

이미지 placeholder를 GHCR manifest digest로 교체하고, 변경을 `main`에 push한다. Argo
Application은 `main`의 `kustomize/overlays/prod/mock-sse`만 읽는다.

```sh
sh scripts/validate-mock-sse-manifests.sh
kubectl kustomize kustomize/overlays/prod/mock-sse > /tmp/persona-mock-sse.yaml
rg -n 'REPLACE_WITH|:latest' /tmp/persona-mock-sse.yaml
git fetch origin main
git show origin/main:kustomize/base/mock-sse/deployment.yaml
git show origin/main:kustomize/overlays/prod/mock-sse/kustomization.yaml
```

정적 검증은 성공해야 하며, `rg`는 출력이 없어야 한다. `origin/main`의 Deployment가 같은
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
