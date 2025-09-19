#!/usr/bin/env bash
set -euo pipefail

# Use the runtime env (or override with --env-file)
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"

# Repo-relative paths
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$ROOT/config-templates"
OUT="$ROOT/configs"

# ABS path to repo root for bind mounts in Swarm
REPO_ROOT_LOCAL="$(cd "$ROOT/.." && pwd)"

FALLBACK_ENV_BASE="${REPO_ROOT_LOCAL}/envs/dev.env"
ROLE_DEFAULT="server3"
ROLE_FROM_ENV="${ROLE:-}"  # allow callers to set ROLE explicitly

# Load env + optional overlays
set -a
if [[ -f "$ENV_FILE" ]]; then
  . "$ENV_FILE"
  [[ -f /etc/sharpe10/dev.local   ]] && . /etc/sharpe10/dev.local
  [[ -f /etc/sharpe10/dev.secrets ]] && . /etc/sharpe10/dev.secrets
else
  echo "WARN: $ENV_FILE not found; falling back to repo defaults." >&2
  if [[ -f "$FALLBACK_ENV_BASE" ]]; then
    . "$FALLBACK_ENV_BASE"
  else
    set +a
    echo "ERROR: fallback env $FALLBACK_ENV_BASE is missing" >&2
    exit 1
  fi

  FALLBACK_ROLE="${ROLE_FROM_ENV:-$ROLE_DEFAULT}"
  FALLBACK_ROLE_ENV="${REPO_ROOT_LOCAL}/envs/${FALLBACK_ROLE}/dev.env"
  if [[ -f "$FALLBACK_ROLE_ENV" ]]; then
    . "$FALLBACK_ROLE_ENV"
  else
    echo "INFO: role env $FALLBACK_ROLE_ENV not found; continuing with base defaults." >&2
  fi
fi
set +a

: "${REPO_ROOT:=$REPO_ROOT_LOCAL}"

mkdir -p "$OUT/stack" "$OUT/connect"

# Export all vars used by the templates
export REPO_ROOT SERVER1_HOST SERVER2_HOST SERVER3_HOST \
       KAFKA_BROKERS_INTERNAL KAFKA_BROKERS_EXTERNAL KAFKA_BROKERS \
       CONNECT_HOST CONNECT_PORT CONNECT_URL \
       CONNECTOR_NAME CH_HOST CH_HTTP_PORT CH_USER CH_PASSWORD CH_DB \
       CONNECT_TASKS_MAX CONNECT_TOPICS CONNECT_TOPIC2TABLE CONNECT_AUTO_CREATE \
       CONNECT_BATCH_SIZE CONNECT_LINGER_MS \
       KAFKA_FETCH_MIN_BYTES KAFKA_FETCH_MAX_BYTES KAFKA_FETCH_MAX_WAIT_MS \
       KAFKA_MAX_PARTITION_FETCH KAFKA_MAX_POLL_RECORDS \
       DATA_ROOT ZK_DATA KAFKA_DATA

# 1) Stack
envsubst < "$TMPL/stack/docker-stack.tmpl.yml" > "$OUT/stack/docker-stack.yml"

# 2) Connector JSON
envsubst < "$TMPL/connect/clickhouse-sink.tmpl.json" > "$OUT/connect/clickhouse-sink.json"

# 3) Static log4j (no templating)
LOG4J_SRC="$ROOT/configs/connect/connect-log4j.properties"
LOG4J_DST="$OUT/connect/connect-log4j.properties"
if [[ -f "$LOG4J_SRC" ]]; then
  if [[ "$LOG4J_SRC" != "$LOG4J_DST" ]]; then
    cp -f "$LOG4J_SRC" "$LOG4J_DST"
  fi
else
  echo "WARN: $LOG4J_SRC not found; skipping log4j copy" >&2
fi

# Sanity: bail if anything is still ${UNRESOLVED}
if grep -R '\${[A-Za-z_][A-Za-z0-9_]*}' "$OUT" -n; then
  echo "ERROR: unresolved variables in $OUT"
  exit 1
fi

echo "Rendered Kafka → $OUT"
