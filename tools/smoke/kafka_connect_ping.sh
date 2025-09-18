#!/usr/bin/env bash
set -euo pipefail

: "${CONNECT_HOST:?need CONNECT_HOST}"
: "${CONNECT_PORT:=8083}"

if [[ "${1:-}" == "--no-network" ]]; then
  [[ "${CONNECT_PORT}" =~ ^[0-9]+$ ]] || { echo "CONNECT_PORT invalid"; exit 1; }
  echo "Kafka Connect vars OK (mock mode)"
  exit 0
fi

# Bypass proxies for CONNECT_HOST; keep strict curl error reporting
code="$(curl --silent --show-error --fail --noproxy "${CONNECT_HOST}" -o /dev/null -w '%{http_code}' \
       "http://${CONNECT_HOST}:${CONNECT_PORT}/connectors" || true)"
if [[ "$code" == "200" ]]; then
  echo "Kafka Connect OK (${CONNECT_HOST}:${CONNECT_PORT})"
  exit 0
else
  echo "Kafka Connect ping failed (${CONNECT_HOST}:${CONNECT_PORT}) http=${code}"
  exit 1
fi
