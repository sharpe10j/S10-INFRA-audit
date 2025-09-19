#!/usr/bin/env bash
set -euo pipefail

usage(){
  cat <<USAGE
Usage: sudo $0 [--env-file PATH] [--manager HOST]... [--worker HOST]...

Applies Docker Swarm node labels so services that require specific roles can be
scheduled. Without explicit hosts the script falls back to environment values
(SWARM_MANAGER_HOSTS/SERVER2_HOST for managers and
SWARM_WORKER_HOSTS/SERVER3_HOST for workers).
USAGE
  exit 2
}

ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"
MANAGER_LABEL="${SWARM_MANAGER_LABEL:-swarm_node=manager}"
WORKER_LABEL="${SWARM_WORKER_LABEL:-swarm_node=worker}"
MANAGER_HOSTS=()
WORKER_HOSTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --manager)
      MANAGER_HOSTS+=("${2:-}")
      shift 2
      ;;
    --worker)
      WORKER_HOSTS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

require_root(){
  if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo" >&2
    exit 1
  fi
}

load_env(){
  if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  else
    echo "[labels] env file '$ENV_FILE' not found; relying on current environment"
  fi
}

resolve_hosts(){
  if [[ ${#MANAGER_HOSTS[@]} -eq 0 ]]; then
    if [[ -n "${SWARM_MANAGER_HOSTS:-}" ]]; then
      local -a manager_defaults=()
      read -r -a manager_defaults <<< "${SWARM_MANAGER_HOSTS}"
      MANAGER_HOSTS+=("${manager_defaults[@]}")
    elif [[ -n "${SERVER2_HOST:-}" ]]; then
      MANAGER_HOSTS+=("${SERVER2_HOST}")
    fi
  fi

  if [[ ${#WORKER_HOSTS[@]} -eq 0 ]]; then
    if [[ -n "${SWARM_WORKER_HOSTS:-}" ]]; then
      local -a worker_defaults=()
      read -r -a worker_defaults <<< "${SWARM_WORKER_HOSTS}"
      WORKER_HOSTS+=("${worker_defaults[@]}")
    elif [[ -n "${SERVER3_HOST:-}" ]]; then
      WORKER_HOSTS+=("${SERVER3_HOST}")
    fi
  fi
}

ensure_manager(){
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"
  if [[ ! "$state" =~ ^(active|pending)$ ]]; then
    echo "[labels] Swarm is not active on this node (state=$state)" >&2
    exit 1
  fi

  local control
  control="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)"
  if [[ "$control" != "true" ]]; then
    echo "[labels] This host is not a Swarm manager; cannot update node labels" >&2
    exit 1
  fi
}

trim_empty(){
  local -n arr=$1
  local filtered=()
  for host in "${arr[@]:-}"; do
    if [[ -n "$host" ]]; then
      filtered+=("$host")
    fi
  done
  arr=("${filtered[@]}")
}

current_label(){
  local node=$1 key=${2%%=*}
  docker node inspect --format "{{ index .Spec.Labels \"$key\" }}" "$node" 2>/dev/null || true
}

apply_label(){
  local node=$1 label=$2 role=$3 key value existing
  key="${label%%=*}"
  value="${label#*=}"

  if ! docker node inspect "$node" >/dev/null 2>&1; then
    echo "[labels] skipping $role '$node' (node not found in Swarm yet)"
    return 0
  fi

  existing="$(current_label "$node" "$label")"
  if [[ "$existing" == "$value" ]]; then
    echo "[labels] $role '$node' already labeled $key=$value"
    return 0
  fi

  docker node update --label-add "$label" "$node" >/dev/null
  echo "[labels] set $key=$value on $role '$node'"
}

main(){
  require_root
  load_env
  resolve_hosts
  trim_empty MANAGER_HOSTS
  trim_empty WORKER_HOSTS

  if [[ ${#MANAGER_HOSTS[@]} -eq 0 && ${#WORKER_HOSTS[@]} -eq 0 ]]; then
    echo "[labels] no manager or worker hosts specified"
    exit 0
  fi

  ensure_manager

  local unique=()
  declare -A seen=()
  for host in "${MANAGER_HOSTS[@]}"; do
    if [[ -n "$host" && -z "${seen[$host]:-}" ]]; then
      unique+=("manager:$host")
      seen[$host]=1
    fi
  done
  for host in "${WORKER_HOSTS[@]}"; do
    if [[ -n "$host" && -z "${seen[$host]:-}" ]]; then
      unique+=("worker:$host")
      seen[$host]=1
    fi
  done

  for entry in "${unique[@]}"; do
    local role host label
    role="${entry%%:*}"
    host="${entry#*:}"
    case "$role" in
      manager) label="$MANAGER_LABEL" ;;
      worker)  label="$WORKER_LABEL" ;;
      *) continue ;;
    esac
    apply_label "$host" "$label" "$role"
  done
}

main "$@"
