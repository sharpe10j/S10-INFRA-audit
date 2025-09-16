#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./bootstrap_server.sh [--keeper-id N] [--env-file /etc/sharpe10/dev.env] [--no-apt]
#
# Notes:
# - Default runtime env file is /etc/sharpe10/dev.env
# - If that file is missing, we copy from repo: ./envs/dev.env (plus optional dev.secrets/dev.local)

KEEPER_ID=""
ENV_FILE="/etc/sharpe10/dev.env"
RUN_APT=1

usage() {
  echo "Usage: sudo $0 [--keeper-id N] [--env-file PATH] [--no-apt]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keeper-id) KEEPER_ID="$2"; shift 2 ;;
    --env-file)  ENV_FILE="$2";  shift 2 ;;
    --no-apt)    RUN_APT=0;      shift 1 ;;
    -h|--help)   usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  case_esac_done=true
  esac
done

# --- Paths ---
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE_DEFAULT_IN_REPO="${REPO_ROOT}/envs/dev.env"
ENV_DIR_RUNTIME="/etc/sharpe10"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root (use sudo)."
    exit 1
  fi
}

stage_env_if_missing() {
  # Only stage if the runtime file is missing and a repo default exists
  if [[ ! -f "${ENV_FILE}" && -f "${ENV_FILE_DEFAULT_IN_REPO}" ]]; then
    echo "Staging env from repo → ${ENV_DIR_RUNTIME}"
    mkdir -p "${ENV_DIR_RUNTIME}"
    install -m 0644 "${ENV_FILE_DEFAULT_IN_REPO}" "${ENV_DIR_RUNTIME}/dev.env"

    # Optional overlays (if the developer created them next to dev.env)
    local repo_env_dir; repo_env_dir="$(dirname "${ENV_FILE_DEFAULT_IN_REPO}")"
    if [[ -f "${repo_env_dir}/dev.secrets" ]]; then
      install -m 0600 "${repo_env_dir}/dev.secrets" "${ENV_DIR_RUNTIME}/dev.secrets"
    fi
    if [[ -f "${repo_env_dir}/dev.local" ]]; then
      install -m 0644 "${repo_env_dir}/dev.local" "${ENV_DIR_RUNTIME}/dev.local"
    fi
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing env file: ${ENV_FILE}"
    echo "Create it or place one at: ${ENV_FILE_DEFAULT_IN_REPO}"
    exit 1
  fi
}

load_env() {
  # shellcheck disable=SC1090
  set -a
  . "${ENV_FILE}"
  [[ -f "${ENV_DIR_RUNTIME}/dev.secrets" ]] && . "${ENV_DIR_RUNTIME}/dev.secrets"
  [[ -f "${ENV_DIR_RUNTIME}/dev.local"   ]] && . "${ENV_DIR_RUNTIME}/dev.local"
  set +a
}

# Create host data directories for Kafka/ZooKeeper (idempotent)
ensure_kafka_dirs() {
  # Only needed on the node that will run Kafka/ZK (server3 in your env)
  if [[ "$(hostname -s)" == "${SERVER3_HOST:-}" ]]; then
    echo "Ensuring Kafka/ZK data dirs under ${DATA_ROOT:-/opt/sharpe10/data} ..."
    mkdir -p "${ZK_DATA:-/opt/sharpe10/data/zookeeper}" \
             "${KAFKA_DATA:-/opt/sharpe10/data/kafka}"
    # Confluent images run as root; root:root + 755 is fine.
    chown -R root:root "${DATA_ROOT:-/opt/sharpe10/data}"
    chmod 755 "${ZK_DATA:-/opt/sharpe10/data/zookeeper}" \
              "${KAFKA_DATA:-/opt/sharpe10/data/kafka}"
  else
    echo "Skipping Kafka/ZK dir setup on $(hostname -s) (not ${SERVER3_HOST:-server3})."
  fi
}

install_prereqs() {
  if [[ ${RUN_APT} -eq 1 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "Installing prereqs (gettext-base for envsubst, git-lfs)…"
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y git-lfs gettext-base
      git lfs install || true
    else
      echo "apt-get not found; skipping prereqs."
    fi
  else
    echo "--no-apt specified; skipping prereqs."
  fi
}


# Ensure default ClickHouse log dirs exist (idempotent)
ensure_clickhouse_log_dirs() {
  # default Debian/Ubuntu package user/group is 'clickhouse'
  local user="clickhouse" group="clickhouse"

  for d in /var/log/clickhouse-server /var/log/clickhouse-keeper; do
    mkdir -p "$d"
    chown -R "$user:$group" "$d" || true
    chmod 755 "$d"
  done
  echo "ClickHouse log dirs ready."
}

render_kafka_if_server3() {
  if [[ "$(hostname -s)" == "${SERVER3_HOST:-}" ]]; then
    echo "Rendering Kafka configs on $(hostname -s)…"
    "${REPO_ROOT}/kafka/install/render-kafka.sh" || {
      echo "Kafka render failed"; exit 1; }
  else
    echo "Skipping Kafka render on $(hostname -s) (not ${SERVER3_HOST:-server3})."
  fi
}




main() {
  require_root
  stage_env_if_missing
  load_env
  install_prereqs
  ensure_kafka_dirs
  render_kafka_if_server3
  ensure_clickhouse_log_dirs

  # ---- ClickHouse (delegate to your existing installer) ----
  # Pass through keeper-id only if provided
  args=( )
  [[ -n "${KEEPER_ID}" ]] && args+=( --keeper-id "${KEEPER_ID}" )

  # Your ClickHouse orchestrator (already in your repo)
  "${REPO_ROOT}/clickhouse/setup_local.sh" "${args[@]}" --env-file "${ENV_FILE}"

  # ---- Add more services here as they’re ready ----
  # "${REPO_ROOT}/kafka/setup_local.sh"        --env-file "${ENV_FILE}"
  # "${REPO_ROOT}/monitoring/setup_local.sh"   --env-file "${ENV_FILE}"
  # "${REPO_ROOT}/whatever/setup_local.sh"     --env-file "${ENV_FILE}"

  echo "Bootstrap complete on $(hostname -s)."
}

main "$@"
