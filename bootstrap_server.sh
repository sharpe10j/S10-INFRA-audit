#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./bootstrap_server.sh [--keeper-id N] [--env-file /etc/sharpe10/dev.env]

KEEPER_ID=""
ENV_FILE="/etc/sharpe10/dev.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keeper-id) KEEPER_ID="$2"; shift 2 ;;
    --env-file)  ENV_FILE="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# Pre-reqs used by multiple components (run once)
apt-get update -y
apt-get install -y git-lfs gettext-base # envsubst for templating
git lfs install

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Ensure env file exists
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"; exit 1
fi

# === ClickHouse ===
#"$REPO_ROOT/clickhouse/setup_local.sh" ${KEEPER_ID:+--keeper-id "$KEEPER_ID"} --env-file "$ENV_FILE"
args=()
[[ -n "${KEEPER_ID}" ]] && args+=(--keeper-id "$KEEPER_ID")
"$REPO_ROOT/clickhouse/setup_local.sh" "${args[@]}" --env-file "$ENV_FILE"

# === Add more later ===
# "$REPO_ROOT/docker/whatever/setup_local.sh"
# "$REPO_ROOT/kafka/setup_local.sh"
# "$REPO_ROOT/monitoring/setup_local.sh"

echo "Bootstrap complete on $(hostname -s)."
