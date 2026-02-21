#!/usr/bin/env bash
set -euo pipefail

# k3s 클러스터 데이터 백업 스크립트 (Proxmox 마이그레이션용)
# - DB 논리 백업: Ghost MySQL, n8n PostgreSQL
# - PVC 파일 백업: OpenWebUI, Ghost content, n8n config
# - 클러스터 메타데이터 내보내기 (참조용)
# - 선택적으로 로컬 Mac 등 원격지로 scp 전송

usage() {
  cat <<'EOF'
Usage:
  ./setup/backup-k3s-data.sh [options]

Options:
  --output-dir <path>        백업 출력 디렉토리 (default: ~/k3s-backup-YYYYMMDD-HHMMSS)
  --transfer-to <scp-dest>   백업 완료 후 scp 전송 대상 (예: user@192.168.0.10:~/homelab-backup)
  --skip-db                  DB 논리 백업 건너뛰기
  --skip-files               PVC 파일 백업 건너뛰기
  --skip-metadata            클러스터 메타데이터 내보내기 건너뛰기
  --dry-run                  실제 백업 없이 사전 검증만 수행
  -h, --help                 도움말

Examples:
  ./setup/backup-k3s-data.sh
  ./setup/backup-k3s-data.sh --transfer-to duchang@192.168.0.10:~/homelab-backup
  ./setup/backup-k3s-data.sh --output-dir /tmp/my-backup --skip-metadata
  ./setup/backup-k3s-data.sh --dry-run
EOF
}

# ── 변수 ──

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR=""
TRANSFER_TO=""
SKIP_DB=false
SKIP_FILES=false
SKIP_METADATA=false
DRY_RUN=false

TOTAL_FAILED=0
SUMMARY_LINES=()
BACKUP_START_TIME=""

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# ── 인자 파싱 ──

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --transfer-to)
      TRANSFER_TO="${2:-}"
      shift 2
      ;;
    --skip-db)
      SKIP_DB=true
      shift
      ;;
    --skip-files)
      SKIP_FILES=true
      shift
      ;;
    --skip-metadata)
      SKIP_METADATA=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$HOME/k3s-backup-${TIMESTAMP}"
fi

# ── 유틸리티 ──

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' 명령이 필요합니다." >&2; exit 1; }
}

get_secret_value() {
  local secret_name="$1"
  local key="$2"
  kubectl get secret "$secret_name" -n default -o go-template="{{index .data \"$key\"}}" | base64 -d
}

file_size_human() {
  du -h "$1" 2>/dev/null | cut -f1
}

elapsed_since() {
  local start=$1
  local now
  now=$(date +%s)
  echo "$(( now - start ))s"
}

log_success() {
  local name="$1"
  local detail="${2:-}"
  SUMMARY_LINES+=("  ✅ ${name}${detail:+ (${detail})}")
  echo "  ✅ ${name} 완료${detail:+ (${detail})}"
}

log_failure() {
  local name="$1"
  local detail="${2:-}"
  SUMMARY_LINES+=("  ❌ ${name} (실패)${detail:+ — ${detail}}")
  echo "  ❌ ${name} 실패${detail:+ — ${detail}}"
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
}

is_deploy_ready() {
  local deploy="$1"
  local ready
  ready=$(kubectl get deploy "$deploy" -n default -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [[ -n "$ready" && "$ready" != "0" ]]
}

# ── 사전 검증 ──

preflight_check() {
  echo "🔎 사전 검증"
  echo "═══════════"
  echo ""

  need_cmd kubectl
  need_cmd tar
  need_cmd sha256sum

  # kubectl 접근
  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "  ❌ kubectl 접근 불가. KUBECONFIG=${KUBECONFIG}"
    exit 1
  fi
  echo "  ✅ kubectl 접근 OK ($(kubectl get nodes -o jsonpath='{.items[0].metadata.name}'))"

  # 필수 Pod 확인
  local required_deploys=("ghost-mysql" "n8n-postgres" "openwebui" "ghost" "n8n")
  local not_ready=()

  for deploy in "${required_deploys[@]}"; do
    if is_deploy_ready "$deploy"; then
      echo "  ✅ ${deploy}: Running"
    else
      echo "  ⚠️  ${deploy}: 실행 중이지 않음"
      not_ready+=("$deploy")
    fi
  done

  if [[ ${#not_ready[@]} -gt 0 ]]; then
    echo ""
    echo "  ⚠️  일부 Deployment가 Ready 상태가 아닙니다."
    echo "     해당 앱의 백업은 실패할 수 있습니다."
  fi

  # 시크릿 접근 확인
  if kubectl get secret ghost-secret -n default >/dev/null 2>&1; then
    echo "  ✅ ghost-secret 접근 OK"
  else
    echo "  ⚠️  ghost-secret 접근 불가 (DB 덤프 실패 가능)"
  fi

  if kubectl get secret n8n-secret -n default >/dev/null 2>&1; then
    echo "  ✅ n8n-secret 접근 OK"
  else
    echo "  ⚠️  n8n-secret 접근 불가 (DB 덤프 실패 가능)"
  fi

  # 전송 대상 연결 확인
  if [[ -n "$TRANSFER_TO" ]]; then
    local remote_host
    remote_host=$(echo "$TRANSFER_TO" | cut -d: -f1)
    echo ""
    echo "  📤 전송 대상: ${TRANSFER_TO}"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" true 2>/dev/null; then
      echo "  ✅ SSH 연결 OK (${remote_host})"
    else
      echo "  ⚠️  SSH 연결 실패 (${remote_host}). 비밀번호 입력이 필요하거나 연결 불가."
      echo "     전송은 백업 완료 후 시도됩니다."
    fi
  fi

  echo ""
}

# ── DB 백업 ──

backup_ghost_mysql() {
  if ! is_deploy_ready "ghost-mysql"; then
    log_failure "Ghost MySQL dump" "Pod이 실행 중이지 않음"
    return
  fi

  echo "  📦 Ghost MySQL 덤프 중..."
  local start
  start=$(date +%s)
  local outfile="$OUTPUT_DIR/db/ghost-mysql.sql"

  local root_pw
  root_pw=$(get_secret_value "ghost-secret" "root-password")

  if kubectl exec deploy/ghost-mysql -n default -- \
    mysqldump -u root -p"${root_pw}" --single-transaction --routines --triggers ghost_prod \
    > "$outfile" 2>/dev/null; then
    log_success "Ghost MySQL dump" "$(file_size_human "$outfile"), $(elapsed_since "$start")"
  else
    rm -f "$outfile"
    log_failure "Ghost MySQL dump"
  fi
}

backup_n8n_postgres() {
  if ! is_deploy_ready "n8n-postgres"; then
    log_failure "n8n PostgreSQL dump" "Pod이 실행 중이지 않음"
    return
  fi

  echo "  📦 n8n PostgreSQL 덤프 중..."
  local start
  start=$(date +%s)
  local outfile="$OUTPUT_DIR/db/n8n-postgres.sql"

  local db_user
  db_user=$(get_secret_value "n8n-secret" "db-user")

  if kubectl exec deploy/n8n-postgres -n default -- \
    pg_dump -U "${db_user}" --clean --if-exists -d n8n \
    > "$outfile" 2>/dev/null; then
    log_success "n8n PostgreSQL dump" "$(file_size_human "$outfile"), $(elapsed_since "$start")"
  else
    rm -f "$outfile"
    log_failure "n8n PostgreSQL dump"
  fi
}

# ── PVC 파일 백업 ──

backup_openwebui_files() {
  if ! is_deploy_ready "openwebui"; then
    log_failure "OpenWebUI data" "Pod이 실행 중이지 않음"
    return
  fi

  echo "  📦 OpenWebUI 데이터 백업 중 (~1.1GB, 시간이 걸릴 수 있습니다)..."
  local start
  start=$(date +%s)
  local outfile="$OUTPUT_DIR/files/openwebui-data.tar.gz"

  if kubectl exec deploy/openwebui -n default -- \
    tar czf - -C / app/backend/data \
    > "$outfile" 2>/dev/null; then
    log_success "OpenWebUI data" "$(file_size_human "$outfile"), $(elapsed_since "$start")"
  else
    rm -f "$outfile"
    log_failure "OpenWebUI data"
  fi
}

backup_ghost_content() {
  if ! is_deploy_ready "ghost"; then
    log_failure "Ghost content" "Pod이 실행 중이지 않음"
    return
  fi

  echo "  📦 Ghost 콘텐츠 백업 중..."
  local start
  start=$(date +%s)
  local outfile="$OUTPUT_DIR/files/ghost-content.tar.gz"

  if kubectl exec deploy/ghost -n default -- \
    tar czf - -C / var/lib/ghost/content \
    > "$outfile" 2>/dev/null; then
    log_success "Ghost content" "$(file_size_human "$outfile"), $(elapsed_since "$start")"
  else
    rm -f "$outfile"
    log_failure "Ghost content"
  fi
}

backup_n8n_data() {
  if ! is_deploy_ready "n8n"; then
    log_failure "n8n data" "Pod이 실행 중이지 않음"
    return
  fi

  echo "  📦 n8n 설정 백업 중 (encryption key 포함)..."
  local start
  start=$(date +%s)
  local outfile="$OUTPUT_DIR/files/n8n-data.tar.gz"

  if kubectl exec deploy/n8n -n default -- \
    tar czf - -C / home/node/.n8n \
    > "$outfile" 2>/dev/null; then
    log_success "n8n data" "$(file_size_human "$outfile"), $(elapsed_since "$start")"
  else
    rm -f "$outfile"
    log_failure "n8n data"
  fi
}

# ── 메타데이터 내보내기 ──

export_metadata() {
  echo "  📋 클러스터 메타데이터 내보내기 중..."
  local meta_dir="$OUTPUT_DIR/metadata"

  kubectl get pvc -A -o yaml > "$meta_dir/pvcs.yaml" 2>/dev/null || true
  kubectl get deploy -A -o yaml > "$meta_dir/deployments.yaml" 2>/dev/null || true
  kubectl get secrets -A --no-headers > "$meta_dir/secrets-list.txt" 2>/dev/null || true
  kubectl get nodes -o wide > "$meta_dir/nodes.txt" 2>/dev/null || true
  kubectl get applications -n argocd > "$meta_dir/argocd-apps.txt" 2>/dev/null || true
  kubectl get pv -o custom-columns='NAME:.metadata.name,CAPACITY:.spec.capacity.storage,PATH:.spec.local.path,CLAIM:.spec.claimRef.name' \
    > "$meta_dir/pv-paths.txt" 2>/dev/null || true
  kubectl get ingress -A > "$meta_dir/ingresses.txt" 2>/dev/null || true
  kubectl get certificate -A > "$meta_dir/certificates.txt" 2>/dev/null || true

  log_success "Cluster metadata" "$(du -sh "$meta_dir" 2>/dev/null | cut -f1)"
}

# ── 체크섬 ──

create_checksums() {
  echo "  🔒 체크섬 생성 중..."
  local checksum_file="$OUTPUT_DIR/checksums.sha256"

  (
    cd "$OUTPUT_DIR"
    find db files -type f 2>/dev/null | sort | while read -r f; do
      sha256sum "$f"
    done
  ) > "$checksum_file"

  local count
  count=$(wc -l < "$checksum_file" | tr -d ' ')
  log_success "Checksums" "${count}개 파일"
}

# ── 요약 ──

create_summary() {
  local total_size
  total_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)
  local total_elapsed
  total_elapsed=$(elapsed_since "$BACKUP_START_TIME")

  echo ""
  echo "═══════════════════════════"
  echo "📊 백업 요약"
  echo "═══════════════════════════"

  {
    echo "k3s Data Backup Summary"
    echo "========================"
    echo "Date:      $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host:      $(hostname)"
    echo "Output:    $OUTPUT_DIR"
    echo ""
    echo "Results:"
    for line in "${SUMMARY_LINES[@]}"; do
      echo "$line"
    done
    echo ""
    echo "Total size:   $total_size"
    echo "Total time:   $total_elapsed"
    echo "Failed:       $TOTAL_FAILED"
  } | tee "$OUTPUT_DIR/backup-summary.txt"
}

# ── 전송 ──

transfer_backup() {
  echo ""
  echo "📤 백업 전송: ${TRANSFER_TO}"

  if scp -r "$OUTPUT_DIR" "$TRANSFER_TO"; then
    echo "  ✅ 전송 완료"
    echo ""
    echo "💡 수신 측에서 체크섬을 검증하세요:"

    local remote_path
    remote_path=$(echo "$TRANSFER_TO" | cut -d: -f2)
    local dir_name
    dir_name=$(basename "$OUTPUT_DIR")

    echo "   cd ${remote_path}/${dir_name} && shasum -a 256 -c checksums.sha256"
  else
    echo "  ❌ 전송 실패"
    echo ""
    echo "💡 수동으로 전송하세요:"
    echo "   scp -r $OUTPUT_DIR $TRANSFER_TO"
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
}

# ── 메인 ──

main() {
  BACKUP_START_TIME=$(date +%s)

  echo ""
  echo "💾 k3s 데이터 백업"
  echo "══════════════════"
  echo "출력: ${OUTPUT_DIR}"
  echo ""

  preflight_check

  if $DRY_RUN; then
    echo "═══════════════════════════"
    echo "🏁 dry-run 완료"
    echo "═══════════════════════════"
    echo "실제 백업은 --dry-run 없이 실행하세요."
    exit 0
  fi

  # 디렉토리 생성
  mkdir -p "$OUTPUT_DIR"/{db,files,metadata}

  if ! $SKIP_DB; then
    echo ""
    echo "── DB 논리 백업 ─────────────────"
    backup_ghost_mysql
    backup_n8n_postgres
  fi

  if ! $SKIP_FILES; then
    echo ""
    echo "── PVC 파일 백업 ────────────────"
    backup_openwebui_files
    backup_ghost_content
    backup_n8n_data
  fi

  if ! $SKIP_METADATA; then
    echo ""
    echo "── 클러스터 메타데이터 ──────────"
    export_metadata
  fi

  echo ""
  echo "── 마무리 ───────────────────────"
  create_checksums
  create_summary

  if [[ -n "$TRANSFER_TO" ]]; then
    transfer_backup
  fi

  echo ""
  echo "═══════════════════════════"
  if [[ "$TOTAL_FAILED" -gt 0 ]]; then
    echo "⚠️  ${TOTAL_FAILED}개 항목이 실패했습니다. 위 결과를 확인하세요."
    exit 1
  else
    echo "🎉 모든 백업이 성공적으로 완료되었습니다!"
    if [[ -z "$TRANSFER_TO" ]]; then
      echo ""
      echo "💡 백업을 안전한 곳으로 전송하세요:"
      echo "   scp -r ${OUTPUT_DIR} <user>@<mac-ip>:~/homelab-backup/"
    fi
  fi
  echo "═══════════════════════════"
}

main
