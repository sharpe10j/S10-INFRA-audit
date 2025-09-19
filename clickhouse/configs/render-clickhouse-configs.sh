#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/config-templates/render-clickhouse-configs.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "ERROR: expected render helper at $TARGET" >&2
  exit 1
fi

exec "$TARGET" "$@"
