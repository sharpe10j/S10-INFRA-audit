#!/usr/bin/env bash
set -euo pipefail

: "${CH_HOST:?need CH_HOST}"; : "${CH_HTTP_PORT:=8123}"

# Expect HTTP 200 and a single "1\n"
out="$(curl -sS "http://${CH_HOST}:${CH_HTTP_PORT}/?query=SELECT%201")"
if [[ "$out" == "1" ]]; then
  echo "ClickHouse OK (${CH_HOST}:${CH_HTTP_PORT})"
  exit 0
else
  echo "ClickHouse ping failed: got '$out'"
  exit 1
fi
