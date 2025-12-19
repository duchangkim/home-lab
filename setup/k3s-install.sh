#!/usr/bin/env bash
set -euo pipefail

# Ubuntu 단일 노드 기준 k3s 설치 스크립트
# - k3s 설치/재설치가 아니라 "최초 설치"를 가볍게 자동화하는 목적
# - 인프라/ArgoCD 설치는 별도: setup/bootstrap-infra.sh

usage() {
  cat <<'EOF'
Usage:
  ./setup/k3s-install.sh [options]

Options:
  --use-big-disk                 /mnt/ncdata가 있을 때 data-dir을 /mnt/ncdata/k3s로 설정
  --data-dir <path>              k3s data-dir 경로 지정 (예: /mnt/ncdata/k3s)
  --stop-nginx                   80/443 점유 시 nginx가 실행 중이면 중지/disable 시도
  --skip-port-check              80/443/6443 포트 점유 체크를 건너뜀
  --k3s-extra-args "<args>"      k3s 설치 시 추가로 넘길 인자 (예: "--disable servicelb")
  -h, --help                     도움말

Environment (optional):
  INSTALL_K3S_VERSION            설치할 k3s 버전 고정 (예: v1.30.5+k3s1)
  INSTALL_K3S_CHANNEL            설치 채널 (예: stable)

Examples:
  ./setup/k3s-install.sh
  ./setup/k3s-install.sh --use-big-disk
  ./setup/k3s-install.sh --data-dir /mnt/ncdata/k3s --stop-nginx
EOF
}

USE_BIG_DISK="false"
DATA_DIR=""
STOP_NGINX="false"
SKIP_PORT_CHECK="false"
K3S_EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --use-big-disk)
      USE_BIG_DISK="true"
      shift
      ;;
    --data-dir)
      DATA_DIR="${2:-}"
      shift 2
      ;;
    --stop-nginx)
      STOP_NGINX="true"
      shift
      ;;
    --skip-port-check)
      SKIP_PORT_CHECK="true"
      shift
      ;;
    --k3s-extra-args)
      K3S_EXTRA_ARGS="${2:-}"
      shift 2
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' 명령이 필요합니다." >&2; exit 1; }
}

is_mountpoint() {
  local p="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "${p}"
    return $?
  fi
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -rn "${p}" >/dev/null 2>&1
    return $?
  fi
  # mountpoint/findmnt가 없으면 엄격 검증 불가
  return 2
}

port_in_use() {
  local port="$1"
  sudo lsof -i :"${port}" >/dev/null 2>&1
}

echo "🏠 k3s 설치 (Ubuntu)"
echo "====================="
echo ""

need_cmd curl
need_cmd sudo

if [[ "${SKIP_PORT_CHECK}" != "true" ]]; then
  echo "📋 포트 사용 상태 확인 (80/443/6443)..."
  for port in 80 443 6443; do
    if port_in_use "${port}"; then
      echo "⚠️  포트 ${port} 사용 중:"
      sudo lsof -i :"${port}" || true
      echo ""
    fi
  done

  # 80/443는 Traefik이 바인딩하므로 충돌 시 조치 필요
  if port_in_use 80 || port_in_use 443; then
    if [[ "${STOP_NGINX}" == "true" ]]; then
      if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        echo "🛑 nginx 중지/disable 시도 중 (80/443 충돌 해결)..."
        sudo systemctl stop nginx
        sudo systemctl disable nginx
        echo "✅ nginx 중지 완료"
      fi
    fi

    if port_in_use 80 || port_in_use 443; then
      echo "ERROR: 80/443 포트가 사용 중입니다. Traefik이 기동 실패할 수 있습니다." >&2
      echo "  - nginx/apache 등을 중지하거나, k3s에서 Traefik 포트 구성을 조정하세요." >&2
      echo "  - nginx만이면: ./setup/k3s-install.sh --stop-nginx" >&2
      exit 1
    fi
  fi
fi

if [[ -z "${DATA_DIR}" && "${USE_BIG_DISK}" == "true" ]]; then
  DATA_DIR="/mnt/ncdata/k3s"
fi

if [[ -n "${DATA_DIR}" ]]; then
  # /mnt/ncdata 아래를 쓰는 경우: "디렉토리 존재"만으로는 위험(재설치 후 루트 디스크에 폴더만 생길 수 있음)
  if [[ "${DATA_DIR}" == /mnt/ncdata/* ]]; then
    if [[ ! -d "/mnt/ncdata" ]]; then
      echo "ERROR: /mnt/ncdata 가 없습니다. 큰 디스크를 /mnt/ncdata에 마운트 후 다시 실행하세요." >&2
      exit 1
    fi

    if is_mountpoint "/mnt/ncdata"; then
      : # OK
    else
      rc=$?
      if [[ "${rc}" -eq 2 ]]; then
        echo "⚠️  경고: mountpoint/findmnt가 없어 /mnt/ncdata 마운트 여부를 확실히 검증할 수 없습니다." >&2
        echo "   재설치 후에는 /etc/fstab 등으로 /mnt/ncdata 자동 마운트를 반드시 확인하세요." >&2
      else
        echo "ERROR: /mnt/ncdata 는 마운트포인트가 아닙니다. (큰 디스크가 마운트되지 않은 상태일 수 있음)" >&2
        echo "  - 재설치 후에는 /etc/fstab 설정 또는 수동 mount를 확인하세요." >&2
        exit 1
      fi
    fi
  fi

  echo "💾 k3s data-dir 설정: ${DATA_DIR}"
  sudo mkdir -p "${DATA_DIR}"
  sudo mkdir -p /etc/rancher/k3s
  sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
# Managed by setup/k3s-install.sh
data-dir: ${DATA_DIR}
EOF
  echo "✅ /etc/rancher/k3s/config.yaml 생성 완료"
  echo ""
fi

if command -v k3s >/dev/null 2>&1; then
  echo "⚠️  k3s가 이미 설치되어 있습니다."
  k3s --version || true
  echo ""
  echo "이미 설치된 k3s를 그대로 사용합니다. (재설치/업그레이드는 이 스크립트 범위 밖입니다.)"
  exit 0
fi

echo "📦 k3s 설치 중..."
INSTALL_CMD_ARGS=(--write-kubeconfig-mode 644)
if [[ -n "${K3S_EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  INSTALL_CMD_ARGS+=(${K3S_EXTRA_ARGS})
fi

curl -sfL https://get.k3s.io | sh -s - "${INSTALL_CMD_ARGS[@]}"
echo "✅ k3s 설치 완료"
echo ""

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "🔎 클러스터 상태 확인:"
kubectl get nodes
echo ""

echo "다음 단계:"
echo "  - 인프라/ArgoCD 설치: ./setup/bootstrap-infra.sh --overlay production"
echo "  - (옵션) 앱 적용: ./setup/bootstrap-infra.sh --overlay production --apply-apps"


