#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./bootstrap_server.sh --role <server1|server2|server3> [--keeper-id N] [--env-file /etc/sharpe10/dev.env] [--no-apt]
#
# Notes:
# - Env is staged from envs/<role>/dev.env → /etc/sharpe10/dev.env if missing.
# - Docker is only installed on server2/server3. Node Exporter host-install only on server1.

ROLE=""
KEEPER_ID=""
ENV_FILE="/etc/sharpe10/dev.env"
RUN_APT=1

usage(){ echo "Usage: sudo $0 --role <server1|server2|server3> [--keeper-id N] [--env-file PATH] [--no-apt]"; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)      ROLE="${2:-}"; shift 2 ;;
    --keeper-id) KEEPER_ID="${2:-}"; shift 2 ;;
    --env-file)  ENV_FILE="${2:-}"; shift 2 ;;
    --no-apt)    RUN_APT=0; shift 1 ;;
    -h|--help)   usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done
[[ -z "$ROLE" ]] && usage

require_root(){ [[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_DIR_RUNTIME="/etc/sharpe10"

stage_env(){
  # if /etc/sharpe10/dev.env is missing, seed from envs/<role>/dev.env
  if [[ ! -f "$ENV_FILE" ]]; then
    "$REPO_ROOT/ops/seed_env.sh" "$ROLE"
  fi
  [[ ! -f "$ENV_FILE" ]] && { echo "Missing $ENV_FILE; add envs/$ROLE/dev.env"; exit 1; }
}

load_env(){
  set -a
  . "$ENV_FILE"
  [[ -f "$ENV_DIR_RUNTIME/dev.secrets" ]] && . "$ENV_DIR_RUNTIME/dev.secrets"
  [[ -f "$ENV_DIR_RUNTIME/dev.local"   ]] && . "$ENV_DIR_RUNTIME/dev.local"
  set +a
}

foundation(){
  if [[ $RUN_APT -eq 1 ]]; then
    "$REPO_ROOT/ops/preflight.sh"
    # Docker only on swarm nodes
    if [[ "$ROLE" == "server2" || "$ROLE" == "server3" ]]; then
      "$REPO_ROOT/ops/install_docker.sh"
    else
      echo "[docker] skipped on $ROLE"
    fi
    "$REPO_ROOT/ops/install_python.sh"
  else
    echo "[apt] skipped by flag"
  fi
  "$REPO_ROOT/ops/setup_dirs.sh"
}

install_node_exporter_if_server1(){
  if [[ "$ROLE" == "server1" ]]; then
    "$REPO_ROOT/monitoring/install/install-node-exporter.sh" || true
  else
    echo "[node-exporter] skipped on $ROLE (runs via Swarm stack)"
  fi
}

ensure_clickhouse_log_dirs(){
  if [[ "$ROLE" != "server1" ]]; then return; fi
  local user="clickhouse" group="clickhouse"
  for d in /var/log/clickhouse-server /var/log/clickhouse-keeper; do
    mkdir -p "$d"; chown -R "$user:$group" "$d" || true; chmod 755 "$d"
  done
}

kafka_dirs_and_render_if_server3(){
  if [[ "$ROLE" == "server3" ]]; then
    mkdir -p "${ZK_DATA:-/opt/sharpe10/data/zookeeper}" "${KAFKA_DATA:-/opt/sharpe10/data/kafka}"
    chmod 755 "${ZK_DATA:-/opt/sharpe10/data/zookeeper}" "${KAFKA_DATA:-/opt/sharpe10/data/kafka}"
    "${REPO_ROOT}/kafka/install/render-kafka.sh"
  fi
}

deploy_by_role(){
  case "$ROLE" in
    server2)  # Swarm manager + monitoring
      "$REPO_ROOT/ops/init_swarm.sh"            # uses $SWARM_OVERLAY_NAME (default external-connect-overlay)
      "${REPO_ROOT}/monitoring/render-monitoring.sh"
      docker stack deploy -c monitoring/configs/monitoring.stack.yml s10-monitoring
      ;;
    server3)  # Kafka/ZK/Connect host
      kafka_dirs_and_render_if_server3
      "${REPO_ROOT}/kafka/install/deploy-kafka-stack.sh"
      ;;
    server1)  # ClickHouse bare metal
      ensure_clickhouse_log_dirs
      args=( ); [[ -n "$KEEPER_ID" ]] && args+=( --keeper-id "$KEEPER_ID" )
      "${REPO_ROOT}/clickhouse/setup_local.sh" "${args[@]}" --env-file "$ENV_FILE"
      ;;
    *) echo "Unknown role: $ROLE"; exit 1 ;;
  esac

  # host-side setups that apply everywhere (venv, configs, etc.)
  "${REPO_ROOT}/monitoring/setup_local.sh" --env-file "$ENV_FILE"
  "${REPO_ROOT}/validation/setup_local.sh" --env-file "$ENV_FILE"
}

main(){
  require_root
  stage_env
  load_env
  foundation
  install_node_exporter_if_server1
  deploy_by_role
  echo "Bootstrap complete on $(hostname -s) for role=$ROLE"
}
main "$@"
