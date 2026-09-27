# 모델 seed DNS discovery (임시)

`persona-inference`에 영구 default-deny와 최소 FQDN allowlist를 넣기 **전에**, 모델 seed가 실제로
질의·접속하는 호스트를 관측하는 임시 절차다. 추측한 호스트 목록으로 allowlist를 만들지 않는다.

- **임시다.** 관측을 기록하면 이 overlay 전체를 지운다. Argo Application이 없고 prod overlay가 이
  경로를 가리키지 않는다(`scripts/validate-model-seed-dns-discovery.sh`가 막는다).
- **현재 cache를 건드리지 않는다.** discovery Job은 모델 cache PVC가 아니라 emptyDir에 받는다. cache를
  지우거나 seed Job을 다시 실행할 필요가 없다.
- **같은 다운로드 흐름이다.** image digest, `seed_model.py`, 모델·revision, GPU 노드 배치, 권한 조건이
  seed Job과 같다(validator가 두 렌더를 대조한다).

## 무엇이 들어 있는가

| 리소스(렌더 이름) | 역할 |
| --- | --- |
| `Job/dns-discovery-persona-vllm-model-seed` | seed와 같은 명령으로 전체 다운로드를 emptyDir(`/discovery`)에 한 번 실행 |
| `CiliumNetworkPolicy/dns-discovery-persona-vllm-model-seed` | discovery Pod만: CoreDNS UDP/TCP 53에 DNS L7 `matchPattern: "*"`(질의 이름 가시성), 외부 HTTPS 443 **임시 허용** |
| `ConfigMap/dns-discovery-persona-vllm-model-seed-script-<hash>` | seed 스크립트 사본(이 overlay를 지워도 seed Job용 ConfigMap은 남는다) |

정책은 `app.kubernetes.io/name: persona-vllm-model-seed`와 `persona.runtime/purpose: dns-discovery`를
**둘 다** 가진 Pod만 고른다. vLLM Pod와 실제 seed Job Pod에는 걸리지 않는다. 이 정책이 고른 Pod의
나머지 egress는 막힌다.

## 절차 (control-plane에서 사람이 수행)

1. **전제 확인**: kubectl context가 운영 클러스터인지, `persona-inference` Namespace가 있는지, GPU 노드
   디스크에 약 10 GiB 여유가 있는지 확인한다.
2. **렌더 검사**: `sh scripts/validate-model-seed-dns-discovery.sh`
3. **적용**: `kubectl apply -k kustomize/overlays/discovery/persona-model-seed-dns` — 적용 시각을 적는다.
4. **관측**(Job이 끝날 때까지):
   ```sh
   # 질의된 이름(DNS L7). discovery label로만 좁힌다.
   hubble observe --namespace persona-inference --label persona.runtime/purpose=dns-discovery \
     --protocol dns --follow
   # 외부 443 접속(목적지 IP). 위 DNS 응답의 IP와 대조한다.
   hubble observe --namespace persona-inference --label persona.runtime/purpose=dns-discovery \
     --to-port 443 --follow
   ```
   GPU 노드의 Cilium agent에서 `cilium-dbg fqdn cache list`로 이름→IP 캐시를 함께 적는다.
5. **완료 확인**: `kubectl -n persona-inference logs job/dns-discovery-persona-vllm-model-seed`의 마지막
   줄이 `"result": "seeded"`인지 본다. 실패면 원인(DNS 거부, 443 외 포트 필요, 용량)을 기록한다 —
   443 외 포트가 필요했다면 그 사실 자체가 관측 결과다.
6. **제거**: `kubectl delete -k kustomize/overlays/discovery/persona-model-seed-dns`. discovery label을 가진
   Pod와 임시 정책이 남지 않았는지 확인한다.
7. **후보 반영**: 아래 기록에서 **443 접속으로 이어진 질의 이름만**
   `kustomize/base/networkpolicy/persona-inference/network-policy-fqdn.yaml.draft`의 후보로 옮긴다.
   와일드카드(matchPattern)로 넓히지 않는다. 최소 FQDN allowlist와 default-deny는 **별도 PR**로 만든다.

## 관측 기록 양식

| 항목 | 값 |
| --- | --- |
| 적용·완료·제거 시각(UTC) | |
| Job 결과(`seeded` / 실패 사유) | |
| discovery Pod 노드 | |

| 질의 이름(A/AAAA) | 응답 IP 또는 CNAME | 443 접속 여부 | 역할(메타데이터·파일 redirect 등, 관측으로 확인한 것만) | allowlist 후보 |
| --- | --- | --- | --- | --- |
| | | | | |

기록에는 토큰·Authorization 값·요청 본문을 남기지 않는다. 이 모델은 gated가 아니라 토큰을 쓰지 않는다.
