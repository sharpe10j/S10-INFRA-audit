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
SWARM_TOKENS_FILE="${REPO_ROOT}/.swarm/join_tokens"

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

join_swarm_if_server3(){
  if [[ "$ROLE" != "server3" ]]; then return; fi

  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
  if [[ "$state" =~ ^(active|pending)$ ]]; then
    echo "[swarm] server3 already part of Swarm (state=$state)"
    return
  fi

  if [[ ! -f "$SWARM_TOKENS_FILE" ]]; then
    echo "[swarm] join tokens missing at $SWARM_TOKENS_FILE"
    echo "         Run bootstrap on server2 first and copy .swarm/join_tokens to this host."
    exit 1
  fi

  # shellcheck disable=SC1090
  . "$SWARM_TOKENS_FILE"
  if [[ -z "${WORKER_TOKEN:-}" || -z "${MANAGER_IP:-}" ]]; then
    echo "[swarm] join tokens file missing WORKER_TOKEN or MANAGER_IP"
    exit 1
  fi

  docker swarm join --token "$WORKER_TOKEN" "${MANAGER_IP}:2377"
  echo "[swarm] server3 joined Swarm manager at ${MANAGER_IP}"
}

wait_for_swarm_worker(){
  local target="${SERVER3_HOST:-server3}"
  local timeout="${SWARM_JOIN_WAIT_SECS:-120}"
  local interval=5 elapsed=0

  if docker node inspect "$target" >/dev/null 2>&1; then
    local status
    status="$(docker node inspect -f '{{.Status.State}}' "$target" 2>/dev/null || echo "unknown")"
    if [[ "$status" == "ready" ]]; then
      echo "[swarm] worker '$target' already ready"
      return 0
    fi
  fi

  echo "[swarm] waiting for worker '$target' to join (timeout=${timeout}s)"
  while (( elapsed < timeout )); do
    if docker node inspect "$target" >/dev/null 2>&1; then
      local status
      status="$(docker node inspect -f '{{.Status.State}}' "$target" 2>/dev/null || echo "unknown")"
      if [[ "$status" == "ready" ]]; then
        echo "[swarm] worker '$target' ready"
        return 0
      fi
    fi
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done

  echo "[swarm] worker '$target' not ready after ${timeout}s"
  return 1
}

deploy_kafka_stack_from_manager(){
  if wait_for_swarm_worker; then
    "${REPO_ROOT}/kafka/install/deploy-kafka-stack.sh"
  else
    echo "[kafka] skipping stack deploy until worker '${SERVER3_HOST:-server3}' is joined"
  fi
}

deploy_by_role(){
  case "$ROLE" in
    server2)  # Swarm manager + monitoring
      "$REPO_ROOT/ops/init_swarm.sh"            # uses $SWARM_OVERLAY_NAME (default external-connect-overlay)
      "$REPO_ROOT/ops/label_swarm_nodes.sh" --env-file "$ENV_FILE"
      "${REPO_ROOT}/monitoring/render-monitoring.sh"
      docker stack deploy -c monitoring/configs/monitoring.stack.yml s10-monitoring
      deploy_kafka_stack_from_manager
      ;;
    server3)  # Kafka/ZK/Connect host
      kafka_dirs_and_render_if_server3
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
  join_swarm_if_server3
  deploy_by_role
  echo "Bootstrap complete on $(hostname -s) for role=$ROLE"
}
main "$@"
