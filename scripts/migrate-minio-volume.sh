#!/usr/bin/env bash
# =============================================================================
# migrate-minio-volume.sh — Migrate tradingo_minio-data from nuc-01 to nuc-02
#
# Run this from your local machine. It orchestrates via SSH.
# Requires only 'docker' group membership on the remote nodes (no sudo).
#
# Usage:
#   ./scripts/migrate-minio-volume.sh [--dry-run] [--skip-transfer]
#
# Options:
#   --dry-run        Print commands without executing any destructive actions
#   --skip-transfer  Skip rsync (re-run after a partial transfer)
#
# Prerequisites:
#   - SSH access to NUC_01 and NUC_02 as ADMIN_USER (key auth)
#   - NUC_01 can SSH directly to NUC_02 (admin@nuc-02) for the data transfer
#   - ADMIN_USER is in the 'docker' group on both nodes
#   - The tradingo stack is deployed on the Swarm
#   - No active DAG runs writing to MinIO (pause DAGs first)
# =============================================================================

set -euo pipefail

cleanup() {
  if ! ${DRY_RUN:-false}; then
    log "Cleaning up rsync daemon on nuc-02 (if running)..."
    ssh "${ADMIN_USER:-rory}@${NUC_02:-192.168.1.51}" "docker stop ${RSYNC_CONTAINER:-minio-rsync-daemon} 2>/dev/null || true" || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Configuration — adjust if your environment differs
# ---------------------------------------------------------------------------
NUC_01="192.168.1.50"
NUC_02="192.168.1.51"
ADMIN_USER="rory"
STACK_NAME="tradingo"
VOLUME_NAME="minio-data"
FULL_VOLUME_NAME="${STACK_NAME}_${VOLUME_NAME}"
SERVICE_NAME="${STACK_NAME}_minio"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=false
SKIP_TRANSFER=false
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY_RUN=true ;;
  --skip-transfer) SKIP_TRANSFER=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }

# Run a command on a remote host via SSH, or print it in dry-run mode
run_on() {
  local host="$1"
  local label="$2"
  local cmd="$3"
  if $DRY_RUN; then
    echo "  [DRY-RUN ${label}] $cmd"
  else
    ssh "${ADMIN_USER}@${host}" "$cmd"
  fi
}

run_nuc01() { run_on "${NUC_01}" "nuc-01" "$1"; }
run_nuc03() { run_on "${NUC_02}" "nuc-02" "$1"; }

# Run an alpine container against a named volume on a remote host.
# Uses 'docker run --rm' so no sudo needed — just docker group membership.
docker_vol_nuc01() {
  local volume="$1"
  local inner_cmd="$2"
  run_nuc01 "docker run --rm -v ${volume}:/data alpine sh -c '${inner_cmd}'"
}
docker_vol_nuc03() {
  local volume="$1"
  local inner_cmd="$2"
  run_nuc03 "docker run --rm -v ${volume}:/data alpine sh -c '${inner_cmd}'"
}

# ---------------------------------------------------------------------------
# Step 0: Preflight checks
# ---------------------------------------------------------------------------
log "=== Preflight checks ==="

log "Checking SSH connectivity to nuc-01..."
ssh -o ConnectTimeout=5 "${ADMIN_USER}@${NUC_01}" "echo 'nuc-01 OK'" || {
  echo "ERROR: Cannot SSH to nuc-01 (${NUC_01})" >&2
  exit 1
}

log "Checking SSH connectivity to nuc-02..."
ssh -o ConnectTimeout=5 "${ADMIN_USER}@${NUC_02}" "echo 'nuc-02 OK'" || {
  echo "ERROR: Cannot SSH to nuc-02 (${NUC_02})" >&2
  exit 1
}

log "Checking SSH from nuc-01 → nuc-02..."
ssh "${ADMIN_USER}@${NUC_01}" \
  "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${ADMIN_USER}@${NUC_02} 'echo nuc-01->nuc-02 OK'" || {
  echo "ERROR: nuc-01 cannot SSH to nuc-02. Set up key auth before proceeding." >&2
  echo "       On nuc-01 run: ssh-copy-id ${ADMIN_USER}@${NUC_02}" >&2
  exit 1
}

log "Checking volume exists on nuc-01..."
run_nuc01 "docker volume inspect ${FULL_VOLUME_NAME} > /dev/null" || {
  echo "ERROR: Volume '${FULL_VOLUME_NAME}' not found on nuc-01" >&2
  exit 1
}

log "Checking service '${SERVICE_NAME}' exists..."
run_nuc01 "docker service inspect ${SERVICE_NAME} > /dev/null" || {
  echo "ERROR: Service '${SERVICE_NAME}' not found" >&2
  exit 1
}

# Report current volume size using a container (no sudo needed)
log "Current volume size on nuc-01:"
docker_vol_nuc01 "${FULL_VOLUME_NAME}" "du -sh /data"

log "Preflight OK."

# ---------------------------------------------------------------------------
# Step 1: Pause Airflow DAGs (reminder — manual)
# ---------------------------------------------------------------------------
log ""
log "=== Step 1: Pause DAGs ==="
log "ACTION REQUIRED: Ensure all Airflow DAGs are paused/idle before continuing."
log "  docker service update --replicas 0 ${STACK_NAME}_airflow-scheduler"
log "  (or pause DAGs via the Airflow UI at http://${NUC_01}:8080)"
log ""
if ! $DRY_RUN; then
  read -r -p "Have you paused all DAGs and confirmed no active MinIO writes? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    echo "Aborted."
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# Step 2: Scale MinIO to 0 replicas
# ---------------------------------------------------------------------------
log ""
log "=== Step 2: Scale MinIO to 0 ==="
log "Scaling ${SERVICE_NAME} to 0 replicas..."
run_nuc01 "docker service scale ${SERVICE_NAME}=0"

if ! $DRY_RUN; then
  log "Waiting for MinIO container to stop..."
  for i in $(seq 1 30); do
    running=$(ssh "${ADMIN_USER}@${NUC_01}" \
      "docker service ps ${SERVICE_NAME} --filter 'desired-state=running' --format '{{.CurrentState}}' | grep -c 'Running' || true")
    if [[ "$running" -eq 0 ]]; then
      log "MinIO stopped."
      break
    fi
    log "  Waiting... ($i/30)"
    sleep 5
  done
fi

# ---------------------------------------------------------------------------
# Step 3: Create destination volume on nuc-02
# ---------------------------------------------------------------------------
log ""
log "=== Step 3: Create destination volume on nuc-02 ==="
run_nuc03 "docker volume inspect ${FULL_VOLUME_NAME} >/dev/null 2>&1 || docker volume create ${FULL_VOLUME_NAME}"
log "Volume ready on nuc-02."

# ---------------------------------------------------------------------------
# Step 4: Transfer volume data nuc-01 → nuc-02 via rsync daemon
# ---------------------------------------------------------------------------
# Strategy: start a temporary rsync daemon container on nuc-02 with the
# destination volume mounted, listening on RSYNC_PORT. Then run rsync from
# a container on nuc-01 pointing directly at rsync://nuc-02:RSYNC_PORT/data.
#
# Benefits over SSH-based rsync:
#   - No SSH auth inside the container (no agent socket, no config issues)
#   - No staging dir — writes directly into the Docker volume on nuc-02
#   - Resumable: re-run with --skip-transfer skips to a fresh rsync pass
#
# The daemon is unauthenticated but only exposed on the LAN for the duration
# of the transfer and torn down immediately after.
# ---------------------------------------------------------------------------
RSYNC_PORT=8730
RSYNC_CONTAINER="minio-rsync-daemon"

log ""
log "=== Step 4: Transfer volume data nuc-01 → nuc-02 ==="

if $SKIP_TRANSFER; then
  warn "--skip-transfer set, skipping data transfer."
else
  log "Starting rsync daemon on nuc-02 (port ${RSYNC_PORT})..."

  if ! $DRY_RUN; then
    # Start daemon container on nuc-02
    ssh "${ADMIN_USER}@${NUC_02}" bash <<EOF
docker run -d --rm \
  --name ${RSYNC_CONTAINER} \
  -v ${FULL_VOLUME_NAME}:/data \
  -p ${RSYNC_PORT}:${RSYNC_PORT} \
  alpine sh -c '
    apk add -q rsync
    printf "[data]\n  path = /data\n  read only = no\n  use chroot = no\n  uid = 0\n  gid = 0\n" > /etc/rsyncd.conf
    rsync --daemon --no-detach --port=${RSYNC_PORT} --config=/etc/rsyncd.conf
  '
EOF

    log "Waiting for rsync daemon to be ready..."
    sleep 3

    log "rsyncing nuc-01:${FULL_VOLUME_NAME} → nuc-02:${RSYNC_PORT}/data (direct, no local hop)"
    log "(This may take a while — ~170 GB)"

    # Run rsync from a container on nuc-01, pushing directly to the daemon
    ssh "${ADMIN_USER}@${NUC_01}" bash <<EOF
docker run --rm \
  -v ${FULL_VOLUME_NAME}:/data \
  alpine sh -c '
    apk add -q rsync
    rsync -avz --progress /data/ rsync://${NUC_02}:${RSYNC_PORT}/data/
  '
EOF
    log "rsync complete."

    log "Stopping rsync daemon on nuc-02..."
    run_nuc03 "docker stop ${RSYNC_CONTAINER} 2>/dev/null || true"
    log "Transfer complete."

  else
    echo "  [DRY-RUN nuc-02] docker run -d --rm --name ${RSYNC_CONTAINER} -v ${FULL_VOLUME_NAME}:/data -p ${RSYNC_PORT}:${RSYNC_PORT} alpine sh -c 'rsync --daemon ...'"
    echo "  [DRY-RUN nuc-01] docker run --rm -v ${FULL_VOLUME_NAME}:/data alpine sh -c 'rsync -avz /data/ rsync://${NUC_02}:${RSYNC_PORT}/data/'"
    echo "  [DRY-RUN nuc-02] docker stop ${RSYNC_CONTAINER}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Verify data integrity
# ---------------------------------------------------------------------------
log ""
log "=== Step 5: Verify data ==="

if ! $DRY_RUN; then
  SRC_COUNT=$(docker_vol_nuc01 "${FULL_VOLUME_NAME}" "find /data -type f | wc -l")
  DST_COUNT=$(docker_vol_nuc03 "${FULL_VOLUME_NAME}" "find /data -type f | wc -l")

  SRC_COUNT=$(echo "$SRC_COUNT" | tr -d '[:space:]')
  DST_COUNT=$(echo "$DST_COUNT" | tr -d '[:space:]')

  log "Source file count (nuc-01): ${SRC_COUNT}"
  log "Destination file count (nuc-02): ${DST_COUNT}"

  if [[ "$SRC_COUNT" -ne "$DST_COUNT" ]]; then
    warn "File counts differ! src=${SRC_COUNT} dst=${DST_COUNT}"
    warn "Re-run with --skip-transfer to retry transfer only."
    read -r -p "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || {
      echo "Aborted. MinIO is still at 0 replicas — redeploy manually when ready."
      exit 1
    }
  else
    log "File counts match. Transfer verified."
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Instructions for docker-stack.yaml update
# ---------------------------------------------------------------------------
log ""
log "=== Step 6: Update docker-stack.yaml ==="
log ""
log "Change the 'minio' service placement constraint in docker-stack.yaml:"
log ""
log "  FROM:"
log "    deploy:"
log "      placement:"
log "        constraints:"
log "          - node.role == manager"
log ""
log "  TO:"
log "    deploy:"
log "      placement:"
log "        constraints:"
log "          - node.labels.node == nuc-02"
log ""
log "The label 'node: nuc-02' is already applied by Ansible (hosts.yml swarm_labels)."
log ""

# ---------------------------------------------------------------------------
# Step 7: Redeploy instructions
# ---------------------------------------------------------------------------
log "=== Step 7: Redeploy stack ==="
log ""
log "After updating docker-stack.yaml, commit and redeploy:"
log ""
log "  cd tradingo-infra"
log "  ansible-playbook playbooks/sync-platform.yml"
log "  ansible-playbook playbooks/deploy-stack.yml -e image_tag=\$(grep TAG versions.env | cut -d= -f2)"
log ""

# ---------------------------------------------------------------------------
# Step 8: Post-deploy verification
# ---------------------------------------------------------------------------
log "=== Step 8: Post-deploy verification ==="
log ""
log "  # Check MinIO landed on nuc-02:"
log "  ssh ${ADMIN_USER}@${NUC_01} 'docker service ps ${SERVICE_NAME}'"
log ""
log "  # Check MinIO health:"
log "  curl -sf http://${NUC_02}:9000/minio/health/live && echo 'MinIO healthy'"
log ""

# ---------------------------------------------------------------------------
# Rollback reminder
# ---------------------------------------------------------------------------
log "=== Rollback ==="
log ""
log "The original volume on nuc-01 is untouched. To rollback:"
log "  1. Revert placement constraint to 'node.role == manager' in docker-stack.yaml"
log "  2. Redeploy — MinIO restarts on nuc-01 with its original data"
log ""
log "Migration script complete."
