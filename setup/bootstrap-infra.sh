#!/usr/bin/env bash
set -euo pipefail

# k3s 클러스터 위에 인프라(ArgoCD/cert-manager/sealed-secrets/traefik 등)를 올리는 부트스트랩 스크립트
# - k3s 설치는 별도: setup/k3s-install.sh

usage() {
  cat <<'EOF'
Usage:
  ./setup/bootstrap-infra.sh [options]

Options:
  --overlay <production|local>   적용할 인프라 오버레이 (default: production)
  --apply-apps                  ArgoCD App-of-Apps(root-app)까지 적용
  --apps-mode <root|all>        apply-apps 시 적용 방식 (default: root)
  --repo-url-hint               repoURL 변경이 필요할 수 있다는 안내 출력
  --timeout <seconds>           kubectl wait timeout (default: 300)
  -h, --help                    도움말

Environment (optional):
  KUBECONFIG                     kubeconfig 경로 (default: /etc/rancher/k3s/k3s.yaml)

Examples:
  ./setup/bootstrap-infra.sh
  ./setup/bootstrap-infra.sh --overlay production --apply-apps
  ./setup/bootstrap-infra.sh --overlay local
EOF
}

OVERLAY="production"
APPLY_APPS="false"
APPS_MODE="root"
TIMEOUT_SECONDS="300"
REPO_URL_HINT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay)
      OVERLAY="${2:-}"
      shift 2
      ;;
    --apply-apps)
      APPLY_APPS="true"
      shift
      ;;
    --apps-mode)
      APPS_MODE="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --repo-url-hint)
      REPO_URL_HINT="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${OVERLAY}" in
  production|local) ;;
  *)
    echo "ERROR: --overlay 는 production 또는 local 이어야 합니다. (현재: ${OVERLAY})" >&2
    exit 2
    ;;
esac

case "${APPS_MODE}" in
  root|all) ;;
  *)
    echo "ERROR: --apps-mode 는 root 또는 all 이어야 합니다. (현재: ${APPS_MODE})" >&2
    exit 2
    ;;
esac

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' 명령이 필요합니다." >&2; exit 1; }
}

need_cmd kubectl

echo "📦 인프라 부트스트랩 (${OVERLAY})"
echo "=========================="
echo ""

echo "🔎 클러스터 연결 확인..."
kubectl get nodes >/dev/null
echo "✅ 클러스터 연결 OK"
echo ""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY_PATH="${ROOT_DIR}/infrastructure/overlays/${OVERLAY}"

if [[ ! -d "${OVERLAY_PATH}" ]]; then
  echo "ERROR: 오버레이 경로가 없습니다: ${OVERLAY_PATH}" >&2
  exit 1
fi

echo "🧱 인프라 적용: infrastructure/overlays/${OVERLAY}"
kubectl apply -k "${OVERLAY_PATH}"
echo ""

echo "⏳ 컨트롤러 준비 대기..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout="${TIMEOUT_SECONDS}s" || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout="${TIMEOUT_SECONDS}s" || true
echo ""

echo "🔐 ArgoCD 관리자 비밀번호 (admin):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || true
echo ""
echo ""

if [[ "${REPO_URL_HINT}" == "true" ]]; then
  echo "⚠️  참고: 레포를 포크/이전했다면 argocd Application의 repoURL을 실제 레포로 수정해야 합니다."
  echo "   - 예: argocd/applications/root-app.yaml, argocd/applications/infrastructure.yaml"
  echo ""
fi

if [[ "${APPLY_APPS}" == "true" ]]; then
  echo "🚀 ArgoCD Applications 적용 중..."
  case "${APPS_MODE}" in
    root)
      kubectl apply -f "${ROOT_DIR}/argocd/applications/root-app.yaml"
      ;;
    all)
      kubectl apply -f "${ROOT_DIR}/argocd/applications/"
      ;;
  esac
  echo "✅ Applications 적용 완료"
  echo ""
fi

echo "다음 확인:"
echo "  - kubectl get applications -n argocd"
echo "  - kubectl get certificate -A"


