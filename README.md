# 홈랩 k3s 관리 프로젝트

k3s와 ArgoCD를 사용한 GitOps 기반 홈서버 관리 프로젝트입니다.

## 🏠 홈랩 서비스

- **OpenWebUI**: AI 챗봇 인터페이스 (https://ai.duchi.click)
- **Nextcloud**: 개인 클라우드 스토리지
- **Blog**: Next.js 블로그
- **ArgoCD**: GitOps CD 플랫폼 (https://argocd.duchi.click)
- **Traefik**: Ingress Controller (http://traefik.duchi.click)

## 🚀 실제 홈랩 배포

### 빠른 시작

```bash
# 설치 스크립트 실행
chmod +x setup/homelab-setup.sh
./setup/homelab-setup.sh
```

### DNS 설정

도메인 제공자에서 다음 레코드를 추가하세요:

```
A 레코드 예시:
*.duchi.click    →  <홈랩-서버-IP>

또는 개별 서브도메인:
argocd.duchi.click   →  <홈랩-서버-IP>
ai.duchi.click       →  <홈랩-서버-IP>
traefik.duchi.click  →  <홈랩-서버-IP>
whoami.duchi.click   →  <홈랩-서버-IP>
```

### 접속 정보

- **ArgoCD**: https://argocd.duchi.click (admin / 초기비밀번호)
- **OpenWebUI**: https://ai.duchi.click
- **Traefik Dashboard**: http://traefik.duchi.click
- **Test App**: https://whoami.duchi.click

## 🧪 로컬 개발 환경 (k3d)

### k3d로 로컬 테스트

```bash
# 클러스터 생성
./setup/k3d-cluster.sh

# ArgoCD 설치
kubectl apply -k infrastructure/argocd/

# /etc/hosts 설정
echo "127.0.0.1 argocd.local ai.local traefik.local" | sudo tee -a /etc/hosts

# 애플리케이션 배포
kubectl apply -f argocd/applications/
```

### 로컬 접속 정보

- ArgoCD: http://argocd.local:8080
- OpenWebUI: http://ai.local
- Traefik: http://traefik.local

## 📁 프로젝트 구조

```
├── infrastructure/           # 기반 인프라
│   ├── argocd/              # ArgoCD 설치 (Kustomize)
│   ├── cert-manager/        # Let's Encrypt 인증서 발급
│   ├── sealed-secrets/      # Secret 암호화 관리
│   └── traefik/             # Ingress Controller 대시보드
├── applications/            # 애플리케이션 매니페스트
│   ├── openwebui/          # AI 챗봇 UI
│   ├── test-app/           # 테스트 앱 (whoami)
│   ├── nextcloud/          # (예정)
│   └── blog/               # (예정)
├── argocd/                 # ArgoCD Application 정의
│   └── applications/       # Git을 통한 배포 관리
└── setup/                  # 설치 스크립트
    ├── homelab-setup.sh    # 홈랩 자동 설치
    └── k3d-cluster.sh      # 로컬 개발 환경
```

## 🔒 Secret 관리

이 프로젝트는 Sealed Secrets를 사용하여 민감한 정보를 안전하게 Git에 저장합니다.

### Secret 생성 및 암호화

```bash
# 1. 일반 Secret 파일 작성
cat > secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: default
stringData:
  password: "my-password"
EOF

# 2. Sealed Secret으로 암호화
kubeseal -f secret.yaml -w sealed-secret.yaml --format yaml

# 3. Git에 커밋 (암호화된 파일만)
git add sealed-secret.yaml
git commit -m "Add sealed secret"

# ⚠️ secret.yaml은 .gitignore에 추가되어 있어 커밋되지 않습니다
```

자세한 사용법은 [infrastructure/sealed-secrets/README.md](infrastructure/sealed-secrets/README.md)를 참조하세요.

## 🔄 GitOps 워크플로우

1. **코드 변경**: 로컬에서 YAML 파일 수정
2. **Git 푸시**: 변경사항을 Git 레포지토리에 푸시
3. **자동 동기화**: ArgoCD가 변경사항을 감지하고 클러스터에 자동 배포
4. **상태 확인**: ArgoCD UI에서 배포 상태 모니터링

```bash
# 예시: OpenWebUI 이미지 버전 업데이트
vim applications/openwebui/deployment.yaml
git add applications/openwebui/deployment.yaml
git commit -m "Update OpenWebUI to latest version"
git push

# ArgoCD가 자동으로 감지하고 배포 (수 분 이내)
```

## 🛠️ 유용한 명령어

```bash
# 클러스터 상태 확인
kubectl get nodes
kubectl get pods -A

# ArgoCD 애플리케이션 상태
kubectl get applications -n argocd

# 인증서 확인
kubectl get certificate -A

# 로그 확인
kubectl logs -n default -l app=openwebui --tail=100 -f

# ArgoCD CLI 로그인 (선택사항)
argocd login argocd.duchi.click --username admin --password <초기비밀번호>
```

## 📚 참고 자료

- [k3s 공식 문서](https://docs.k3s.io/)
- [ArgoCD 공식 문서](https://argo-cd.readthedocs.io/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [cert-manager](https://cert-manager.io/)
