#!/bin/bash

# Required args
BROKER="10.0.0.210:29092"
TOPIC="docker_topic_1"
HOST="10.0.0.208"
PORT="9000"
DB="database1"
TABLE="production_test_table_1"

# Time range (in nanoseconds)
#START_NS=1735790340000000000
#END_NS=16354079600000000005873200000000000

# ===== Time range =====
# Only START_TIME is needed — script finds the stop time automatically
# You can use human-readable UTC ("YYYY-MM-DD HH:MM:SS") or epoch ms
START_TIME=1755026950000


# Output files
# Output files
SUMMARY="summary.json"               # single JSON object
DETAILS="details.json"              # JSONL
BAD_ROWS="bad_rows.json"            # JSONL
CH_QUERY_LOG="ch_query_windows.json" # JSONL
BATCH_SIZE=10000

# Clear old files before starting
: > "$SUMMARY"
: > "$DETAILS"
: > "$BAD_ROWS"
: > "$CH_QUERY_LOG"

# ===== Run the validation script =====
python3 validate_batched_3.py \
  --broker "$BROKER" \
  --topic "$TOPIC" \
  --group "validator_group" \
  --start-time "$START_TIME" \
  --batch-size "$BATCH_SIZE" \
  --ch-host "$HOST" \
  --ch-port "$PORT" \
  --ch-database "$DB" \
  --table "$TABLE" \
  --summary "$SUMMARY" \
  --details "$DETAILS" \
  --bad-rows "$BAD_ROWS" \
  --ch-query-log "$CH_QUERY_LOG"

####################################################################################################

#!/usr/bin/env bash
set -euo pipefail

# --- locations ---
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${THIS_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/envs/dev.env"

# --- load envs (repo + optional runtime overlays) ---
set -a
[[ -f "${ENV_FILE}" ]] && . "${ENV_FILE}"
[[ -f /etc/sharpe10/dev.secrets ]] && . /etc/sharpe10/dev.secrets
[[ -f /etc/sharpe10/dev.local   ]] && . /etc/sharpe10/dev.local
set +a

# --- inputs ---
START_TIME="${1:-${VALIDATION_START_TIME:-}}"
if [[ -z "${START_TIME}" ]]; then
  echo "Usage: $0 <START_TIME as epoch_ms or 'YYYY-MM-DD HH:MM:SS'>" >&2
  exit 2
fi

# Kafka / ClickHouse from env (no hard-coded IPs)
BROKER="${KAFKA_BROKER_ADDR:?Set KAFKA_BROKER_ADDR in envs/dev.env}"
TOPIC="${VALIDATION_TOPIC:-${CONNECT_TOPICS:-docker_topic_1}}"

CH_HOST="${CH_HOST:?Set CH_HOST in envs/dev.env}"   # e.g. server1
CH_PORT="${CH_PORT:-9000}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CH_PASSWORD:-}"
CH_DB="${CH_DB:?Set CH_DB in envs/dev.env}"

# Table: prefer explicit, else derive from CONNECT_TOPIC2TABLE="topic=table"
if [[ -n "${VALIDATION_CH_TABLE:-}" ]]; then
  TABLE="${VALIDATION_CH_TABLE}"
elif [[ -n "${CONNECT_TOPIC2TABLE:-}" && "${CONNECT_TOPIC2TABLE}" == *"="* ]]; then
  IFS='=' read -r _t _table <<<"${CONNECT_TOPIC2TABLE}"
  if [[ "${_t}" == "${TOPIC}" ]]; then TABLE="${_table}"; fi
fi
TABLE="${TABLE:-production_test_table_1}"

# Batch + flags
BATCH_SIZE="${VALIDATION_BATCH_SIZE:-10000}"
COMMIT_FLAG=()
case "${VALIDATION_COMMIT:-0}" in
  1|true|TRUE|yes|YES) COMMIT_FLAG=(--commit) ;;
esac

# --- ensure venv ---
# Use --use-lock if you want exact versions from requirements.lock
USE_LOCK="${VALIDATION_USE_LOCK:-0}"
if [[ "${USE_LOCK}" == "1" ]]; then
  "${REPO_ROOT}/validation/install/ensure_venv.sh" --use-lock
else
  "${REPO_ROOT}/validation/install/ensure_venv.sh"
fi
PY="${REPO_ROOT}/validation/venv/bin/python"

# --- choose python file (supports your rename) ---
PY_FILE="${REPO_ROOT}/validation/validate_batched.py"
[[ -f "${PY_FILE}" ]] || PY_FILE="${REPO_ROOT}/validation/validate_batched_3.py"

# --- outputs (json arrays/objects) ---
SUMMARY="${VALIDATION_SUMMARY:-summary.json}"
DETAILS="${VALIDATION_DETAILS:-details.json}"
BAD_ROWS="${VALIDATION_BAD_ROWS:-bad_rows.json}"
CH_QUERY_LOG="${VALIDATION_CH_QUERY_LOG:-ch_query_windows.json}"
: > "${SUMMARY}"; : > "${DETAILS}"; : > "${BAD_ROWS}"; : > "${CH_QUERY_LOG}"

# --- run ---
exec "${PY}" "${PY_FILE}" \
  --broker "${BROKER}" \
  --topic "${TOPIC}" \
  --start-time "${START_TIME}" \
  --batch-size "${BATCH_SIZE}" \
  --ch-host "${CH_HOST}" \
  --ch-port "${CH_PORT}" \
  --ch-user "${CH_USER}" \
  --ch-password "${CH_PASSWORD}" \
  --ch-database "${CH_DB}" \
  --table "${TABLE}" \
  --summary "${SUMMARY}" \
  --details "${DETAILS}" \
  --bad-rows "${BAD_ROWS}" \
  --ch-query-log "${CH_QUERY_LOG}" \
  "${COMMIT_FLAG[@]}"
