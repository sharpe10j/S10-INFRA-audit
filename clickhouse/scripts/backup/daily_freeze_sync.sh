#!/usr/bin/env bash
# daily_freeze_sync.sh — Freeze & rsync ClickHouse table data for a specific day
# Usage:
#   daily_freeze_sync.sh <database> <table> [YYYY-MM-DD]
# Examples:
#   daily_freeze_sync.sh database1 production_test_table_1
#   daily_freeze_sync.sh database1 production_test_table_1 2025-01-02

set -euo pipefail

# ======= LOAD ENV (shared across servers/services) =======
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
# Optional split files (not required)
[[ -f /etc/sharpe10/dev.secrets ]] && { set -a; . /etc/sharpe10/dev.secrets; set +a; }
[[ -f /etc/sharpe10/dev.local   ]] && { set -a; . /etc/sharpe10/dev.local;   set +a; }

# ======= ARGS =======
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <database> <table> [YYYY-MM-DD]"
  exit 1
fi
DB="$1"
TABLE="$2"
DAY_NY="${3:-$(date -d 'yesterday' +%F)}"  # default: yesterday
TZ="${TZ:-America/New_York}"

# ======= CONFIG (from env with safe fallbacks) =======
# ClickHouse connection (bare metal on server1)
CH_HOST="${CH_HOST:-${SERVER1_HOST:-server1}}"
CH_PORT="${CH_PORT:-9000}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-}"  # empty means no --password flag

# Local snapshot (shadow) root
SHADOW_BASE="${FREEZE_ROOT:-/var/lib/clickhouse/shadow}"

# Remote backup target (Server2)
REMOTE_SSH_USER="${REMOTE_SSH_USER:-jake_morrison}"
REMOTE_HOST="${SERVER2_HOST:-server2}"
REMOTE_BACKUP_ROOT="${REMOTE_BACKUP_ROOT:-/backups}"
REMOTE_BASE="${REMOTE_BACKUP_ROOT}/clickhouse/partitions/${DB}/${TABLE}"

# SSH options (key path can come from env, with sensible default)
SSH_KEY_SERVER2="${SSH_KEY_SERVER2:-$HOME/.ssh/id_ed25519_server2}"
SSH_OPTS="-i ${SSH_KEY_SERVER2} -o StrictHostKeyChecking=accept-new"

# Local retention for shadow tags
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-7}"

# Tag with underscores (no %2D): e.g., backup_2025_01_02_153045
DAY_TAG="$(echo "$DAY_NY" | tr '-' '_')"
TAG="backup_${DAY_TAG}_$(date -u +%H%M%S)"

# ClickHouse client
CH_CLIENT=(clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" --format TSVRaw)
[[ -n "$CH_PASSWORD" ]] && CH_CLIENT+=(--password "$CH_PASSWORD")

log(){ echo "[$(date +'%F %T')] $*"; }

log "Start: db=${DB} table=${TABLE} day=${DAY_NY} tz=${TZ} tag=${TAG}"

# ======= DISCOVER PARTITIONS FOR THE DAY =======
SQL_PARTS="
WITH toDate('${DAY_NY}') AS d
SELECT DISTINCT partition_id
FROM system.parts
WHERE database='${DB}'
  AND table='${TABLE}'
  AND active
  AND toDate(toTimeZone(min_time,'${TZ}')) <= d
  AND toDate(toTimeZone(max_time,'${TZ}')) >= d
ORDER BY partition_id;
"
mapfile -t IDS < <("${CH_CLIENT[@]}" --query "$SQL_PARTS")
if [[ ${#IDS[@]} -eq 0 ]]; then
  log "No partitions found for ${DAY_NY} on ${DB}.${TABLE}. Nothing to freeze."
  exit 0
fi
log "Partitions to freeze: ${IDS[*]}"

# ======= FREEZE EACH PARTITION =======
for ID in "${IDS[@]}"; do
  log "FREEZE PARTITION ID '${ID}' WITH NAME '${TAG}'"
  "${CH_CLIENT[@]}" --query \
    "ALTER TABLE ${DB}.${TABLE} FREEZE PARTITION ID '${ID}' WITH NAME '${TAG}'"
done

# ======= FIND SNAPSHOT SOURCE PATH (Atomic vs Ordinary) =======
UUID="$("${CH_CLIENT[@]}" --query "SELECT uuid FROM system.tables WHERE database='${DB}' AND name='${TABLE}' LIMIT 1" | tr -d '\r')"
SRC=""
if [[ -n "$UUID" && "$UUID" != "00000000-0000-0000-0000-000000000000" ]]; then
  # Atomic layout -> shadow/<TAG>/store/<first3>/<uuid>/
  PREFIX="${UUID:0:3}"
  SRC="${SHADOW_BASE}/${TAG}/store/${PREFIX}/${UUID}/"
else
  # Ordinary layout -> shadow/<TAG>/data/<db>/<table>/
  SRC="${SHADOW_BASE}/${TAG}/data/${DB}/${TABLE}/"
fi
log "Snapshot source path: ${SRC}"
sudo ls -lah "${SRC}" >/dev/null

# ======= RSYNC TO SERVER2 =======
DEST="${REMOTE_SSH_USER}@${REMOTE_HOST}:${REMOTE_BASE}/${TAG}/"

# 1) Ensure the remote directory exists
ssh ${SSH_OPTS} "${REMOTE_SSH_USER}@${REMOTE_HOST}" \
  "mkdir -p '${REMOTE_BASE}/${TAG}'"

# 2) Copy the frozen parts (SRC) to DEST using the SSH key
log "Rsync ${SRC} -> ${DEST}"
sudo rsync -aH --delete -e "ssh ${SSH_OPTS}" \
  "${SRC}" "${DEST}"

# ======= PRUNE OLD LOCAL SHADOWS =======
log "Pruning local shadows older than ${LOCAL_RETENTION_DAYS} days"
sudo find "${SHADOW_BASE}" -mindepth 1 -maxdepth 1 -type d -mtime +${LOCAL_RETENTION_DAYS} -print -exec sudo rm -rf {} +

log "Done: tag=${TAG}"

