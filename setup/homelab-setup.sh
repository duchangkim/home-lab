#!/bin/bash
set -e

echo "🏠 홈랩 k3s + ArgoCD 설치 스크립트"
echo "=================================="
echo ""

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. nginx 확인 및 안내
echo "📋 Step 1: nginx 상태 확인"
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "${YELLOW}⚠️  nginx가 실행 중입니다.${NC}"
    echo "k3s Traefik이 80/443 포트를 사용하므로 nginx를 중지해야 합니다."
    echo ""
    read -p "nginx를 중지하고 제거하시겠습니까? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo systemctl stop nginx
        sudo systemctl disable nginx
        echo -e "${GREEN}✅ nginx 중지 완료${NC}"
    else
        echo -e "${RED}❌ nginx가 실행 중이면 k3s 설치가 실패할 수 있습니다.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✅ nginx가 실행 중이지 않습니다.${NC}"
fi
echo ""

# 2. 포트 확인
echo "📋 Step 2: 포트 사용 상태 확인"
for port in 80 443 6443; do
    if sudo lsof -i :$port > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  포트 $port 이미 사용 중!${NC}"
        sudo lsof -i :$port
    else
        echo -e "${GREEN}✅ 포트 $port 사용 가능${NC}"
    fi
done
echo ""

# 3. k3s 설치
echo "📋 Step 3: k3s 설치"
if command -v k3s &> /dev/null; then
    echo -e "${YELLOW}⚠️  k3s가 이미 설치되어 있습니다.${NC}"
    k3s --version
else
    echo "k3s 설치 중..."
    curl -sfL https://get.k3s.io | sh -
    echo -e "${GREEN}✅ k3s 설치 완료${NC}"
fi
echo ""

# 4. kubectl 권한 설정
echo "📋 Step 4: kubectl 설정"
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
echo -e "${GREEN}✅ kubectl 권한 설정 완료${NC}"
echo ""

# 5. 노드 확인
echo "📋 Step 5: 클러스터 상태 확인"
sudo k3s kubectl get nodes
echo ""

# 6. cert-manager 설치
echo "📋 Step 6: cert-manager 설치"
sudo k3s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
echo "cert-manager가 준비될 때까지 대기 중..."
sleep 30
sudo k3s kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
echo -e "${GREEN}✅ cert-manager 설치 완료${NC}"
echo ""

# 7. ArgoCD 설치
echo "📋 Step 7: ArgoCD 설치"
cd "$(dirname "$0")/.."
sudo k3s kubectl apply -k infrastructure/argocd/
echo "ArgoCD가 준비될 때까지 대기 중..."
sleep 60
sudo k3s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
echo -e "${GREEN}✅ ArgoCD 설치 완료${NC}"
echo ""

# 8. ArgoCD 초기 비밀번호 확인
echo "📋 Step 8: ArgoCD 관리자 비밀번호"
echo "Username: admin"
echo -n "Password: "
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""

# 9. Sealed Secrets 설치
echo "📋 Step 9: Sealed Secrets Controller 설치"
sudo k3s kubectl apply -f infrastructure/sealed-secrets/controller.yaml
echo -e "${GREEN}✅ Sealed Secrets 설치 완료${NC}"
echo ""

# 10. cert-manager ClusterIssuer 설치
echo "📋 Step 10: Let's Encrypt ClusterIssuer 설치"
sudo k3s kubectl apply -f infrastructure/cert-manager/issuer.yaml
echo -e "${GREEN}✅ ClusterIssuer 설치 완료${NC}"
echo ""

# 11. ArgoCD Applications 배포
echo "📋 Step 11: ArgoCD Applications 등록"
echo ""
echo -e "${YELLOW}⚠️  중요: Git 레포지토리 URL 확인!${NC}"
echo "argocd/applications/*.yaml 파일의 repoURL을 실제 Git 레포지토리로 변경하세요."
echo ""
read -p "Git 레포지토리 설정을 완료하셨습니까? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo k3s kubectl apply -f argocd/applications/
    echo -e "${GREEN}✅ ArgoCD Applications 등록 완료${NC}"
else
    echo -e "${YELLOW}⏭️  ArgoCD Applications 등록을 건너뜁니다.${NC}"
    echo "나중에 다음 명령어로 등록하세요:"
    echo "  sudo k3s kubectl apply -f argocd/applications/"
fi
echo ""

# 완료
echo "=================================="
echo -e "${GREEN}🎉 홈랩 설치 완료!${NC}"
echo ""
echo "📌 접속 정보:"
echo "  - ArgoCD: https://argocd.duchi.click"
echo "  - OpenWebUI: https://ai.duchi.click"
echo "  - Traefik Dashboard: http://traefik.duchi.click"
echo "  - Test App: https://whoami.duchi.click"
echo ""
echo "📝 다음 단계:"
echo "  1. DNS 설정: *.duchi.click를 서버 IP로 A 레코드 추가"
echo "  2. ArgoCD에 로그인하여 애플리케이션 동기화 확인"
echo "  3. Let's Encrypt 인증서 발급 확인: sudo k3s kubectl get certificate -A"
echo ""

