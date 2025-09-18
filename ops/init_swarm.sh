#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }

NAME="${SWARM_OVERLAY_NAME:-external-connect-overlay}"

if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qiE 'active|pending'; then
  echo "[swarm] already active"
else
  IP="${1:-$(hostname -I | awk '{print $1}')}"
  docker swarm init --advertise-addr "$IP"
  mkdir -p .swarm
  echo "MANAGER_TOKEN=$(docker swarm join-token manager -q)" > .swarm/join_tokens
  echo "WORKER_TOKEN=$(docker swarm join-token worker -q)" >> .swarm/join_tokens
  echo "MANAGER_IP=$IP" >> .swarm/join_tokens
fi

docker network create --driver overlay --attachable "$NAME" || true
echo "[swarm] overlay '$NAME' present"
