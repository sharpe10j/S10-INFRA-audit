#!/usr/bin/env bash
# ch_restore_day.sh — Restore ClickHouse table partitions for a given day (or tag)
# Works with backups produced by ch_freeze_day.sh
#
# Usage:
#   ch_restore_day.sh <database> <table> <YYYY-MM-DD> [TAG]
# Examples:
#   ch_restore_day.sh database1 production_test_table_1 2025-01-02
#   ch_restore_day.sh database1 production_test_table_1 2025-01-02 backup_2025_01_02_193447

set -euo pipefail

# ====== LOAD ENV (adds only configurability; logic below is unchanged) ======
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
[[ -f /etc/sharpe10/dev.secrets ]] && { set -a; . /etc/sharpe10/dev.secrets; set +a; }
[[ -f /etc/sharpe10/dev.local   ]] && { set -a; . /etc/sharpe10/dev.local;   set +a; }

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 <database> <table> <YYYY-MM-DD> [TAG]"
  exit 1
fi

DB="$1"
TABLE="$2"
DAY_NY="$3"                                   # required day
DAY_TAG="$(echo "$DAY_NY" | tr '-' '_')"      # e.g. 2025_01_02
TAG="${4:-}"                                  # optional explicit tag

# ====== CONFIG (now overridable via /etc/sharpe10/dev.env) ======
# ClickHouse connection
CH_HOST="${CH_HOST:-${SERVER1_HOST:-127.0.0.1}}"
CH_PORT="${CH_PORT:-9000}"
CH_USER="${CH_USER:-default}"
# Support either CH_PASS (old var) or CH_PASSWORD (env file)
CH_PASS="${CH_PASS:-${CH_PASSWORD:-}}"

# SSH/remote info
REMOTE_SSH_USER="${REMOTE_SSH_USER:-jake_morrison}"
REMOTE_HOST="${REMOTE_HOST:-${SERVER2_HOST:-10.0.0.225}}"
REMOTE_BACKUP_ROOT="${REMOTE_BACKUP_ROOT:-/backups}"
REMOTE_BASE="${REMOTE_BASE:-${REMOTE_BACKUP_ROOT}/clickhouse/partitions/${DB}/${TABLE}}"

# Key used to reach server2; keep your original default but allow override
SSH_KEY="${SSH_KEY:-${SSH_KEY_SERVER2:-/root/.ssh/id_ed25519_server2}}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=accept-new"

# Local ClickHouse roots
DATA_BASE="${DATA_BASE:-/var/lib/clickhouse}"   # root path from <path> in config.xml

# ====== Helpers (unchanged) ======
CH_CLIENT=(clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" --format TSVRaw)
[[ -n "$CH_PASS" ]] && CH_CLIENT+=(--password "$CH_PASS")

log(){ echo "[$(date +'%F %T')] $*"; }

# ====== Determine TAG if not provided (pick newest for the day) ======
if [[ -z "$TAG" ]]; then
  log "Selecting newest backup tag for day ${DAY_NY} on ${REMOTE_HOST}..."
  # List remote tags and pick the newest that begins with backup_<YYYY_MM_DD>_
  TAG=$(ssh ${SSH_OPTS} ${REMOTE_SSH_USER}@${REMOTE_HOST} \
    "bash -lc 'ls -1 ${REMOTE_BASE} | grep -E ^backup_${DAY_TAG}_ | sort | tail -n1'") || true
  if [[ -z "$TAG" ]]; then
    echo "ERROR: No tag found on ${REMOTE_HOST}:${REMOTE_BASE} for day ${DAY_NY} (pattern backup_${DAY_TAG}_*)"
    exit 1
  fi
fi
log "Using TAG: ${TAG}"

# ====== Discover table layout (Atomic vs Ordinary) and detached folder ======
UUID="$("${CH_CLIENT[@]}" --query "SELECT uuid FROM system.tables WHERE database='${DB}' AND name='${TABLE}' LIMIT 1" | tr -d '\r')" || true

if [[ -n "$UUID" && "$UUID" != "00000000-0000-0000-0000-000000000000" ]]; then
  # Atomic layout
  PREFIX="${UUID:0:3}"
  DETACHED_DIR="${DATA_BASE}/store/${PREFIX}/${UUID}/detached"
else
  # Ordinary layout
  DETACHED_DIR="${DATA_BASE}/data/${DB}/${TABLE}/detached"
fi

sudo mkdir -p "${DETACHED_DIR}"
log "Local detached dir: ${DETACHED_DIR}"

# ====== Rsync parts from Server2 into detached/ ======
SRC="${REMOTE_SSH_USER}@${REMOTE_HOST}:${REMOTE_BASE}/${TAG}/"
DST="${DETACHED_DIR}/"

log "Rsync from ${SRC} -> ${DST}"
# (If Server2 requires sudo to read that path, use: --rsync-path='sudo rsync')
sudo rsync -aH -e "ssh ${SSH_OPTS}" "${SRC}" "${DST}"

# Capture just-copied part directory names (first-level dirs)
mapfile -t PART_DIRS < <(find "${DETACHED_DIR}" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort)

if [[ ${#PART_DIRS[@]} -eq 0 ]]; then
  echo "ERROR: No part directories found in ${DETACHED_DIR} after rsync."
  exit 1
fi

# Derive unique partition_ids from part directory names (prefix before first underscore)
declare -A PARTITION_IDS=()
for d in "${PART_DIRS[@]}"; do
  pid="${d%%_*}"         # everything before first underscore
  # Partition IDs in your table are long hex strings like 02cdb0...
  # Filter to plausible hex-only IDs:
  if [[ "$pid" =~ ^[0-9a-f]{8,}$ ]]; then
    PARTITION_IDS["$pid"]=1
  fi
done

if [[ ${#PARTITION_IDS[@]} -eq 0 ]]; then
  echo "ERROR: Could not infer partition IDs from detached parts in ${DETACHED_DIR}."
  echo "Example dirs: ${PART_DIRS[*]:0:5}"
  exit 1
fi

log "Will ATTACH partitions: ${!PARTITION_IDS[@]}"

# ====== ATTACH each partition ======
for PID in "${!PARTITION_IDS[@]}"; do
  log "ALTER TABLE ${DB}.${TABLE} ATTACH PARTITION ID '${PID}'"
  "${CH_CLIENT[@]}" --query "ALTER TABLE ${DB}.${TABLE} ATTACH PARTITION ID '${PID}'"
done

log "Restore complete. Validate row counts as needed."

