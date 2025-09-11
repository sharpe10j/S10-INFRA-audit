#!/usr/bin/env bash
set -euo pipefail
SECONDS=0

# ===== Load env (adds configurability; behavior unchanged) =====
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
[[ -f /etc/sharpe10/dev.secrets ]] && { set -a; . /etc/sharpe10/dev.secrets; set +a; }
[[ -f /etc/sharpe10/dev.local   ]] && { set -a; . /etc/sharpe10/dev.local;   set +a; }

# ===== Config (now overridable via /etc/sharpe10/dev.env) =====
CH_HOST="${CH_HOST:-${SERVER1_HOST:-127.0.0.1}}"
CH_PORT="${CH_PORT:-9000}"
CH_USER="${CH_USER:-default}"
CH_PASS="${CH_PASS:-${CH_PASSWORD:-}}"

# New default backup location -> /mnt/backup (still overridable)
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup}"

usage() {
  cat <<USAGE
Usage:
  $0 table    <db> <table> <label> [target_table]
  $0 database <db> <label> [suffix]

Examples:
  # Restore one table into <table>_restored
  $0 table database1 production_test_table_1 weekly_2025-08-19
  # Restore one table into a custom name
  $0 table database1 production_test_table_1 weekly_2025-08-19 pt1_tmp

  # Restore every table in DB with suffix _restored
  $0 database database1 weekly_2025-08-19
  # Restore with custom suffix
  $0 database database1 weekly_2025-08-19 _scratch
USAGE
  exit 1
}

[[ $# -lt 1 ]] && usage
MODE="$1"; shift

CH_CLIENT=(clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER")
[[ -n "$CH_PASS" ]] && CH_CLIENT+=(--password "$CH_PASS")

log(){ echo "[$(date -u +'%F %T')]" "$@"; }

restore_one_table() {
  local db="$1" table="$2" label="$3" target="${4}"
  local base="${BACKUP_ROOT}/${label}/${db}/${table}"
  local src="${base}/store/"

  [[ -d "$src" ]] || { echo "Missing snapshot for ${db}.${table} at ${src}" >&2; return 1; }

  # --- guard: don't clobber an existing target ---
  if "${CH_CLIENT[@]}" -q "EXISTS TABLE \`${db}\`.\`${target}\`" | grep -q 1; then
    echo "Target ${db}.${target} already exists. Drop/rename it or choose a different target." >&2
    return 1
  fi

  # --- obtain DDL: prefer saved DDL, else SHOW CREATE from live source table ---
  local ddl=""
  if [[ -f "${base}/create_table.sql" ]]; then
    ddl="$(cat "${base}/create_table.sql")"
  else
    ddl="$("${CH_CLIENT[@]}" -q "SHOW CREATE TABLE \`${db}\`.\`${table}\`FORMAT TSVRaw" 2>/dev/null || true)"
  fi
  [[ -z "$ddl" ]] && { echo "No DDL available. Create ${db}.${target} manually and rerun." >&2; return 1; }

  # rename the table in the DDL to the new target name
  local ddl_restored
  echo "DEBUG: DDL first line (raw): $(printf '%s\n' "$ddl" | head -n1)"

  # Match ANY table token after 'CREATE TABLE' (with/without backticks, with/without db prefix)
  pattern='^[[:space:]]*CREATE[[:space:]]+TABLE[[:space:]]+[^[:space:]\(]+'
  replace="CREATE TABLE \`$db\`.\`$target\`"

  ddl_restored="$(printf '%s\n' "$ddl" | sed -E "1s|$pattern|$replace|")"

  # If Replicated engine, rewrite Keeper path to use target name
  if grep -qE 'ENGINE[[:space:]]*=[[:space:]]*Replicated' <<< "$ddl_restored"; then
    echo "DEBUG: Detected Replicated engine; rewriting Keeper path to use target name."
    re_table=$(printf '%s' "$table"  | sed 's/[.[\*^$()+?{}|/]/\\&/g')
    re_target=$(printf '%s' "$target" | sed 's/[&/]/\\&/g')

    ddl_restored="$(printf '%s' "$ddl_restored" \
      | sed -E "s#(Replicated[^\\(]*\\([[:space:]]*'/?clickhouse/tables/[^/]+/)${re_table}([/'\"])#\\1${re_target}\\2#g")"
    ddl_restored="$(printf '%s' "$ddl_restored" \
      | sed -E "s/\\{table\\}/${re_target}/g; s/\\{database\\}/${db}/g")"
  fi

  echo "DDL first line: $(printf '%s\n' "$ddl_restored" | head -n1)"
  echo "DEBUG: target db.table = ${db}.${target}"
  log "Creating table ${db}.${target}"
  "${CH_CLIENT[@]}" --multiquery -q "$ddl_restored"

  # --- attach parts from the snapshot ---
  local detached="/var/lib/clickhouse/data/${db}/${target}/detached"
  sudo mkdir -p "$detached"

  mapfile -t PART_DIRS < <(sudo find "$src" -type d -regextype posix-extended -regex '.*/[^/]+_[0-9]+_[0-9]+_[0-9]+$' | sort)

  log "Attaching ${#PART_DIRS[@]} parts into ${db}.${target}"
  for dir in "${PART_DIRS[@]}"; do
    part="$(basename "$dir")"
    sudo rsync -aH "$dir/" "${detached}/${part}/"
    "${CH_CLIENT[@]}" -q "ALTER TABLE \`${db}\`.\`${target}\` ATTACH PART '${part}'"
  done
}

case "$MODE" in
  table)
    [[ $# -lt 3 ]] && usage
    DB="$1"; TABLE="$2"; LABEL="$3"; TARGET="${4:-${TABLE}_restored}"
    restore_one_table "$DB" "$TABLE" "$LABEL" "$TARGET"
    ;;
  database)
    [[ $# -lt 2 ]] && usage
    DB="$1"; LABEL="$2"; SUFFIX="${3:-_restored}"
    mapfile -t SNAP_TABLES < <(find "${BACKUP_ROOT}/${LABEL}/${DB}" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)
    for t in "${SNAP_TABLES[@]}"; do
      TARGET="${t}${SUFFIX}"
      restore_one_table "$DB" "$t" "$LABEL" "$TARGET" || true
    done
    ;;
  *) usage ;;
esac

log "Restore complete."
echo "RESTORE elapsed: ${SECONDS}s"

