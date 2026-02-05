# ArgoCD CRD Annotation Size Limit Troubleshooting

ArgoCD의 `applicationsets.argoproj.io` CRD가 Kubernetes annotation 크기 제한(262144 bytes)을 초과하여 infrastructure Application sync가 실패하는 문제의 해결 기록입니다.

## Environment

- **ArgoCD**: v3.3.0
- **Cluster**: k3s on Ubuntu 24.04
- **ArgoCD 설치 방식**: Kustomize + 공식 `install.yaml` remote resource

## Symptom

infrastructure Application이 `OutOfSync` 상태에서 sync 실패:

```
Failed last sync attempt: one or more objects failed to apply, reason:
  Failed to perform client-side apply migration: failed to perform client-side apply
  migration on manager kubectl-client-side-apply: error when patching:
  CustomResourceDefinition.apiextensions.k8s.io "applicationsets.argoproj.io" is invalid:
  metadata.annotations: Too long: may not be more than 262144 bytes (retried 5 times).
```

다른 모든 Application은 정상 동작, infrastructure만 영향받음.

## Root Cause

1. **annotation 크기 제한**: `kubectl apply`(client-side apply)는 리소스 전체를 `kubectl.kubernetes.io/last-applied-configuration` annotation에 저장. ArgoCD의 `applicationsets.argoproj.io` CRD는 스펙이 매우 커서 이 annotation만 261KB+로 Kubernetes의 262144 bytes 제한을 초과.

2. **SSA migration 실패**: `ServerSideApply=true` syncOption이 이미 설정되어 있었지만, 기존 client-side apply 리소스를 SSA로 전환하는 "migration" 과정에서 다시 annotation을 생성하려 해서 같은 크기 제한에 걸림.

3. **auto-sync 중단**: retry limit(5회)에 도달 후 ArgoCD가 같은 Git revision에 대해 재시도를 거부.

### 관련 GitHub Issues

- https://github.com/argoproj/argo-cd/issues/7131
- https://github.com/argoproj/argo-cd/issues/5704

## Solution

### Step 1: 과대 annotation 제거

```bash
kubectl annotate crd applicationsets.argoproj.io \
  kubectl.kubernetes.io/last-applied-configuration-
```

### Step 2: managed fields에서 client-side-apply manager 제거

기본 `kubectl get -o json`으로는 managed fields가 보이지 않음. `--show-managed-fields` 플래그 필수:

```bash
# managed fields 확인
kubectl get crd applicationsets.argoproj.io -o json --show-managed-fields \
  | jq '[.metadata.managedFields[] | {manager, operation}]'
```

`kubectl-client-side-apply` manager가 남아있으면 ArgoCD가 migration을 계속 시도함. 해당 항목의 인덱스를 확인 후 제거:

```bash
# 인덱스 확인 후 제거 (예: index 1)
kubectl patch crd applicationsets.argoproj.io --type=json \
  -p '[{"op":"remove","path":"/metadata/managedFields/1"}]' \
  --show-managed-fields
```

### Step 3: ArgoCD auto-sync 재시도 트리거

ArgoCD는 이전에 실패한 Git revision에 대해 재시도를 거부함. 새 revision이 필요:

```bash
git commit --allow-empty -m "chore: trigger ArgoCD re-sync for infrastructure app"
git push
```

그 후 hard refresh:

```bash
kubectl patch application infrastructure -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Prevention

infrastructure Application에 `ServerSideApply=true` syncOption이 설정되어 있어야 함:

```yaml
# argocd/applications/infrastructure.yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
```

SSA를 사용하면 `last-applied-configuration` annotation을 생성하지 않으므로 크기 제한 문제가 발생하지 않음.

## Verification

```bash
# 모든 Application이 Synced + Healthy인지 확인
kubectl get application -n argocd

# CRD annotation 크기 확인 (0이어야 함)
kubectl get crd applicationsets.argoproj.io \
  -o jsonpath='{.metadata.annotations}' | wc -c

# managed fields에 kubectl-client-side-apply가 없는지 확인
kubectl get crd applicationsets.argoproj.io -o json --show-managed-fields \
  | jq '[.metadata.managedFields[] | .manager]'
```
