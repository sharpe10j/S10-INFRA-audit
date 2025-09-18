#!/usr/bin/env bash
set -euo pipefail

: "${CH_HOST:?need CH_HOST}"; : "${CH_HTTP_PORT:=8123}"

curl_args=("--silent" "--show-error" "--fail")
# Corporate environments often inject HTTP(S)_PROXY which breaks direct
# connections to internal hosts like "server1"/"server2".  Force curl to
# bypass the proxy for the ClickHouse host so we actually hit the target.
curl_args+=("--noproxy" "${CH_HOST}")

# Expect HTTP 200 and a single "1\n"
out="$(curl "${curl_args[@]}" "http://${CH_HOST}:${CH_HTTP_PORT}/?query=SELECT%201" || true)"
if [[ "$out" == "1" ]]; then
  echo "ClickHouse OK (${CH_HOST}:${CH_HTTP_PORT})"
  exit 0
else
  echo "ClickHouse ping failed: got '$out'"
  exit 1
fi
