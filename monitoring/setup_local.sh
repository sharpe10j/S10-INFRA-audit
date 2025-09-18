#!/usr/bin/env bash
set -euo pipefail

# Orchestrates monitoring setup: node-exporter install, render, secret, deploy.
# Usage: ./monitoring/setup_local.sh [--env-file /etc/sharpe10/dev.env] [--no-deploy]

ENV_FILE="/etc/sharpe10/dev.env"
DEPLOY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)  ENV_FILE="$2"; shift 2 ;;
    --no-deploy) DEPLOY=0; shift 1 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR_RUNTIME="/etc/sharpe10"

# Load env so we can read SERVER3_HOST, etc.
set -a
. "${ENV_FILE}"
[[ -f "${ENV_DIR_RUNTIME}/dev.secrets" ]] && . "${ENV_DIR_RUNTIME}/dev.secrets"
[[ -f "${ENV_DIR_RUNTIME}/dev.local"   ]] && . "${ENV_DIR_RUNTIME}/dev.local"
set +a

# 1) Install Node Exporter (idempotent) on this server
#"${REPO_ROOT}/monitoring/install/install-node-exporter.sh"

# 1) Install Node Exporter (only on server1; Swarm handles 2 & 3)
if [[ "$(hostname -s)" == "${SERVER1_HOST}" ]]; then
  "${REPO_ROOT}/monitoring/install/install-node-exporter.sh"
else
  echo "Skipping systemd node-exporter (this is not ${SERVER1_HOST})."
fi

# 2) Render monitoring templates & stage configs on this server
"${REPO_ROOT}/monitoring/install/render-monitoring.sh" --env-file "${ENV_FILE}"

# 3) Ensure Alertmanager SMTP secret exists (optional)
if docker info >/dev/null 2>&1; then
  if ! docker secret ls --format '{{.Name}}' | grep -qx 'alertmanager_smtp_pass'; then
    if [[ -n "${ALERT_SMTP_PASSWORD:-}" ]]; then
      printf '%s' "${ALERT_SMTP_PASSWORD}" | docker secret create alertmanager_smtp_pass -
      echo "Created docker secret: alertmanager_smtp_pass"
    else
      echo "WARN: ALERT_SMTP_PASSWORD not set; skipping secret creation."
    fi
  fi
fi

# 4) Deploy stack (only from a Swarm manager; safe to re-run)
if [[ ${DEPLOY} -eq 1 ]]; then
  if docker info >/dev/null 2>&1 && docker info | grep -q 'Is Manager: true'; then
    docker stack deploy -c "${REPO_ROOT}/monitoring/configs/monitoring.stack.yml" monitoring
  else
    echo "Not a Swarm manager here; skipping 'docker stack deploy'."
  fi
fi

echo "Monitoring setup complete on $(hostname -s)."
