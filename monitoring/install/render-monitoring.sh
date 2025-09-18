#!/usr/bin/env bash
set -euo pipefail

# Renders monitoring templates and prepares host bind-mount directories.
# Usage: ./monitoring/install/render-monitoring.sh [--env-file /etc/sharpe10/dev.env]

ENV_FILE="/etc/sharpe10/dev.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="${REPO_ROOT}/monitoring/templates"
OUT_DIR="${REPO_ROOT}/monitoring/configs"

# Load env (and optional overlays)
ENV_DIR_RUNTIME="/etc/sharpe10"
set -a
. "${ENV_FILE}"
[[ -f "${ENV_DIR_RUNTIME}/dev.secrets" ]] && . "${ENV_DIR_RUNTIME}/dev.secrets"
[[ -f "${ENV_DIR_RUNTIME}/dev.local"   ]] && . "${ENV_DIR_RUNTIME}/dev.local"
set +a

# Defaults (only used if not set in env)
: "${PROM_ROOT:=/opt/prometheus}"
: "${ALERTM_ROOT:=/opt/alertmanager}"
: "${GRAFANA_ROOT:=/opt/grafana}"

: "${PROMETHEUS_PORT:=9090}"
: "${ALERTMANAGER_PORT:=9093}"
: "${GRAFANA_PORT:=3000}"
: "${NODE_EXPORTER_PORT:=9100}"
: "${KAFKA_EXPORTER_PORT:=9308}"

: "${KAFKA_VERSION:=3.6.0}"

: "${ALERT_SMTP_HOSTPORT:=smtp.gmail.com:587}"
: "${ALERT_SMTP_FROM:=Sharpe_10 Alerts <jmorrison@sharpe10.com>}"
: "${ALERT_SMTP_USERNAME:=jmorrison@sharpe10.com}"
: "${ALERT_SMTP_REQUIRE_TLS:=true}"
: "${ALERT_DEFAULT_RECEIVER:=team-email}"
: "${ALERT_EMAIL_TO:=jmorrison@sharpe10.com}"
: "${ALERT_GROUP_WAIT:=30s}"
: "${ALERT_GROUP_INTERVAL:=5m}"
: "${ALERT_REPEAT_INTERVAL:=12h}"

mkdir -p "${OUT_DIR}"

# Ensure host bind mounts exist (idempotent)
sudo mkdir -p "${PROM_ROOT}/rules" "${ALERTM_ROOT}" "${GRAFANA_ROOT}/provisioning"
sudo chown -R root:root "${PROM_ROOT}" "${ALERTM_ROOT}" "${GRAFANA_ROOT}" || true
sudo chmod -R 755       "${PROM_ROOT}" "${ALERTM_ROOT}" "${GRAFANA_ROOT}" || true

render() {
  local in="$1" out="$2" vars="$3"
  envsubst "${vars}" <"${in}" >"${out}"
  echo "rendered: ${out}"
}

# Whitelist the variables each template expects (avoids accidental clobbering)
PROM_VARS='${ALERTMANAGER_HOST} ${ALERTMANAGER_PORT} ${SERVER1_IP} ${SERVER2_IP} ${SERVER3_IP} ${NODE_EXPORTER_PORT} ${KAFKA_EXPORTER_PORT}'
AM_VARS='${ALERT_SMTP_HOSTPORT} ${ALERT_SMTP_FROM} ${ALERT_SMTP_USERNAME} ${ALERT_SMTP_REQUIRE_TLS} ${ALERT_DEFAULT_RECEIVER} ${ALERT_GROUP_WAIT} ${ALERT_GROUP_INTERVAL} ${ALERT_REPEAT_INTERVAL} ${ALERT_EMAIL_TO}'
STACK_VARS='${NODE_EXPORTER_PORT} ${KAFKA_BROKER_ADDR} ${KAFKA_VERSION} ${SERVER3_HOST} ${KAFKA_EXPORTER_PORT} ${PROMETHEUS_PORT} ${PROM_ROOT} ${ALERTM_ROOT} ${ALERTMANAGER_PORT} ${GRAFANA_PORT} ${GRAFANA_ROOT}'

# 1) Render templates into repo/configs
render "${TPL_DIR}/prometheus.yml.tmpl"         "${OUT_DIR}/prometheus.yml"       "${PROM_VARS}"
render "${TPL_DIR}/alertmanager.yml.tmpl"       "${OUT_DIR}/alertmanager.yml"     "${AM_VARS}"
render "${TPL_DIR}/monitoring.stack.yml.tmpl"   "${OUT_DIR}/monitoring.stack.yml" "${STACK_VARS}"

# 2) Copy configs to host bind-mount locations
sudo install -m 0644 "${OUT_DIR}/prometheus.yml"     "${PROM_ROOT}/prometheus.yml"
sudo install -m 0644 "${OUT_DIR}/alertmanager.yml"   "${ALERTM_ROOT}/alertmanager.yml"

# 3) Copy alerts.yml (not templated) from configs → host bind mount
#    If you later templatize it, swap this to use render() just like above.
if [[ -f "${REPO_ROOT}/monitoring/configs/alerts.yml" ]]; then
  sudo install -m 0644 "${REPO_ROOT}/monitoring/configs/alerts.yml" "${PROM_ROOT}/rules/alerts.yml"
else
  echo "WARN: monitoring/configs/alerts.yml not found; Prometheus will have no rules."
fi

echo "Monitoring configs staged under ${PROM_ROOT} and ${ALERTM_ROOT}."
echo "Stack file at: ${OUT_DIR}/monitoring.stack.yml"
