#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="./envs/dev.env"
TMPL="./clickhouse/configs/config-templates/render-clickhouse-configs.sh"

rm -rf /tmp/chcfg1 /tmp/chcfg2
mkdir -p /tmp/chcfg1 /tmp/chcfg2

echo "== Dry run: simulate server1 =="
DST_DIR=/tmp/chcfg1 KEEPER_SERVER_ID=1 THIS_REPLICA=replica1 ENV_FILE="$ENV_FILE" $TMPL

echo "== Dry run: simulate server2 =="
DST_DIR=/tmp/chcfg2 KEEPER_SERVER_ID=2 THIS_REPLICA=replica2 ENV_FILE="$ENV_FILE" $TMPL

echo "== Sanity checks =="

check_dir() {
  local d="$1"
  echo "-- Inspect $d"
  ls -1 "$d"/{config.xml,clusters.xml,keeper_config.xml,users.xml,macros.xml,zookeeper.xml} 2>/dev/null

  grep -n '<remote_servers .*incl=' "$d/config.xml" || echo "MISSING remote_servers include"
  grep -n '<zookeeper .*incl='      "$d/config.xml" || echo "MISSING zookeeper include"
  grep -n '<macros .*incl='         "$d/config.xml" || echo "MISSING macros include"

  if [[ $(grep -c '<remote_servers .*incl=' "$d/config.xml") -ne 1 ]]; then echo "DUPLICATE remote_servers include"; fi
  if [[ $(grep -c '<zookeeper .*incl='      "$d/config.xml") -ne 1 ]]; then echo "DUPLICATE zookeeper include"; fi
  if [[ $(grep -c '<macros .*incl='         "$d/config.xml") -ne 1 ]]; then echo "DUPLICATE macros include"; fi

  ! grep -q '<remote_servers>' "$d/config.xml" || echo "INLINE <remote_servers> still present"
  ! grep -q '<zookeeper>'      "$d/config.xml" || echo "INLINE <zookeeper> still present"
  ! grep -q '<macros>'         "$d/config.xml" || echo "INLINE <macros> still present"

  grep -n '<http_port>' "$d/config.xml"
  grep -n '<tcp_port>'  "$d/config.xml"

  grep -n '/etc/clickhouse-server/users.xml' "$d/config.xml" || echo "users.xml path NOT rewritten"

  echo "macros.xml:"; sed -n '1,40p' "$d/macros.xml"
  echo "zookeeper.xml:"; sed -n '1,40p' "$d/zookeeper.xml"
  echo "clusters.xml:";  sed -n '1,80p' "$d/clusters.xml"

  if grep -R '\${[A-Za-z_][A-Za-z0-9_]*}' "$d" -n; then echo "ERROR: unresolved variables in $d"; fi

  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$d/config.xml" "$d/clusters.xml" "$d/zookeeper.xml" "$d/macros.xml" || true
  fi
  echo
}

cd "$repoWSL"
check_dir /tmp/chcfg1
check_dir /tmp/chcfg2

echo "== Re-run to check idempotency =="
DST_DIR=/tmp/chcfg1 KEEPER_SERVER_ID=1 THIS_REPLICA=replica1 ENV_FILE="$ENV_FILE" $TMPL >/dev/null
DST_DIR=/tmp/chcfg2 KEEPER_SERVER_ID=2 THIS_REPLICA=replica2 ENV_FILE="$ENV_FILE" $TMPL >/dev/null
check_dir /tmp/chcfg1
check_dir /tmp/chcfg2