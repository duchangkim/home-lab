# Sealed Secrets

Sealed Secrets는 Kubernetes Secret을 암호화하여 Git에 안전하게 저장할 수 있게 해주는 도구입니다.

## 📌 왜 Sealed Secrets를 사용하나?

### 문제점

```yaml
# ❌ 일반 Secret을 Git에 올리면 위험!
apiVersion: v1
kind: Secret
stringData:
  password: "my-super-secret" # Git에 그대로 노출!
```

### 해결책

```yaml
# ✅ Sealed Secret은 암호화되어 안전!
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
spec:
  encryptedData:
    password: AgBx7f8... # 암호화된 데이터, Git에 올려도 안전
```

## 🚀 설치

### 1. Controller 설치 (클러스터에 한 번만)

```bash
# Sealed Secrets Controller 설치
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# 설치 확인
kubectl get pods -n kube-system | grep sealed-secrets
```

### 2. kubeseal CLI 설치 (로컬 머신에)

```bash
# Mac
brew install kubeseal

# 설치 확인
kubeseal --version
```

## 📝 사용법

### Step 1: 일반 Secret 작성

```bash
# 예시: applications/myapp/ 디렉토리에서
cd applications/myapp
```

`secret.yaml` 파일 생성:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
  namespace: default
type: Opaque
stringData:
  database-password: "super-secret-password"
  api-key: "sk-xxxxxxxxxxxxx"
```

### Step 2: Sealed Secret으로 암호화

```bash
# 암호화
kubeseal -f secret.yaml -w sealed-secret.yaml --format yaml

# 생성된 파일 확인
ls -la
# secret.yaml          <- Git에 올리지 않음 (.gitignore)
# sealed-secret.yaml   <- Git에 올림 (암호화됨, 안전!)
```

### Step 3: Git에 커밋

```bash
# sealed-secret.yaml만 Git에 추가
git add sealed-secret.yaml
git commit -m "Add myapp sealed secret"

# ⚠️ secret.yaml은 절대 커밋하지 않기!
```

### Step 4: 클러스터에 배포

```bash
# SealedSecret 배포
kubectl apply -f sealed-secret.yaml

# 자동으로 Secret이 생성됨 (복호화됨)
kubectl get secrets myapp-secret

# Secret 내용 확인
kubectl describe secret myapp-secret
```

## 🔄 Secret 수정하기

### 방법 1: 원본 secret.yaml 수정 후 재암호화

```bash
# 1. secret.yaml 수정
vim secret.yaml

# 2. 다시 암호화
kubeseal -f secret.yaml -w sealed-secret.yaml --format yaml

# 3. Git 커밋
git add sealed-secret.yaml
git commit -m "Update myapp secret"

# 4. 클러스터에 적용
kubectl apply -f sealed-secret.yaml
```

### 방법 2: secret.yaml을 잃어버렸다면

```bash
# 기존 Secret에서 복원
kubectl get secret myapp-secret -o yaml > secret.yaml

# stringData로 변환 후 수정
# (base64 디코딩 필요)
```

## 📁 프로젝트 파일 구조

```
applications/myapp/
├── deployment.yaml          # Git에 올림
├── service.yaml             # Git에 올림
├── ingress.yaml             # Git에 올림
├── sealed-secret.yaml       # ✅ Git에 올림 (암호화됨)
├── secret.yaml.example      # ✅ Git에 올림 (예시)
└── secret.yaml              # ❌ Git에 올리지 않음 (.gitignore)
```

## 🔒 .gitignore 설정

프로젝트 루트의 `.gitignore`:

```
# Secret files
**/secret.yaml
!**/sealed-secret.yaml
!**/secret.yaml.example
```

## 📋 Secret 예시 템플릿

### secret.yaml.example

```yaml
# Example: Copy this to secret.yaml and fill in your values
# Then encrypt with: kubeseal -f secret.yaml -w sealed-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
  namespace: default
type: Opaque
stringData:
  # Database
  db-username: "your-username"
  db-password: "your-password"

  # API Keys
  openai-api-key: "sk-xxxxxxxxxxxxx"

  # Other secrets
  jwt-secret: "your-jwt-secret"
```

## 🛠️ 트러블슈팅

### SealedSecret이 Secret으로 변환되지 않음

```bash
# Controller 로그 확인
kubectl logs -n kube-system -l name=sealed-secrets-controller

# Controller가 실행 중인지 확인
kubectl get pods -n kube-system | grep sealed-secrets
```

### 암호화 실패: "cannot fetch certificate"

```bash
# Controller가 준비될 때까지 기다리기
kubectl wait --for=condition=Ready pod -l name=sealed-secrets-controller -n kube-system --timeout=120s

# 다시 시도
kubeseal -f secret.yaml -w sealed-secret.yaml
```

### Secret 값 확인하기

```bash
# Secret 존재 확인
kubectl get secret myapp-secret

# Secret 값 복호화해서 보기
kubectl get secret myapp-secret -o jsonpath='{.data.database-password}' | base64 -d
```

## 🔑 주요 명령어 정리

```bash
# Secret 암호화
kubeseal -f secret.yaml -w sealed-secret.yaml --format yaml

# 특정 namespace로 암호화
kubeseal -f secret.yaml -w sealed-secret.yaml --format yaml --namespace myapp

# SealedSecret 배포
kubectl apply -f sealed-secret.yaml

# 생성된 Secret 확인
kubectl get secret myapp-secret
kubectl describe secret myapp-secret

# Controller 상태 확인
kubectl get pods -n kube-system | grep sealed-secrets
kubectl logs -n kube-system -l name=sealed-secrets-controller
```

## 📚 참고 자료

- [Sealed Secrets GitHub](https://github.com/bitnami-labs/sealed-secrets)
- [공식 문서](https://sealed-secrets.netlify.app/)

## 💡 Tips

1. **secret.yaml은 항상 로컬에 백업**

   - 암호화 원본이 없으면 수정이 어려움
   - 안전한 곳에 별도 보관 (1Password, 암호화된 USB 등)

2. **secret.yaml.example 제공**

   - 팀원들이 Secret 구조를 알 수 있게
   - 실제 값은 비우고 예시만

3. **namespace 주의**

   - SealedSecret과 Secret의 namespace가 일치해야 함
   - 다른 namespace에 배포하려면 재암호화 필요

4. **클러스터 재생성 시**
   - k3d 클러스터를 삭제하고 다시 만들면
   - Sealed Secrets Controller도 재설치 필요
   - 암호화 키가 변경되므로 모든 SealedSecret 재암호화 필요
