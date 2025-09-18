#!/usr/bin/env bash
set -euo pipefail

: "${KAFKA_BROKERS_EXTERNAL:?need KAFKA_BROKERS_EXTERNAL}"

host="${KAFKA_BROKERS_EXTERNAL%:*}"
port="${KAFKA_BROKERS_EXTERNAL##*:}"

if [[ "${1:-}" == "--no-network" ]]; then
  [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || { echo "KAFKA_BROKERS_EXTERNAL invalid (need host:port)"; exit 1; }
  echo "Kafka broker vars OK (mock mode)"
  exit 0
fi

# Pure bash TCP check (no nc required)
timeout 3 bash -lc "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || {
  echo "Kafka broker TCP check failed (${host}:${port})"
  exit 1
}
echo "Kafka broker OK (${host}:${port})"
