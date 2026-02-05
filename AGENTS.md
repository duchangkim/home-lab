# AGENTS.md - Homelab k3s Infrastructure

This document provides guidance for AI coding agents working in this repository.

---

## CRITICAL: Secret Protection Rules

> **THIS IS A PUBLIC REPOSITORY. SECRETS MUST NEVER BE EXPOSED.**

### Absolute Prohibitions

| File Type | Action | Reason |
|-----------|--------|--------|
| `secret.yaml` | **NEVER commit** | Contains plaintext credentials |
| `*.pem`, `*.key` | **NEVER commit** | Private keys |
| `.env` files | **NEVER commit** | Environment secrets |
| API keys, passwords | **NEVER hardcode** | Use secretKeyRef |

### Allowed Secret Files

- `sealed-secret.yaml` - Encrypted by kubeseal, safe to commit
- `secret.yaml.example` - Template with placeholder values only

### Before Every Commit

```bash
# Verify no secrets are staged
git diff --cached --name-only | grep -E "secret\.yaml$|\.env$|\.pem$|\.key$"
# If any output appears, DO NOT COMMIT

# Check .gitignore is protecting secrets
cat .gitignore | grep secret
# Should show: **/secret.yaml
```

### If You Need to Create a Secret

1. Create `secret.yaml` locally (gitignored)
2. Encrypt with kubeseal: `kubeseal --cert=pub-cert.pem -f secret.yaml -w sealed-secret.yaml`
3. Commit only `sealed-secret.yaml`
4. Delete local `secret.yaml` or keep in secure storage

**VIOLATION = CREDENTIAL LEAK = SECURITY INCIDENT**

---

## Project Overview

GitOps-based Kubernetes homelab infrastructure using k3s and ArgoCD. This is **infrastructure-as-code**, not application source code. Changes are deployed via Git push → ArgoCD auto-sync.

**Tech Stack:**
- **Kubernetes**: k3s (lightweight K8s)
- **GitOps**: ArgoCD with App-of-Apps pattern
- **Configuration**: Kustomize overlays (local/production)
- **Ingress**: Traefik
- **TLS**: cert-manager with Let's Encrypt
- **Secrets**: Sealed Secrets (kubeseal)

## Hardware Specifications

This is a **resource-constrained homelab** environment. Configure resource limits conservatively.

| Resource | Spec | Notes |
|----------|------|-------|
| **CPU** | Intel N95 (4 cores, 4 threads) | Low-power efficiency CPU, no hyperthreading |
| **RAM** | 8GB DDR4 | ~3GB available for workloads |
| **OS Disk** | 238GB NVMe SSD | 100GB LVM for root filesystem |
| **Data Disk** | 500GB HDD | Mounted at `/mnt/ncdata` for k3s data |
| **OS** | Ubuntu 24.04 LTS | Kernel 6.8.x |

### Resource Allocation Guidelines

**Total cluster budget** (approximate):
- CPU: 4000m total, ~3500m allocatable
- Memory: 8Gi total, ~7Gi allocatable
- Current usage: ~160m CPU (4%), ~4.7Gi memory (60%)

**Per-application recommendations:**

| App Type | CPU Request | CPU Limit | Memory Request | Memory Limit |
|----------|-------------|-----------|----------------|--------------|
| Lightweight (test-app) | 10m | 100m | 32Mi | 128Mi |
| Standard (Ghost, n8n) | 100m | 500m | 256Mi | 512Mi |
| Heavy (OpenWebUI) | 500m | 2000m | 1Gi | 2Gi |
| Database (MySQL, PostgreSQL) | 100m | 500m | 256Mi | 512Mi |
| Infrastructure (ArgoCD, etc.) | 50m | 200m | 128Mi | 256Mi |

**Important constraints:**
- Always set both `requests` and `limits`
- Leave ~1.5Gi memory headroom for system + k3s
- Avoid CPU limits > 1000m for non-critical apps
- Single replica only (`replicas: 1`) - no HA capacity

## Project Structure

```
├── infrastructure/          # Core infrastructure components
│   ├── argocd/             # ArgoCD installation (Kustomize)
│   ├── cert-manager/       # TLS certificate management
│   │   ├── base/           # Base installation
│   │   └── overlays/       # local/production issuers
│   ├── base/               # Shared infrastructure
│   │   ├── sealed-secrets/ # Secret encryption
│   │   ├── traefik/        # Ingress controller
│   │   └── cloudflared/    # Cloudflare tunnel
│   └── overlays/           # Environment-specific configs
│       ├── local/          # k3d local development
│       └── production/     # Production server
├── applications/           # Application deployments
│   ├── openwebui/         # AI chat interface
│   ├── ghost/             # Headless CMS
│   ├── n8n/               # Workflow automation
│   └── test-app/          # whoami test service
├── argocd/                # ArgoCD Application definitions
│   └── applications/      # App-of-Apps manifests
└── setup/                 # Installation scripts
    ├── k3s-install.sh     # k3s installation (Ubuntu)
    ├── bootstrap-infra.sh # Infrastructure bootstrap
    └── k3d-cluster.sh     # Local dev cluster
```

## Build/Validation Commands

This project has no traditional build system. Validation is done via kubectl/kustomize.

### Validate Manifests

```bash
# Validate a kustomization
kustomize build infrastructure/overlays/production | kubectl apply --dry-run=client -f -

# Validate single manifest
kubectl apply --dry-run=client -f applications/openwebui/deployment.yaml

# Check kustomization syntax
kustomize build applications/openwebui
```

### Local Development (k3d)

```bash
# Create local cluster
./setup/k3d-cluster.sh

# Apply local infrastructure
kubectl apply -k infrastructure/overlays/local/

# Apply specific application
kubectl apply -k applications/openwebui/
```

### Production Deployment

```bash
# Install k3s (first time only)
./setup/k3s-install.sh

# Bootstrap infrastructure
./setup/bootstrap-infra.sh --overlay production

# With ArgoCD apps
./setup/bootstrap-infra.sh --overlay production --apply-apps
```

### Useful kubectl Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# ArgoCD applications
kubectl get applications -n argocd

# Certificates
kubectl get certificate -A

# Logs
kubectl logs -n default -l app=openwebui --tail=100 -f
```

## Code Style Guidelines

### YAML (Kubernetes Manifests)

**Formatting:**
- 2-space indentation (no tabs)
- One blank line between resources in multi-document files
- Use `---` separator between documents

**Resource Structure:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-name
  namespace: default        # Always explicit
  labels:
    app: app-name
    component: frontend     # Use when app has multiple components
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-name
  template:
    metadata:
      labels:
        app: app-name
    spec:
      containers:
        - name: app-name
          image: registry/image:tag  # Comment with source URL
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: ENV_VAR
              value: "string-value"
            - name: SECRET_VAR
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: secret-key
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
```

**Naming Conventions:**
- Resource names: lowercase with hyphens (`openwebui`, `ghost-mysql`)
- Labels: `app`, `component` for pod selection
- Secrets: `{app}-secret` pattern
- PVCs: `{app}-data` or `{app}-{purpose}` pattern
- Services: same name as deployment

**Comments:**
- Korean comments are acceptable (bilingual codebase)
- Add source URLs for container images
- Document non-obvious configurations

### Kustomization Files

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: argocd  # Optional: override namespace

resources:
  - deployment.yaml
  - service.yaml
  - sealed-secret.yaml  # Never plain secret.yaml
```

### Bash Scripts (setup/*.sh)

**Header Pattern:**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Brief description of script purpose
# - Additional context
# - Related scripts

usage() {
  cat <<'EOF'
Usage:
  ./setup/script-name.sh [options]

Options:
  --option-name <value>   Description
  -h, --help              Show help

Examples:
  ./setup/script-name.sh --option value
EOF
}
```

**Argument Parsing:**
```bash
OPTION_NAME="default"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --option-name)
      OPTION_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done
```

**Utility Functions:**
```bash
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' required." >&2; exit 1; }
}
```

**Output Style:**
- Use emoji prefixes for status messages
- Examples: `echo "📦 Installing..."`, `echo "✅ Done"`, `echo "⚠️ Warning"`

## Secret Management

**CRITICAL: Never commit `secret.yaml` files. Only `sealed-secret.yaml`.**

```bash
# Create sealed secret
kubeseal --cert=pub-cert.pem \
  -f applications/{app}/secret.yaml \
  -w applications/{app}/sealed-secret.yaml \
  --format yaml

# Verify .gitignore excludes secrets
# Pattern: **/secret.yaml (excluded), !**/sealed-secret.yaml (included)
```

## ArgoCD Application Pattern

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/duchangkim/home-lab.git
    targetRevision: main
    path: applications/app-name
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Common Patterns

### Multi-container Apps (e.g., Ghost + MySQL)

- Separate deployments: `deployment-app.yaml`, `deployment-db.yaml`
- Use component labels: `component: frontend`, `component: database`
- Internal service for DB: `ghost-mysql` (DNS-resolvable name)

### InitContainers for Setup

Used when base image needs modification (e.g., installing S3 adapter for Ghost):
```yaml
initContainers:
  - name: setup-task
    image: appropriate-image
    command: ["sh", "-c", "setup commands"]
    volumeMounts:
      - name: shared-volume
        mountPath: /path
```

### Resource Limits

**REQUIRED** - This homelab has limited resources (Intel N95 / 8GB RAM). Always specify limits:

```yaml
resources:
  requests:
    cpu: "100m"      # Minimum guaranteed
    memory: "256Mi"
  limits:
    cpu: "500m"      # Maximum allowed
    memory: "512Mi"
```

See [Hardware Specifications](#hardware-specifications) for allocation guidelines.

## Troubleshooting Documentation

After resolving infrastructure or deployment issues, **always document the troubleshooting process** in the `docs/` directory.

**Required content:**
- Environment context (versions, cluster state)
- Symptom (error messages, logs)
- Root cause analysis
- Step-by-step solution
- Prevention / verification commands

**File location:** `docs/{topic}-troubleshooting.md`

**Existing docs:**
- `docs/openclaw-troubleshooting.md` - OpenClaw deployment issues
- `docs/argocd-crd-sync-troubleshooting.md` - ArgoCD CRD annotation size limit

## Validation Checklist

Before committing changes:

- [ ] `kustomize build <path>` succeeds
- [ ] `kubectl apply --dry-run=client -f <file>` validates
- [ ] No `secret.yaml` files staged (only `sealed-secret.yaml`)
- [ ] Resource limits specified for new deployments
- [ ] Namespace explicitly set in metadata
- [ ] Labels consistent with existing patterns
- [ ] Troubleshooting documented if an issue was resolved
