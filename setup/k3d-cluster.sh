#!/bin/bash
set -e

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

# kubectl 컨텍스트 확인
kubectl config current-context
kubectl get nodes

echo ""
echo "🎉 로컬 k3s 클러스터 준비 완료!"
echo "다음 명령어로 ArgoCD를 설치하세요:"
echo "  kubectl create namespace argocd"
echo "  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
