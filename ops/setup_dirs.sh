#!/usr/bin/env bash
set -euo pipefail
for root in /srv/clickhouse /srv/kafka /srv/monitoring; do
  mkdir -p "$root"/{data,logs,conf,backups}
done
mkdir -p /srv/clickhouse/shadow /srv/clickhouse/native_backups
chown -R jake_morrison:jake_morrison /srv
echo "[dirs] created"
