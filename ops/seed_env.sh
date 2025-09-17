#!/usr/bin/env bash
set -euo pipefail
ROLE="${1:-}"; [[ -z "$ROLE" ]] && { echo "usage: $0 <server1|server2|server3>"; exit 1; }
SRC="envs/${ROLE}/dev.env"; DST="/etc/sharpe10/dev.env"
mkdir -p /etc/sharpe10
[[ -f "$SRC" ]] && install -m 0644 "$SRC" "$DST"
echo "[env] seeded $DST from $SRC"
