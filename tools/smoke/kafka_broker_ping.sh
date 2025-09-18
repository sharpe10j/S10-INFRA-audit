#!/usr/bin/env bash
set -euo pipefail

# External host:port for a quick TCP check (from your dev.env)
: "${KAFKA_BROKERS_EXTERNAL:?need KAFKA_BROKERS_EXTERNAL}"

host="${KAFKA_BROKERS_EXTERNAL%:*}"
port="${KAFKA_BROKERS_EXTERNAL##*:}"

# Pure bash TCP check (no nc required)
timeout 3 bash -lc "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || {
  echo "Kafka broker TCP check failed (${host}:${port})"
  exit 1
}
echo "Kafka broker OK (${host}:${port})"
