#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="$ENV_FILE" "$ROOT/install/render-kafka.sh"
docker stack deploy -c "$ROOT/configs/stack/docker-stack.yml" kafka
