#!/usr/bin/env bash
set -euo pipefail

# Where to read env vars from
ENV_FILE="${ENV_FILE:-/etc/sharpe10/dev.env}"

# Repo paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # clickhouse/configs
SRC_BASE="$BASE_DIR/base"                           # has your full config.xml & users.xml
TMPL_DIR="$BASE_DIR/config-templates"

# Where to write the generated files that CH/Keeper actually read
# Tip: set DST_DIR=/etc/clickhouse-server when you deploy
DST_DIR="${DST_DIR:-/home/jake_morrison/clickhouse_binaries}"

# ---- env load + defaults ----
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi

CH_PORT="${CH_PORT:-9000}"
CH_HTTP_PORT="${CH_HTTP_PORT:-8123}"

KEEPER_CLIENT_PORT="${KEEPER_CLIENT_PORT:-9181}"
KEEPER_RAFT_PORT="${KEEPER_RAFT_PORT:-9234}"
: "${KEEPER_SERVER_ID:?Set KEEPER_SERVER_ID=1|2 (or 3 if you add a third Keeper) before running}"
: "${SERVER1_HOST:?must be set}"
: "${SERVER2_HOST:?must be set}"
# SERVER3_HOST optional today

mkdir -p "$DST_DIR"

echo "[1/4] Render clusters.xml from template"
export SERVER1_HOST SERVER2_HOST CH_PORT
envsubst < "$TMPL_DIR/clusters.tmpl.xml" > "$DST_DIR/clusters.xml"

echo "[2/4] Render keeper_config.xml from template"
export KEEPER_SERVER_ID KEEPER_CLIENT_PORT KEEPER_RAFT_PORT
envsubst < "$TMPL_DIR/keeper_config.tmpl.xml" > "$DST_DIR/keeper_config.xml"

echo "[3/4] Generate config.xml from your base/config.xml with env overrides"
cp -f "$SRC_BASE/config.xml" "$DST_DIR/config.xml"

# Replace tcp/http ports
sed -i -E \
  -e "s#(<http_port>)[0-9]+(</http_port>)#\1${CH_HTTP_PORT}\2#g" \
  -e "s#(<tcp_port>)[0-9]+(</tcp_port>)#\1${CH_PORT}\2#g" \
  "$DST_DIR/config.xml"

# Remove any existing <remote_servers> block to avoid duplicates
sed -i -E 's#<remote_servers>(.|\n)*?</remote_servers>##g' "$DST_DIR/config.xml"

# Ensure config.xml includes clusters.xml via incl= (added before closing </yandex>)
# If an incl already exists, this is a no-op.
grep -q 'remote_servers .*incl=' "$DST_DIR/config.xml" || \
  sed -i -E 's#</yandex>#  <remote_servers incl="clusters.xml"/>\n</yandex>#' "$DST_DIR/config.xml"

echo "[4/4] Copy users.xml unchanged"
if [[ -f "$SRC_BASE/users.xml" ]]; then
  cp -f "$SRC_BASE/users.xml" "$DST_DIR/users.xml"
else
  echo "WARN: $SRC_BASE/users.xml not found; skipping copy"
fi

echo
echo "Wrote:"
ls -1 "$DST_DIR"/{config.xml,clusters.xml,keeper_config.xml,users.xml} 2>/dev/null || true
echo "Done. Restart services when ready:"
echo "  sudo install -o root -g root -m 0644 \"$DST_DIR/keeper_config.xml\" /etc/clickhouse-keeper/keeper_config.xml 2>/dev/null || true"
echo "  sudo systemctl restart clickhouse-keeper || true"
echo "  sudo systemctl restart clickhouse-server"
