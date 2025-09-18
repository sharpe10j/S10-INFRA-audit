#!/usr/bin/env bash
set -euo pipefail

: "${CONNECT_HOST:?need CONNECT_HOST}"
: "${CONNECT_PORT:=8083}"

curl_args=("--silent" "--show-error" "--fail" "--noproxy" "${CONNECT_HOST}" "-o" "/dev/null" "-w" "%{http_code}")
code="$(curl "${curl_args[@]}" "http://${CONNECT_HOST}:${CONNECT_PORT}/connectors" || true)"
if [[ "$code" == "200" ]]; then
  echo "Kafka Connect OK (${CONNECT_HOST}:${CONNECT_PORT})"
  exit 0
else
  echo "Kafka Connect ping failed (${CONNECT_HOST}:${CONNECT_PORT}) http=${code}"
  exit 1
fi
