# OpenClaw Kubernetes Deployment Troubleshooting

OpenClaw을 k3s 클러스터에 배포하면서 발생한 문제들과 해결 방법을 정리합니다.

## Environment

- **Cluster**: k3s on Ubuntu 24.04 (Intel N95, 8GB RAM)
- **Ingress**: Traefik (k3s 기본)
- **TLS**: cert-manager + Let's Encrypt
- **GitOps**: ArgoCD with auto-sync + self-heal
- **OpenClaw Version**: 2026.2.2

---

## Issue 1: ArgoCD Application Controller OOMKilled

### Symptom
ArgoCD application-controller Pod가 반복적으로 OOMKilled 상태로 재시작됨.

### Cause
기본 메모리 limit(512Mi)이 homelab 환경의 여러 Application 관리에 부족.

### Solution
```yaml
# infrastructure/argocd/kustomization.yaml
patches:
  - patch: |
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: "768Mi"
    target:
      kind: Deployment
      name: argocd-application-controller
```

---

## Issue 2: OpenClaw Image Tag Format

### Symptom
```
Failed to pull image "ghcr.io/openclaw/openclaw:v2026.2.2": tag does not exist
```

### Cause
OpenClaw 이미지 태그에 `v` prefix가 없음. GitHub releases는 `v2026.2.2`이지만 container tag는 `2026.2.2`.

### Solution
```yaml
image: ghcr.io/openclaw/openclaw:2026.2.2  # Not v2026.2.2
```

---

## Issue 3: Gateway Bind Address

### Symptom
```
[gateway] listening on ws://127.0.0.1:18789
```
Pod 내부에서만 접근 가능하고 외부에서 연결 불가.

### Cause
OpenClaw 기본 bind가 loopback(127.0.0.1)으로 설정됨.

### Solution
```yaml
command: ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]
```

---

## Issue 4: Gateway Startup Block

### Symptom
Gateway가 시작 시 사용자 입력을 기다리며 블록됨 (컨테이너 환경에서 무한 대기).

### Cause
초기 설정이 없을 때 interactive prompt 표시.

### Solution
```yaml
command: ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789", "--allow-unconfigured"]
```

---

## Issue 5: Control UI "pairing required" Error (Main Issue)

### Symptom
Control UI 접속 시 WebSocket 연결 실패:
```
disconnected (1008): pairing required
[ws] Proxy headers detected from untrusted address. Connection will not be treated as local.
```

### Root Cause Analysis

1. **Reverse Proxy Detection**: OpenClaw이 `X-Forwarded-For` 헤더를 감지하면 연결을 "remote"로 분류
2. **trustedProxies CIDR Bug**: OpenClaw의 CIDR 파싱 버그로 `10.0.0.0/8` 같은 범위가 제대로 인식되지 않음 (GitHub #8552)
3. **Device Authentication**: Remote 연결에는 device pairing이 필요하지만 브라우저 환경에서 진행 어려움
4. **Config File Path**: initContainer가 잘못된 파일명(`openclaw.json`)으로 복사하여 설정 미적용

### Solution

#### 1. Fix Config File Path
```yaml
initContainers:
  - name: init-config
    image: busybox:1.36
    # config.json으로 복사 (openclaw.json 아님)
    # rm -f로 기존 파일 강제 삭제 (PVC에 이전 설정이 남아있을 수 있음)
    command: ['sh', '-c', 'rm -f /home/node/.openclaw/config.json && cp /config-source/openclaw.json /home/node/.openclaw/config.json && chmod 644 /home/node/.openclaw/config.json']
```

#### 2. Configure trustedProxies with Explicit IP
```yaml
# configmap.yaml
data:
  openclaw.json: |
    {
      "gateway": {
        "mode": "local",
        "trustedProxies": ["10.42.0.20", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
        "controlUi": {
          "allowInsecureAuth": true
        }
      }
    }
```

**Key Points:**
- `10.42.0.20`: Traefik Pod IP (CIDR 버그 우회를 위해 명시적 추가)
- `allowInsecureAuth: true`: HTTP 환경에서 token-only 인증 허용 (Traefik이 HTTPS 종료)
- `dangerouslyDisableDeviceAuth`: **사용하지 않음** (보안 위험)

#### 3. Find Traefik Pod IP
```bash
kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik -o wide
```

> **Note**: Traefik Pod IP는 재시작 시 변경될 수 있음. 변경되면 ConfigMap 업데이트 필요.

---

## Security Considerations

### Settings Explained

| Setting | Purpose | Risk Level |
|---------|---------|------------|
| `trustedProxies` | Reverse proxy IP 신뢰 | Low (필수) |
| `allowInsecureAuth` | HTTP에서 token-only 인증 | Medium |
| `dangerouslyDisableDeviceAuth` | Device 인증 완전 비활성화 | **Critical** |

### Recommended Configuration

1. **Always use** `trustedProxies` with explicit proxy IP
2. **Use** `allowInsecureAuth: true` only when behind HTTPS-terminating proxy
3. **Never use** `dangerouslyDisableDeviceAuth` in production

### Gateway Token Security

- Token은 URL parameter로 전달됨
- HTTPS 사용 시 전송 중 보호됨
- Token 유출 시 완전한 접근 권한 노출
- 강력한 랜덤 token 사용 (32+ characters)

---

## Deployment Checklist

- [ ] Image tag에 `v` prefix 없음 확인
- [ ] `--bind lan` 옵션 추가
- [ ] `--allow-unconfigured` 옵션 추가
- [ ] initContainer가 `config.json`으로 복사하는지 확인
- [ ] trustedProxies에 Traefik Pod IP 명시적 추가
- [ ] Gateway token이 Secret으로 관리되는지 확인
- [ ] `dangerouslyDisableDeviceAuth` 미사용 확인

---

## Useful Commands

```bash
# Check OpenClaw logs
kubectl logs -l app=openclaw -f

# Verify config inside pod
kubectl exec deploy/openclaw -- cat /home/node/.openclaw/config.json | jq .

# Get Traefik Pod IP
kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik -o wide

# Force ArgoCD sync after Git push
kubectl patch application openclaw -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Restart OpenClaw pods
kubectl delete pod -l app=openclaw
```

---

## References

- [OpenClaw Security Documentation](https://docs.openclaw.ai/gateway/security)
- [OpenClaw Reverse Proxy Guide](https://docs.openclaw.ai/gateway/security#reverse-proxy-configuration)
- [GitHub Issue #8552 - CIDR parsing bug](https://github.com/openclaw/openclaw/issues/8552)
