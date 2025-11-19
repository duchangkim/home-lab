#!/bin/bash
set -e

echo "🔄 K3s 데이터 디렉토리 마이그레이션"
echo "==================================="
echo ""

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 경고 메시지
echo -e "${YELLOW}⚠️  주의: 이 작업은 K3s 클러스터를 일시 중지합니다.${NC}"
echo -e "${YELLOW}   다운타임이 발생할 수 있습니다 (예상 시간: 5-10분).${NC}"
echo -e "${YELLOW}   /var/lib/rancher/k3s → /mnt/ncdata/k3s${NC}"
echo ""

# /mnt/ncdata 디렉토리 확인
if [ ! -d "/mnt/ncdata" ]; then
    echo -e "${RED}❌ /mnt/ncdata 디렉토리가 존재하지 않습니다.${NC}"
    echo "먼저 큰 디스크를 /mnt/ncdata에 마운트해주세요."
    exit 1
fi

# k3s 설치 확인
if ! command -v k3s &> /dev/null; then
    echo -e "${RED}❌ k3s가 설치되어 있지 않습니다.${NC}"
    exit 1
fi

# 이미 마이그레이션되었는지 확인
if [ -f "/etc/rancher/k3s/config.yaml" ] && grep -q "data-dir: /mnt/ncdata/k3s" /etc/rancher/k3s/config.yaml 2>/dev/null; then
    echo -e "${YELLOW}⚠️  이미 /mnt/ncdata/k3s를 사용하도록 설정되어 있습니다.${NC}"
    echo "현재 설정:"
    cat /etc/rancher/k3s/config.yaml
    echo ""
    read -p "다시 마이그레이션하시겠습니까? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "작업을 취소했습니다."
        exit 0
    fi
fi

read -p "계속하시겠습니까? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "작업을 취소했습니다."
    exit 0
fi
echo ""

# 1. 현재 데이터 크기 확인
echo "📊 현재 데이터 크기 확인..."
if [ -d "/var/lib/rancher/k3s" ]; then
    echo "원본 데이터:"
    sudo du -sh /var/lib/rancher/k3s
else
    echo -e "${YELLOW}⚠️  /var/lib/rancher/k3s 디렉토리가 없습니다.${NC}"
fi
echo ""

# 2. K3s 중지
echo "📋 Step 1: K3s 중지"
sudo systemctl stop k3s
echo -e "${GREEN}✅ K3s 중지 완료${NC}"
echo ""

# 3. 타겟 디렉토리 생성
echo "📋 Step 2: 타겟 디렉토리 생성"
sudo mkdir -p /mnt/ncdata/k3s
echo -e "${GREEN}✅ 디렉토리 생성 완료: /mnt/ncdata/k3s${NC}"
echo ""

# 4. 데이터 복사
echo "📋 Step 3: 데이터 복사 (시간이 걸릴 수 있습니다...)"
if [ -d "/var/lib/rancher/k3s" ] && [ "$(ls -A /var/lib/rancher/k3s)" ]; then
    echo "rsync로 데이터 복사 중..."
    sudo rsync -av --progress /var/lib/rancher/k3s/ /mnt/ncdata/k3s/
    echo -e "${GREEN}✅ 데이터 복사 완료${NC}"
else
    echo -e "${YELLOW}⚠️  복사할 데이터가 없습니다 (새로 설치된 것 같습니다).${NC}"
fi
echo ""

# 5. 설정 파일 생성
echo "📋 Step 4: K3s 설정 파일 생성"
sudo mkdir -p /etc/rancher/k3s

# 기존 설정 파일 백업
if [ -f "/etc/rancher/k3s/config.yaml" ]; then
    sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.backup.$(date +%Y%m%d_%H%M%S)
    echo "기존 설정 파일 백업 완료"
fi

sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
# K3s 데이터 디렉토리를 큰 디스크로 설정
data-dir: /mnt/ncdata/k3s
EOF

echo -e "${GREEN}✅ 설정 파일 생성 완료${NC}"
echo "설정 내용:"
cat /etc/rancher/k3s/config.yaml
echo ""

# 6. K3s 재시작
echo "📋 Step 5: K3s 재시작"
sudo systemctl start k3s
echo "K3s 시작 대기 중 (30초)..."
sleep 30

if sudo systemctl is-active --quiet k3s; then
    echo -e "${GREEN}✅ K3s 재시작 완료${NC}"
else
    echo -e "${RED}❌ K3s 시작 실패${NC}"
    echo "로그 확인:"
    sudo journalctl -u k3s -n 50 --no-pager
    exit 1
fi
echo ""

# 7. 상태 확인
echo "📋 Step 6: 클러스터 상태 확인"
echo "노드 상태:"
sudo k3s kubectl get nodes
echo ""
echo "파드 상태 (모든 네임스페이스):"
sudo k3s kubectl get pods -A
echo ""

# 8. 데이터 디렉토리 확인
echo "📋 Step 7: 새 데이터 디렉토리 확인"
echo "새 데이터 디렉토리 크기:"
sudo du -sh /mnt/ncdata/k3s
echo ""
echo "디스크 사용량:"
df -h /mnt/ncdata
echo ""

# 9. 기존 데이터 백업
echo "📋 Step 8: 기존 데이터 처리"
if [ -d "/var/lib/rancher/k3s" ] && [ "$(ls -A /var/lib/rancher/k3s)" ]; then
    echo -e "${YELLOW}기존 데이터를 백업으로 이동합니다.${NC}"
    BACKUP_NAME="k3s.backup.$(date +%Y%m%d_%H%M%S)"
    sudo mv /var/lib/rancher/k3s "/var/lib/rancher/${BACKUP_NAME}"
    echo -e "${GREEN}✅ 백업 완료: /var/lib/rancher/${BACKUP_NAME}${NC}"
    echo ""
    echo -e "${YELLOW}💡 팁: 며칠간 정상 작동 확인 후 백업 삭제${NC}"
    echo "   sudo rm -rf /var/lib/rancher/${BACKUP_NAME}"
else
    echo "기존 데이터가 없습니다."
fi
echo ""

# 완료
echo "==================================="
echo -e "${GREEN}🎉 마이그레이션 완료!${NC}"
echo ""
echo "📌 확인사항:"
echo "  ✅ 새 데이터 위치: /mnt/ncdata/k3s"
echo "  ✅ 설정 파일: /etc/rancher/k3s/config.yaml"
if [ -d "/var/lib/rancher/k3s.backup."* 2>/dev/null ]; then
    echo "  ✅ 백업 위치: /var/lib/rancher/k3s.backup.*"
fi
echo ""
echo "📝 다음 단계:"
echo "  1. ArgoCD 대시보드에서 애플리케이션 상태 확인"
echo "  2. 몇 시간/일 동안 정상 작동 확인"
echo "  3. 문제없으면 백업 삭제"
echo "  4. 디스크 공간 확인: df -h"
echo ""
echo "🔍 로그 확인:"
echo "  sudo journalctl -u k3s -f"
echo "  sudo k3s kubectl get events -A --sort-by='.lastTimestamp'"
echo ""

