# Homelab Machine Specifications

## Physical Hardware

| Resource       | Spec                             | Notes                                            |
| -------------- | -------------------------------- | ------------------------------------------------ |
| **CPU**        | Intel N95 (4 cores, 4 threads)   | Alder Lake-N, 저전력 효율 CPU, 하이퍼스레딩 없음 |
| **RAM**        | 32GB DDR4 (Samsung, single slot) |                                                  |
| **NVMe SSD**   | 238GB                            | Proxmox OS + VM 디스크 (local-lvm)               |
| **HDD**        | 500GB (sda)                      | `/mnt/hdd-storage`, Proxmox 백업/ISO 저장소      |
| **Hypervisor** | Proxmox VE                       |                                                  |

## VM 구성

### VM 100: k3s-node

| 항목        | 설정값                                                            |
| ----------- | ----------------------------------------------------------------- |
| **CPU**     | 4 cores (Sockets: 1, Cores: 4, Type: host)                        |
| **RAM**     | 28672 MiB (28GB), Ballooning 활성 (Min: 4096)                     |
| **Disk**    | 100GB, local-lvm (NVMe), VirtIO SCSI, SSD emulation, Discard 활성 |
| **Network** | VirtIO paravirtualized, Bridge: vmbr0                             |
| **OS**      | Ubuntu 24.04.3 LTS (Kernel 6.8.x)                                 |
| **Machine** | q35, SeaBIOS, Qemu Agent 활성                                     |
| **용도**    | k3s 클러스터 (ArgoCD, OpenWebUI, Ghost, n8n, Beszel 등)           |

### VM 101: zeroclaw (계획됨, 미배포)

| 항목     | 설정값                                               |
| -------- | ---------------------------------------------------- |
| **CPU**  | 2 cores                                              |
| **RAM**  | 8GB                                                  |
| **Disk** | 20GB NVMe                                            |
| **OS**   | Debian 13 Desktop (Trixie, XFCE)                     |
| **용도** | ZeroClaw AI 에이전트 (systemd daemon + Discord 연동) |

## Secret 보호 규칙

> **공개 레포지토리. 시크릿 노출 절대 금지.**

### 금지 항목

| 파일 유형 | 행동 | 이유 |
|-----------|------|------|
| `secret.yaml` | **커밋 금지** | 평문 자격증명 포함 |
| `*.pem`, `*.key` | **커밋 금지** | 개인키 (`pub-cert.pem`은 공개키이므로 예외) |
| `.env` 파일 | **커밋 금지** | 환경 시크릿 |
| API 키, 비밀번호 | **하드코딩 금지** | `secretKeyRef` 사용 |

### 커밋 가능한 파일

- `sealed-secret.yaml` — kubeseal로 암호화됨
- `secret.yaml.example` — 플레이스홀더 값만 포함된 템플릿

### Sealed Secret 생성

새 시크릿 추가 시, 레포 루트의 `pub-cert.pem`을 사용하여 암호화한다.

```bash
kubeseal --cert=pub-cert.pem \
  -f applications/{app}/secret.yaml \
  -w applications/{app}/sealed-secret.yaml \
  --format yaml
```

`secret.yaml`은 `.gitignore`에 의해 제외되며, `sealed-secret.yaml`만 커밋한다.
