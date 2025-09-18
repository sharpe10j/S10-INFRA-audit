#!/usr/bin/env bash
set -euo pipefail
# timing
SECONDS=0

# ===== Load env (adds configurability; behavior unchanged) =====
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
[[ -f /etc/sharpe10/dev.secrets ]] && { set -a; . /etc/sharpe10/dev.secrets; set +a; }
[[ -f /etc/sharpe10/dev.local   ]] && { set -a; . /etc/sharpe10/dev.local;   set +a; }

# ===== Defaults (now overridable via env) =====
# Local backup tree (native copies)
BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/clickhouse/backups}"

# ClickHouse connection
CH_HOST="${CH_HOST:-${SERVER1_HOST:-127.0.0.1}}"
CH_PORT="${CH_PORT:-9000}"
CH_USER="${CH_USER:-default}"
CH_PASS="${CH_PASS:-${CH_PASSWORD:-}}"

# ClickHouse data root (for locating shadows/store)
CH_DATA_ROOT="${CH_DATA_ROOT:-/var/lib/clickhouse}"

# Optional remote mirror
# Set SYNC_TO_REMOTE=true in /etc/sharpe10/dev.env to enable
SYNC_TO_REMOTE="${SYNC_TO_REMOTE:-false}"
REMOTE_SSH_USER="${REMOTE_SSH_USER:-jake_morrison}"
REMOTE_HOST="${REMOTE_HOST:-${SERVER2_HOST:-10.0.0.225}}"
# Remote native-backup root; script appends /<db>/<label>
REMOTE_NATIVE_ROOT="${REMOTE_NATIVE_ROOT:-/backups/clickhouse/native}"

# SSH key/options to reach remote (server2)
SSH_KEY="${SSH_KEY:-${SSH_KEY_SERVER2:-$HOME/.ssh/id_ed25519_server2}}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=accept-new"

usage() {
  cat <<USAGE
Usage:
  $0 table <db> <table> [label]
  $0 database <db> [label]
USAGE
  exit 1
}

log(){ echo "[$(date -u +'%F %T')]" "$@"; }

[[ $# -lt 2 ]] && usage

SCOPE="$1"; shift
case "$SCOPE" in
  table)
    [[ $# -lt 2 ]] && usage
    DB="$1"; TABLE="$2"; LABEL="${3:-weekly_$(date -u +%Y_%m_%d_%H_%M_%S)}"
    ;;
  database)
    [[ $# -lt 1 ]] && usage
    DB="$1"; LABEL="${2:-weekly_$(date -u +%Y_%m_%d_%H_%M_%S)}"
    ;;
  *) usage ;;
esac

# ===== Normalize label (no dashes, no weird chars) =====
LABEL="${LABEL//-/_}"
LABEL="${LABEL//[^A-Za-z0-9_]/_}"

# Identify the mount point to make the message clearer
MOUNT=$(df -P "$BACKUP_ROOT" | awk 'NR==2{print $6}')

# Record filesystem usage for BACKUP_ROOT's filesystem in bytes
FS_USED_BEFORE=$(df -B1 --output=used "$MOUNT" | tail -1 | tr -d ' ')
FS_AVAIL_BEFORE=$(df -B1 --output=avail "$MOUNT" | tail -1 | tr -d ' ')

# Pretty print helper
human_bytes() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$1"
  else
    echo "${1}B"
  fi
}

CH_CLIENT=(clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER")
[[ -n "$CH_PASS" ]] && CH_CLIENT+=(--password "$CH_PASS")

# Find where ClickHouse wrote the shadow snapshot for this table+label
find_freeze_src() {
  local db="$1" tbl="$2" label="$3"

  # 1) classic table-local path
  local c1="${CH_DATA_ROOT}/data/${db}/${tbl}/shadow/${label}/"
  # 2) global shadow path
  local c2="${CH_DATA_ROOT}/shadow/${label}/data/${db}/${tbl}/"
  # 3) Atomic (UUID) store path
  local uuid; uuid="$("${CH_CLIENT[@]}"  -q "SELECT uuid FROM system.tables WHERE database='${db}' AND name='${tbl}'")" || true
  local c3=""
  if [[ -n "${uuid:-}" && "${#uuid}" -ge 3 ]]; then
    local pfx="${uuid:0:3}"
    c3="${CH_DATA_ROOT}/store/${pfx}/${uuid}/shadow/${label}/"
  fi

  for cand in "$c1" "$c2" "$c3"; do
    if [[ -n "$cand" && -d "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done

  # As a last resort, try to locate it anywhere
  local found
  found="$(sudo find "${CH_DATA_ROOT}" -maxdepth 6 -type d -path "*/shadow/${label}" -print 2>/dev/null | head -n1 || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

freeze_one_table() {
  local db="$1" tbl="$2" label="$3"

  log "FREEZE \`${db}\`.\`${tbl}\` WITH NAME '${label}'"
  "${CH_CLIENT[@]}" -q "ALTER TABLE \`${db}\`.\`${tbl}\` FREEZE WITH NAME '${label}'"

  # --- locate where ClickHouse wrote the snapshot ---
  local src
  local c1="${CH_DATA_ROOT}/data/${db}/${tbl}/shadow/${label}/"
  local c2="${CH_DATA_ROOT}/shadow/${label}/data/${db}/${tbl}/"
  local uuid; uuid="$("${CH_CLIENT[@]}"  -q "SELECT uuid FROM system.tables WHERE database='${db}' AND name='${tbl}'" || true)"
  local c3=""
  if [[ -n "${uuid:-}" && "${#uuid}" -ge 3 ]]; then
    local pfx="${uuid:0:3}"
    c3="${CH_DATA_ROOT}/store/${pfx}/${uuid}/shadow/${label}/"
  fi
  for cand in "$c1" "$c2" "$c3"; do
    if [[ -n "$cand" && -d "$cand" ]]; then src="$cand"; break; fi
  done
  if [[ -z "${src:-}" ]]; then
    src="$(sudo find "${CH_DATA_ROOT}" -maxdepth 6 -type d -path "*/shadow/${label}" -print 2>/dev/null | head -n1 || true)"
  fi
  [[ -z "${src:-}" ]] && { echo "ERROR: Could not locate snapshot for ${db}.${tbl} (${label})" >&2; exit 1; }

  # --- copy snapshot out to the backup tree ---
  local dest="${BACKUP_ROOT}/${LABEL}/${db}/${tbl}/"
  log "Copy from: $src"
  log "Copy to  : $dest"
  sudo mkdir -p "$dest"
  sudo rsync -aH "$src/" "$dest"

  # --- save exact DDL for disaster recovery ---
  "${CH_CLIENT[@]}" -q "SHOW CREATE TABLE \`${db}\`.\`${tbl}\` FORMAT TSVRaw" > "${dest}/create_table.sql"
}

mkdir -p "${BACKUP_ROOT}/${LABEL}"

if [[ "$SCOPE" == "table" ]]; then
  freeze_one_table "$DB" "$TABLE" "$LABEL"
else
  # Freeze all MergeTree-family tables in the DB
  mapfile -t TABLES < <("${CH_CLIENT[@]}"  -q \
    "SELECT name FROM system.tables
     WHERE database='${DB}' AND engine ILIKE '%MergeTree%' ORDER BY name")
  for t in "${TABLES[@]}"; do
    freeze_one_table "$DB" "$t" "$LABEL"
  done
fi

if [[ "${SYNC_TO_REMOTE}" == "true" ]]; then
  dest="${REMOTE_SSH_USER}@${REMOTE_HOST}:${REMOTE_NATIVE_ROOT}/${DB}/${LABEL}/"
  log "Rsync snapshot to ${dest}"
  sudo rsync -aH --delete -e "ssh ${SSH_OPTS}" "${BACKUP_ROOT}/${LABEL}/" "$dest"
fi

log "Done. Snapshot at ${BACKUP_ROOT}/${LABEL}/"
echo "BACKUP elapsed: ${SECONDS}s"

# Path that holds this label’s backup(s)
LABEL_ROOT="${BACKUP_ROOT}/${LABEL}"

# If this run copied a single table, show that dir size
if [ -n "${dest:-}" ] && [[ -d "${BACKUP_ROOT}/${LABEL}/" ]]; then
  DIR_BYTES=$(du -sb -- "${BACKUP_ROOT}/${LABEL}/" | awk '{print $1}')
  if command -v numfmt >/dev/null 2>&1; then
    HUMAN_DIR=$(numfmt --to=iec --suffix=B "$DIR_BYTES")
  else
    HUMAN_DIR="${DIR_BYTES}B"
  fi
  printf 'Backup dir size (this label): %s (%s)\n' "$HUMAN_DIR" "${BACKUP_ROOT}/${LABEL}/"
fi

# Show the total size under this label root (may include multiple tables)
if [ -d "$LABEL_ROOT" ]; then
  LABEL_BYTES=$(du -sb -- "$LABEL_ROOT" | awk '{print $1}')
  if command -v numfmt >/dev/null 2>&1; then
    HUMAN_LABEL=$(numfmt --to=iec --suffix=B "$LABEL_BYTES")
  else
    HUMAN_LABEL="${LABEL_BYTES}B"
  fi
  printf 'Total size for label: %s (%s)\n' "$HUMAN_LABEL" "$LABEL_ROOT"
fi

# Filesystem usage delta for the filesystem that contains BACKUP_ROOT
read FS_USED_BEFORE FS_AVAIL_BEFORE <<EOF
$(df -B1 -- "$BACKUP_ROOT" | awk 'NR==2{print $3, $4}')
EOF

read FS_USED_AFTER  FS_AVAIL_AFTER  <<EOF
$(df -B1 -- "$BACKUP_ROOT" | awk 'NR==2{print $3, $4}')
EOF

DELTA=$(( FS_USED_AFTER - FS_USED_BEFORE ))

# friendly mountpoint name
MOUNT=$(df -P -- "$BACKUP_ROOT" | awk 'NR==2{print $6}')

if command -v numfmt >/dev/null 2>&1; then
  HUMAN_DELTA=$(numfmt --to=iec --suffix=B "$DELTA")
  HUMAN_AVAIL_BEFORE=$(numfmt --to=iec --suffix=B "$FS_AVAIL_BEFORE")
  HUMAN_AVAIL_AFTER=$(numfmt  --to=iec --suffix=B "$FS_AVAIL_AFTER")
else
  HUMAN_DELTA="${DELTA}B"
  HUMAN_AVAIL_BEFORE="${FS_AVAIL_BEFORE}B"
  HUMAN_AVAIL_AFTER="${FS_AVAIL_AFTER}B"
fi

printf 'FS used delta on %s: %s\n' "$MOUNT" "$HUMAN_DELTA"
printf 'Free space: before %s, after %s\n' "$HUMAN_AVAIL_BEFORE" "$HUMAN_AVAIL_AFTER"

