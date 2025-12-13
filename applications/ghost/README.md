# Ghost CMS (Headless Mode) Deployment

이 디렉토리는 Ghost를 **Headless CMS** 용도로 사용하기 위한 직접 배포(Native Kubernetes Manifest) 구성을 담고 있습니다.
블로그의 프론트엔드는 제공하지 않으며, 오직 **콘텐츠 작성(Admin Panel)** 및 **API 제공** 역할만 수행합니다.

## 🔄 전체 워크플로우

Ghost는 정적 사이트 생성기(Astro)에 콘텐츠를 제공하는 백엔드 역할만 수행합니다.

```mermaid
graph LR
    User[Author] -->|Write Content| Ghost[Ghost CMS\n(Admin Panel)]
    Ghost -->|Webhook| n8n[n8n Automation]
    n8n -->|Trigger| GHA[GitHub Actions]
    GHA -->|Build & Deploy| Astro[Astro Static Site]
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

```mermaid
graph TD
    Admin((Admin User)) -->|HTTPS| Ingress[Ingress\n(Traefik)]
    Ingress -->|cms.duchi.click| SvcApp[Service: ghost]

    subgraph "Ghost Pod"
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

    Secret[SealedSecret] -.->|Env: Passwords| GhostApp
    Secret -.->|Env: Passwords| MySQL
```

## 📁 디렉토리 구조 (예정)

직접 작성한 매니페스트를 사용합니다.

```
ghost/
├── deployment.yaml      # Ghost App & MySQL 배포 (Workload)
├── service.yaml         # 내부 통신용 Service
├── pvc.yaml             # 데이터 저장소 요청 (Storage)
├── ingress.yaml         # 외부 접속 설정 (Networking)
├── secret.yaml          # (Git 무시) 실제 비밀번호
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

## 🚀 배포 단계

1.  **Secret 생성**: DB 비밀번호 등 민감 정보 생성 및 암호화 (`sealed-secret.yaml`)
2.  **Manifest 작성**: Deployment, Service, Ingress 등 쿠버네티스 리소스 작성
3.  **ArgoCD 연동**: Helm 방식에서 Directory 방식으로 `Application` 수정
