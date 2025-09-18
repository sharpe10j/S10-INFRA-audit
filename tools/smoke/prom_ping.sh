#!/usr/bin/env bash
set -euo pipefail

: "${PROM_URL:=http://localhost:9090}"

if [[ "${1:-}" == "--no-network" ]]; then
  [[ "$PROM_URL" =~ ^https?:// ]] || { echo "PROM_URL invalid"; exit 1; }
  echo "Prometheus vars OK (mock mode)"
  exit 0
fi

code="$(curl --silent --show-error --fail -o /dev/null -w '%{http_code}' "${PROM_URL}/-/ready" || true)"
if [[ "$code" == "200" ]]; then
  echo "Prometheus OK (${PROM_URL})"
  exit 0
else
  echo "Prometheus not ready (${PROM_URL}) http=${code}"
  exit 1
fi
