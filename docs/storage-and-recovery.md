# 스토리지 운영 원칙과 복구 전략

`local-path`는 일반적인 동적 프로비저닝처럼 다루면 안 된다. 이 문서는 그 제약을
운영 규칙으로 고정하고, 각 저장소가 실제로 어떻게 복구되는지를 정직하게 적는다.

## 1. StorageClass 사양

재구축 후 local-path-provisioner를 **별도로 설치**한다. Kubernetes 기본 기능이 아니다.

```yaml
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer   # 파드가 스케줄된 노드에 볼륨 생성
reclaimPolicy: Retain                     # PVC 삭제가 데이터 삭제가 아니다
allowVolumeExpansion: false               # 확장 불가 — 크기는 처음에 확정
```

`local-path-config` ConfigMap의 0777 setup 스크립트를 복원한다. 기본값으로 두면
non-root 컨테이너(postgres, airflow 등 임의 UID)가 볼륨에 쓰지 못해 기동에 실패한다.

## 2. 노드 배치 강제 — 어디서 강제되는가

**StorageClass에는 nodeAffinity를 적을 수 없다.** 배치는 두 지점에서 강제한다.

**(a) 워크로드에서** — 각 StatefulSet/Deployment에 `nodeSelector` 또는 `nodeAffinity`.
이것이 1차 방어선이다.

**(b) provisioner ConfigMap에서** — `nodePathMap`에서 `DEFAULT_PATH_FOR_NON_LISTED_NODES`
항목을 **제거하고** 허용할 노드만 명시한다. 목록에 없는 노드에서는 프로비저닝이 실패하므로,
워크로드에 nodeSelector를 깜빡해도 조용히 잘못된 노드에 볼륨이 생기지 않는다.

```json
{ "nodePathMap": [
    { "node": "k8s-worker1", "paths": ["/opt/local-path-provisioner"] },
    { "node": "k8s-worker2", "paths": ["/opt/local-path-provisioner"] }
] }
```

더 엄격하게 가려면 provisioner를 두 개 띄워 StorageClass를 분리한다
(`local-path-data` → worker1, `local-path-obs` → worker2). 잘못된 배치가 아예 불가능해진다.

### 순서가 중요하다

`WaitForFirstConsumer`는 **파드가 처음 스케줄되는 순간** 볼륨 위치를 결정한다.
그 시점 이후 그 파드는 영구히 그 노드에 고정된다. 따라서 `nodeSelector`는
**첫 배포 전에** 들어가 있어야 한다. 나중에 추가해도 이미 만들어진 PV는 움직이지 않는다.

## 3. 배치 (확정)

관측 계층과 데이터 계층을 **다른 노드로 분리**한다. 한쪽 장애가 다른 쪽을 진단할
수단까지 앗아가지 않게 하기 위해서다.

| 노드 | 워크로드 | PVC |
| --- | --- | --- |
| `k8s-worker1` (4 vCPU / 9.7 GiB) | CNPG, Qdrant, private corpus | 20 + 15 + 10 + 15(백업) GiB |
| `k8s-worker2` (2 vCPU / 5.8 GiB) | Prometheus, Tempo | 25 + 10 GiB |
| `k8s-cp` | 없음 (스케줄 금지) | — |

Grafana는 무상태이므로 PVC가 없고 배치도 자유롭다.

## 4. PVC의 용량은 강제되지 않는다

**`local-path`는 디렉토리를 만들 뿐이고, 요청한 용량을 강제하지 않는다.**
쿼터도, 제한도 없다. 실측으로 확인된 사실이다 — 재구축 직전 클러스터의 PVC 요청 합계는
**234 Gi**였는데, 실제 워커 디스크는 77 GiB와 67 GiB뿐이었다. 그런데도 전부 `Bound`였다.

| PVC | 요청 | 실제 |
| --- | --- | --- |
| `logs-airflow-triggerer-0` | 100 Gi | 디렉토리 하나 |
| `logs-airflow-worker-0` | 100 Gi | 디렉토리 하나 |
| `mlflow-artifacts-pvc` | 20 Gi | 디렉토리 하나 |
| 합계 | 234 Gi | 디스크는 77 + 67 GiB |

### 결과 — 우리 설계에 미치는 영향

1. **문서의 PVC 크기표는 계획일 뿐 상한이 아니다.** 20 GiB로 적어도 그 이상 쓴다
2. **실제 상한은 애플리케이션 설정뿐이다.** 따라서 다음은 선택이 아니라 **필수**다
   - Prometheus: `retention.time`과 **`retention.size` 둘 다** 설정
   - Tempo: 보존 기간과 블록 크기 상한 설정
   - CNPG: WAL 보존과 덤프 로테이션 상한
3. **백스톱은 노드 disk-pressure eviction뿐이다.** 그런데 축출은 파드를 죽이며,
   무엇이 죽을지는 PriorityClass가 정한다. 관측 스택이 죽으면 원인을 볼 수단이 사라진다

### 그래서 필요한 것

- **PVC 사용률이 아니라 노드 디스크 여유를 감시한다.** PVC 단위 사용률은 의미가 없다
- 디스크 여유 알림을 **eviction threshold보다 먼저** 울리게 건다
- 관측 파드에 높은 PriorityClass를 주어, 압박 시 stateless 앱이 먼저 축출되게 한다

## 5. PVC 삭제는 데이터 삭제가 아니다 — 운영 규칙

`Retain` 정책의 결과:

- PVC를 지워도 PV는 `Released` 상태로 남고, **노드 디스크의 디렉토리도 남는다**
- `Released` PV는 자동으로 재사용되지 않는다. 새 PVC는 새 PV를 만든다
- 방치하면 디스크만 계속 줄어든다. 확장 불가 환경에서 이는 조용한 고갈이다

**규칙: PVC를 삭제할 때는 항상 두 단계를 함께 수행한다.**

```bash
kubectl delete pvc <name> -n <ns>
kubectl get pv | grep Released                    # 남은 PV 확인
kubectl delete pv <pv-name>                       # PV 오브젝트 제거
# 그리고 해당 노드에서
sudo rm -rf /opt/local-path-provisioner/<pv-name>_<ns>_<pvc-name>
```

정기적으로 `Released` PV가 없는지 확인한다. 이것을 알림 항목으로 둔다.

**실증 사례**: 재구축 직전 클러스터에 `pvc-99da511f...`가 `Released` 상태로 20일간
남아 있었다. `vllm-affinity-proof-before`의 PVC를 지우고 다시 만들면서 생긴 고아 볼륨으로,
아무도 쓰지 않는데 노드 디스크를 붙들고 있었다. 이 규칙이 필요한 이유다.

## 6. 무엇이 백업이고 무엇이 아닌가

| 수단 | 막아주는 것 | **막지 못하는 것** |
| --- | --- | --- |
| `pg_dump` / `pg_dumpall` → 로컬 PVC | 논리적 실수, 마이그레이션 실패, 잘못된 DELETE | worker1 디스크 손실, Proxmox 호스트 장애 |
| Proxmox VM 스냅샷 | 재구축 실패 시 되돌리기 | 같은 물리 디스크 손상 — 스냅샷도 같이 사라진다 |
| (없음) | — | **재해복구 전체** |

**오프사이트 사본이 없다. 따라서 이 시스템에는 재해복구가 없다.**
포트폴리오와 문서에서 "백업 체계를 갖췄다"고 쓰지 않는다. 정확한 서술은:

> 논리적 실수에 대한 복구 절차는 있고, 검증된 복구 리허설을 수행한다.
> 호스트 디스크 손실에 대한 재해복구는 v1 범위 밖이며, 그 경우 수동 재구축한다.

## 7. 저장소별 복구 전략

### PostgreSQL (CNPG)

`pg_dump`만으로는 **role과 전역 설정이 빠진다.** 복구 리허설은 반드시 이 순서를 포함한다.

```bash
# 백업 — 둘 다 필요하다
pg_dumpall --globals-only > globals.sql     # role, 권한, 전역 파라미터
pg_dump -Fc persona_app  > persona_app.dump
pg_dump -Fc persona_corpus > persona_corpus.dump

# 복구 리허설 — 빈 네임스페이스의 새 CNPG 클러스터에서
psql -f globals.sql                          # role 먼저
pg_restore -d persona_app persona_app.dump
pg_restore -d persona_corpus persona_corpus.dump
```

**D2 완료 조건**: 빈 클러스터에 role까지 포함해 복구되고, `corpus_reader`가
`persona_corpus`에 SELECT만 가능한 상태가 재현될 것.

### source of truth는 세 층이다

"원본이 어디 있느냐"는 층에 따라 답이 다르다. 뭉뚱그리면 복구 절차가 틀어진다.

| 층 | 무엇 | 어디 | 소실 시 |
| --- | --- | --- | --- |
| **원천 SoT** | 권한 있는 원본 TXT/PDF | **사용자 로컬** (클러스터 밖) | 복구 불가 — 유일하게 진짜 지켜야 할 것 |
| **온라인 serving SoT** | chunk 텍스트와 메타데이터 | PostgreSQL `persona_corpus` | 원천에서 재처리 |
| **파생 인덱스** | 벡터와 검색 필터 | Qdrant | 언제든 재생성 |

Gateway가 실제 인용문을 읽는 곳은 **PostgreSQL**이고, Qdrant는 `chunk_id`를 찾아주는
인덱스일 뿐이다. 따라서 Qdrant 소실은 서비스 중단이지 데이터 손실이 아니다.

### Qdrant — 백업하지 않는다. 재생성한다

```
사용자 로컬의 원본 TXT/PDF        ← 원천 SoT
  → persona-ingestion 파서
  → canonical JSONL (corpus PVC)
  → chunking
  → PostgreSQL persona_corpus     ← 온라인 serving SoT
  → embedding
  → Qdrant 컬렉션                  ← 파생 인덱스
```

재생성이 **같은 결과를 내려면** 다음이 고정·기록되어야 한다. 하나라도 흔들리면
재생성된 컬렉션은 원래와 다른 것이 되고, 이전 실험 결과와 비교할 수 없다.

**파싱·청킹 단계**

- parser version (`transcript-txt-v1` 등)
- chunking 설정 (윈도우 크기, 오버랩, 토크나이저)
- `dataset_version`

**임베딩·인덱스 단계**

- embedding 모델 이름과 **revision**
- 임베딩 서비스의 **컨테이너 이미지 digest**
- 거리 방식 (cosine / dot / euclid)
- 컬렉션 설정 (벡터 차원, HNSW 파라미터, quantization 여부)

이 값들은 Qdrant payload와 `persona_corpus`에 함께 남긴다.

### 재생성 검증 — 두 단계로 나눈다

`text_hash` 일치는 **파서와 청킹까지만** 검증한다. 임베딩이 같은지는 말해주지 않는다.
같은 텍스트라도 모델 revision이나 런타임이 바뀌면 벡터가 달라지고, 검색 순위가 바뀐다.

1. **파싱·청킹 검증** — 재생성된 chunk 집합의 `text_hash` 집합이 원래와 일치
2. **검색 동등성 검증** — 고정된 테스트 질문 세트로 **top-k 결과를 비교**.
   `chunk_id` 순서와 점수가 허용 오차 안에 있어야 한다

2번을 통과해야 "재생성했다"고 말할 수 있다. 테스트 질문 세트와 기대 결과는
`persona-ingestion`에 합성 데이터 기준으로 고정해 둔다.

### Prometheus / Tempo

백업하지 않는다. 관측 데이터는 소실되어도 시스템이 복구되며, 보존 기간이 짧다.
**단, 실험 결과 보고서는 Prometheus에 의존하지 않는다** — 집계된 수치를
`persona-ops-lab`의 실험 기록에 파일로 남긴다. TSDB가 사라져도 결론은 남아야 한다.

### private corpus PVC

사용자 로컬 원본에서 재생성 가능하므로 별도 백업을 두지 않는다.
단, `source_manifest.yaml`은 재생성에 필요하므로 원본 파일과 함께 사용자 로컬에 보관한다.

## 8. 완료 조건에 포함할 문장

D1 이후 문서와 포트폴리오에 명시적으로 적는다.

- **worker1 장애 시 CNPG와 Qdrant는 자동 복구되지 않는다.** 새 노드에서 수동 재구축한다
- **worker2 장애 시 Prometheus·Tempo 데이터는 소실된다.** 재수집 외 복구 수단이 없다
- 두 경우 모두 감수한 설계이며, HA를 주장하지 않는다
