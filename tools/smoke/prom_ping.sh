#!/usr/bin/env bash
set -euo pipefail

: "${PROM_URL:=http://localhost:9090}"

code="$(curl -sS -o /dev/null -w '%{http_code}' "${PROM_URL}/-/ready")"
if [[ "$code" == "200" ]]; then
  echo "Prometheus OK (${PROM_URL})"
  exit 0
else
  echo "Prometheus not ready (${PROM_URL}) http=${code}"
  exit 1
fi
