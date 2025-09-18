#!/usr/bin/env bash
set -euo pipefail

: "${CONNECT_HOST:?need CONNECT_HOST}"
: "${CONNECT_PORT:=8083}"

code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${CONNECT_HOST}:${CONNECT_PORT}/connectors")"
if [[ "$code" == "200" ]]; then
  echo "Kafka Connect OK (${CONNECT_HOST}:${CONNECT_PORT})"
  exit 0
else
  echo "Kafka Connect ping failed (${CONNECT_HOST}:${CONNECT_PORT}) http=${code}"
  exit 1
fi
