# 홈랩 k3s 관리 프로젝트

k3s를 사용한 홈서버 구축 및 GitOps를 통한 관리 프로젝트입니다.

## 🏠 홈랩 서비스

- **OpenWebUI**: AI 챗봇 인터페이스
- **Nextcloud**: 개인 클라우드 스토리지
- **Blog**: Next.js 블로그

## 🚀 로컬 개발 환경

### k3d로 로컬 테스트

```bash
# 클러스터 생성
./setup/k3d-cluster.sh

# ArgoCD 설치
kubectl apply -k infrastructure/argocd/

# 애플리케이션 배포
kubectl apply -f argocd/applications/
```

### 접속 정보

- ArgoCD: http://localhost:8080
- OpenWebUI: http://openwebui.local
- Nextcloud: http://nextcloud.local

## 📁 프로젝트 구조

```
├── infrastructure/ # 기반 인프라 (ArgoCD, Ingress, 모니터링)
├── applications/ # 애플리케이션 매니페스트
├── argocd/ # ArgoCD Application 정의
└── scripts/ # 배포/관리 스크립트
```
