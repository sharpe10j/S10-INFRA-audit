#!/usr/bin/env bash
set -euo pipefail

: "${CH_HOST:?need CH_HOST}"; : "${CH_HTTP_PORT:=8123}"

# Mock mode: just validate variables, no network calls
if [[ "${1:-}" == "--no-network" ]]; then
  [[ "${CH_HTTP_PORT}" =~ ^[0-9]+$ ]] || { echo "CH_HTTP_PORT invalid"; exit 1; }
  echo "ClickHouse vars OK (mock mode)"
  exit 0
fi

# Safer curl defaults + bypass proxies for this host
curl_args=( "--silent" "--show-error" "--fail" )
curl_args+=( "--noproxy" "${CH_HOST}" )

# Expect HTTP 200 and a single "1\n"
out="$(curl "${curl_args[@]}" "http://${CH_HOST}:${CH_HTTP_PORT}/?query=SELECT%201" || true)"
if [[ "$out" == "1" ]]; then
  echo "ClickHouse OK (${CH_HOST}:${CH_HTTP_PORT})"
  exit 0
else
  echo "ClickHouse ping failed: got '$out'"
  exit 1
fi
