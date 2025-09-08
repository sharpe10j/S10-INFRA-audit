#!/usr/bin/env bash
set -euo pipefail
SECONDS=0

CH_HOST="127.0.0.1"
CH_PORT="9000"
CH_USER="default"
CH_PASS=""
BACKUP_ROOT="/var/lib/clickhouse/backups"

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
  # Robustly rewrite the first CREATE TABLE line to the target name.
  # 1) keep the regex in single quotes (backticks are literal)
  # 2) build the replacement with escaped backticks
  echo "DEBUG: DDL first line (raw): $(printf '%s\n' "$ddl" | head -n1)"

  # Match ANY table token after 'CREATE TABLE' (with/without backticks, with/without db prefix)
  # Examples matched: `db`.`tbl`, db.tbl, `tbl`, tbl
  pattern='^[[:space:]]*CREATE[[:space:]]+TABLE[[:space:]]+[^[:space:]\(]+'
  replace="CREATE TABLE \`$db\`.\`$target\`"

  # Apply just to the FIRST line
  ddl_restored="$(printf '%s\n' "$ddl" | sed -E "1s|$pattern|$replace|")"

  # If the engine is Replicated*MergeTree and the Keeper path contains the original table name,
  # rewrite the path to use the target table name so we don't collide with the live replica.
  if grep -qE 'ENGINE[[:space:]]*=[[:space:]]*Replicated' <<< "$ddl_restored"; then
    echo "DEBUG: Detected Replicated engine; rewriting Keeper path to use target name."

    # escape values for regex/sed safety
    re_table=$(printf '%s' "$table"  | sed 's/[.[\*^$()+?{}|/]/\\&/g')
    re_target=$(printf '%s' "$target" | sed 's/[&/]/\\&/g')

  # Case 1: literal path like '/clickhouse/tables/shard1/<table>'
    ddl_restored="$(printf '%s' "$ddl_restored" \
      | sed -E "s#(Replicated[^\\(]*\\([[:space:]]*'/?clickhouse/tables/[^/]+/)${re_table}([/'\"])#\\1${re_target}\\2#g")"

  # Case 2: macros in the path, e.g. '/clickhouse/tables/{shard}/{table}'
    ddl_restored="$(printf '%s' "$ddl_restored" \
      | sed -E "s/\\{table\\}/${re_target}/g; s/\\{database\\}/${db}/g")"
  fi

  # Optional: sanity-print the first line we’ll run
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
    # Restore each table that exists in the snapshot
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
