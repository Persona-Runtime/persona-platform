# persona-platform — 기획 문서

## 목적

AWS GPU worker와 home Kubernetes의 desired state를 GitOps 방식으로 관리한다. 이 레포만 인프라·배포·보안 정책을 소유한다.

## 책임

- Terraform: dedicated AWS VPC, EC2 GPU worker, encrypted gp3 EBS, IAM, Security Group, Secrets Manager
- bootstrap: Tailscale one-off auth key, SSM access, short-lived kubeadm join runbook
- Helm: Traefik, Argo CD, GPU Operator, Qdrant, kube-prometheus-stack
- Kustomize: persona-web/gateway/ingestion/vLLM, NetworkPolicy, Gateway API routes
- Argo CD application과 image digest promotion
- Tailscale grants/policy tests, backup/restore runbook

## 고정 아키텍처

- home Control Plane 1 + home Worker pool 2 + AWS GPU worker 1
- Tailscale은 node underlay, 기존 CNI는 Pod data plane
- AWS GPU worker: `g6.xlarge` 우선, vLLM 1 replica, tensor parallel size 1
- GPU AMI가 NVIDIA driver/toolkit을 소유하고, GPU Operator는 `driver.enabled=false`, `toolkit.enabled=false`
- public inbound 0. SSM은 break-glass. public ingress/Funnel/SSH/API/metrics/NodePort 노출 금지
- Tailscale Serve → Traefik Gateway API → `persona-web`/`persona-gateway`만 Tailnet에 노출

## 제외

- CNI migration, Multus/SR-IOV/RDMA, distributed inference
- cluster/GPU autoscaling, Spot, HA, public TLS domain
- app business logic, parser 구현, dashboard query 구현

## 구현 루프

### Loop 1 — inventory and guardrails

- 현재 K8s/CNI/CIDR/API endpoint/Tailscale interface를 inventory한다.
- 완료 조건: LAN/VPC/Tailnet/Pod/Service CIDR 비중첩과 CNI flow를 문서화.

### Loop 2 — AWS bootstrap

- VPC/IAM/SG/EC2/EBS/SSM/Secrets Manager를 Terraform으로 만든다.
- 완료 조건: public inbound 0, least-privilege role, GPU quota/AZ capacity 확인.

### Loop 3 — worker join and CNI gate

- TLS SAN, Node InternalIP, `kubernetes.default` EndpointSlice, PMTU를 정렬한다.
- 완료 조건: Pod-IP/ClusterIP/DNS/NetworkPolicy/large payload/streaming/DCGM scrape e2e 통과.

### Loop 4 — GPU serving platform

- GPU Operator/DCGM/vLLM/Gateway API/NetworkPolicy를 배포한다.
- 완료 조건: fixed 1-token vLLM canary가 readiness를 결정하고 non-GPU workload는 GPU node에 배치되지 않음.

### Loop 5 — GitOps and recovery

- Argo CD manual sync, image digest promotion, backup/restore dry-run을 만든다.
- 완료 조건: etcd/PostgreSQL/Qdrant/raw PV restore evidence와 rollback commit 존재.

## 검증 기준

- `kubectl get nodes -o wide`의 InternalIP/API endpoint가 설계한 Tailnet 경로와 일치
- GPU node path down 시 Gateway 503, 데이터 서비스가 GPU node에 없음
- no public port exposure, Tailnet grant policy test 통과
- CNI/MTU 실험은 disposable/canary와 maintenance window에서만 실행
