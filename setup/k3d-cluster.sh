#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="homelab"

echo "🚀 k3d 클러스터 생성: ${CLUSTER_NAME}"

# 포트 사용 상태 확인
echo "📋 포트 사용 상태 확인 중..."
for port in 80 443 8080 3000; do
    if lsof -i :$port > /dev/null 2>&1; then
        echo "⚠️  포트 $port 이미 사용중!"
        lsof -i :$port
    fi
done

# 기존 클러스터가 있다면 삭제
if k3d cluster list | grep -q "${CLUSTER_NAME}"; then
    echo "⚠️  기존 클러스터 삭제 중..."
    k3d cluster delete ${CLUSTER_NAME}
fi

# 새 클러스터 생성 (포트 충돌 방지를 위해 다른 포트 사용)
k3d cluster create ${CLUSTER_NAME} \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --port "8080:8080@loadbalancer" \
    --port "3001:3000@loadbalancer" \
    --agents 1

echo "✅ 클러스터 생성 완료"

# Traefik 준비 대기
echo "⏳ Traefik이 준비될 때까지 대기 중..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=300s

# CRD 확인 (120초 타임아웃)
echo "⏳ Traefik CRD 확인 중..."
CRD_TIMEOUT=120
CRD_ELAPSED=0
while ! kubectl get crd ingressroutes.traefik.io > /dev/null 2>&1; do
    if [[ ${CRD_ELAPSED} -ge ${CRD_TIMEOUT} ]]; then
        echo "❌ Traefik CRD 대기 타임아웃 (${CRD_TIMEOUT}초)"
        echo "   수동 확인: kubectl get crd | grep traefik"
        exit 1
    fi
    sleep 2
    CRD_ELAPSED=$((CRD_ELAPSED + 2))
    echo "  - CRD 대기 중... (${CRD_ELAPSED}/${CRD_TIMEOUT}초)"
done
echo "✅ Traefik 준비 완료!"

echo ""
echo "🔎 클러스터 상태 확인:"
kubectl config current-context
kubectl get nodes

echo ""
echo "🎉 로컬 k3d 클러스터 준비 완료!"
echo ""
echo "다음 단계:"
echo "  1. 로컬 인프라 설치: kubectl apply -k infrastructure/overlays/local/"
echo "  2. 애플리케이션 등록: kubectl apply -f argocd/applications/root-app.yaml"
