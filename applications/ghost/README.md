# Ghost CMS (Headless Mode) Deployment

이 디렉토리는 Ghost를 **Headless CMS** 용도로 사용하기 위한 직접 배포(Native Kubernetes Manifest) 구성을 담고 있습니다.
블로그의 프론트엔드는 제공하지 않으며, 오직 **콘텐츠 작성(Admin Panel)** 및 **API 제공** 역할만 수행합니다.

## 🔄 전체 워크플로우

Ghost는 정적 사이트 생성기(Astro)에 콘텐츠를 제공하는 백엔드 역할만 수행합니다.

```mermaid
graph LR
    User[Author] -->|Write Content| Ghost[Ghost CMS\n(Admin Panel)]
    Ghost -->|Store Image| R2[Cloudflare R2\n(S3 Adapter)]
    Ghost -->|Webhook| n8n[n8n Automation]
    n8n -->|Trigger| GHA[GitHub Actions]
    GHA -->|Build & Deploy| Astro[Astro Static Site]
    Astro -->|Load Image| R2
    Astro -->|Publish| GH_Pages[GitHub Pages]

    subgraph Kubernetes Cluster
        Ghost
        n8n
    end

    subgraph GitHub
        GHA
        GH_Pages
    end
```

## 🏗️ 인프라 아키텍처

트래픽이 적은 관리자 전용 시스템이므로 리소스를 최소화한 구성입니다.
이미지 파일은 로컬 디스크가 아닌 Cloudflare R2(Object Storage)에 직접 저장됩니다.

```mermaid
graph TD
    Admin((Admin User)) -->|HTTPS| Ingress[Ingress\n(Traefik)]
    Ingress -->|cms.duchi.click| SvcApp[Service: ghost]

    subgraph "Ghost Pod"
        Init[InitContainer:\nInstall S3 Adapter] -.->|Copy Adapter| GhostApp
        GhostApp[Ghost App Container\n(Node.js)]
    end

    subgraph "MySQL Pod"
        MySQL[MySQL 8.0 Container]
    end

    SvcApp --> GhostApp
    GhostApp -->|DB Connection| SvcDB[Service: ghost-mysql]
    SvcDB --> MySQL

    GhostApp -->|Mount| PVC_Content[PVC: ghost-content\n(2Gi)]
    MySQL -->|Mount| PVC_DB[PVC: ghost-mysql-data\n(2Gi)]

    GhostApp -.->|Uploads| CloudflareR2[Cloudflare R2 Bucket]

    Secret[SealedSecret] -.->|Env: Passwords & R2 Keys| GhostApp
    Secret -.->|Env: Passwords| MySQL
```

## 📁 디렉토리 구조

직접 작성한 매니페스트를 사용합니다.

```plain
ghost/
├── deployment-app.yaml  # Ghost App 배포 (S3 Adapter InitContainer 포함)
├── deployment-db.yaml   # MySQL DB 배포
├── service.yaml         # 내부 통신용 Service
├── pvc.yaml             # 데이터 저장소 요청 (Storage)
├── ingress.yaml         # 외부 접속 설정 (Networking)
├── secret.yaml          # (Git 무시) 실제 비밀번호 및 R2 키
└── sealed-secret.yaml   # 암호화된 비밀번호 (Git 커밋)
```

## ⚙️ 리소스 스펙 (Lightweight)

관리자 혼자 사용하는 시스템이므로 리소스를 보수적으로 할당합니다.

| 컴포넌트    | 리소스 | 요청(Request) | 제한(Limit) | 비고               |
| :---------- | :----- | :------------ | :---------- | :----------------- |
| **Ghost**   | CPU    | 100m          | 500m        | 트래픽 없음        |
|             | Memory | 256Mi         | 512Mi       | Node.js 최소 구동  |
| **MySQL**   | CPU    | 100m          | 500m        | 쓰기 작업 적음     |
|             | Memory | 256Mi         | 512Mi       |                    |
| **Storage** | PVC    | 2Gi (각각)    | -           | 텍스트/이미지 위주 |

## ☁️ Cloudflare R2 연동

Ghost 공식 이미지에는 S3 어댑터가 포함되어 있지 않으므로, `InitContainer`를 통해 실행 시점에 어댑터를 설치합니다.

### 1. R2 버킷 및 API 키 생성

1. Cloudflare Dashboard > R2 > Create bucket (`ghost-blog` 등)
2. Manage R2 API Tokens > Create API token (권한: **Object Read & Write**)
3. Access Key, Secret Key, Endpoint URL 저장

### 2. Secret 설정

`secret.yaml`에 R2 접속 정보를 입력해야 합니다.

```yaml
stringData:
  r2-access-key: "..."
  r2-secret-key: "..."
  r2-endpoint: "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
  r2-asset-host: "https://cdn.duchi.click" # 커스텀 도메인
```

## 🚀 배포 단계

1. **Secret 생성**: DB 비밀번호 및 R2 키 생성 및 암호화 (`sealed-secret.yaml`)
2. **Manifest 작성**: Deployment, Service, Ingress 등 쿠버네티스 리소스 작성
3. **ArgoCD 연동**: Helm 방식에서 Directory 방식으로 `Application` 수정
