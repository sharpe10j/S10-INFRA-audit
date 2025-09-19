#!/usr/bin/env bash
set -euo pipefail
for root in /srv/clickhouse /srv/kafka /srv/monitoring; do
  mkdir -p "$root"/{data,logs,conf,backups}
done
mkdir -p /srv/clickhouse/shadow /srv/clickhouse/native_backups

owner_spec="${SHARPE10_OWNER:-}"
if [[ -z "$owner_spec" ]]; then
  fallback_user="${SUDO_USER:-$(id -un)}"
  fallback_group="$(id -gn "$fallback_user" 2>/dev/null || id -gn)"
  owner_spec="${fallback_user}:${fallback_group}"
fi

owner_user="${owner_spec%%:*}"
if [[ "$owner_spec" == *":"* ]]; then
  owner_group="${owner_spec#*:}"
else
  owner_group="${owner_user}"
fi

if id -u "$owner_user" &>/dev/null; then
  if ! getent group "$owner_group" &>/dev/null; then
    owner_group="$(id -gn "$owner_user")"
  fi
  chown -R "${owner_user}:${owner_group}" /srv
else
  echo "[dirs] user '${owner_user}' not found; skipping chown" >&2
fi
echo "[dirs] created"
