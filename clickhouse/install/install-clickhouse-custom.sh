#!/usr/bin/env bash
set -euo pipefail
# Install your custom ClickHouse  binary and systemd units.
# Repo layout this script expects:
#   clickhouse/
#     artifacts/                # contains 'clickhouse' or version subdirs with that file
#       [24.3.1/]clickhouse
#     systemd/
#       clickhouse-server.service
#       clickhouse-keeper.service (optional)
#
# Result:
#   /opt/sharpe10/clickhouse/bin/clickhouse
#   /usr/local/bin/{clickhouse,clickhouse-server,clickhouse-client,clickhouse-keeper} -> symlinks
#   /etc/systemd/system/{clickhouse-server.service,clickhouse-keeper.service}

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ART_BASE="$REPO_ROOT/clickhouse/artifacts"   # <-- your binaries root
BIN_DST="/opt/sharpe10/clickhouse/bin"
ETC_CH="/etc/clickhouse-server"
ETC_KP="/etc/clickhouse-keeper"
VAR_DATA="/var/lib/clickhouse"
VAR_LOG="/var/log/clickhouse"

# ---- locate the directory that actually contains the 'clickhouse' binary ----
ART_DIR=""
if [[ -x "$ART_BASE/clickhouse" ]]; then
  ART_DIR="$ART_BASE"
else
  # Prefer a versioned subdir whose name sorts highest and that contains 'clickhouse'
  # (e.g., clickhouse/artifacts/24.3.1/clickhouse)
  CANDIDATE="$(ls -1d "$ART_BASE"/*/ 2>/dev/null | sed 's#/*$##' | sort -V | tail -n1 || true)"
  if [[ -n "${CANDIDATE:-}" && -x "$CANDIDATE/clickhouse" ]]; then
    ART_DIR="$CANDIDATE"
  fi
fi

if [[ -z "$ART_DIR" || ! -x "$ART_DIR/clickhouse" ]]; then
  echo "ERROR: couldn't find executable 'clickhouse' under $ART_BASE" >&2
  echo "       Expect either: $ART_BASE/clickhouse  OR  $ART_BASE/<version>/clickhouse" >&2
  exit 1
fi

echo "[1/6] Stop any running clickhouse-server (from apt or prior runs)"
if systemctl is-active --quiet clickhouse-server 2>/dev/null; then
  systemctl stop clickhouse-server || true
fi

if dpkg -l | grep -q '^ii  clickhouse-server' 2>/dev/null; then
  echo "NOTE: APT clickhouse-server package detected. Binaries will be overridden by your custom build."
fi

echo "[2/6] Create user and directories"
id -u clickhouse >/dev/null 2>&1 || useradd --system --home "$VAR_DATA" --shell /usr/sbin/nologin clickhouse
mkdir -p "$BIN_DST" "$ETC_CH" "$ETC_KP" "$VAR_DATA" "$VAR_LOG"
chown -R clickhouse:clickhouse "$VAR_DATA" "$VAR_LOG"

echo "[3/6] Install binary and create PATH symlinks"
install -o root -g root -m 0755 "$ART_DIR/clickhouse" "$BIN_DST/"

# multi-call symlinks (one file, different argv[0] names)
ln -sf "$BIN_DST/clickhouse" /usr/local/bin/clickhouse
ln -sf "$BIN_DST/clickhouse" /usr/local/bin/clickhouse-server
ln -sf "$BIN_DST/clickhouse" /usr/local/bin/clickhouse-client
ln -sf "$BIN_DST/clickhouse" /usr/local/bin/clickhouse-keeper

echo "[4/6] Install systemd units and reload"
install -o root -g root -m 0644 "$REPO_ROOT/clickhouse/systemd/clickhouse-server.service" \
  /etc/systemd/system/clickhouse-server.service

if [[ -f "$REPO_ROOT/clickhouse/systemd/clickhouse-keeper.service" ]]; then
  install -o root -g root -m 0644 "$REPO_ROOT/clickhouse/systemd/clickhouse-keeper.service" \
    /etc/systemd/system/clickhouse-keeper.service
fi

systemctl daemon-reload

echo "[5/6] Seed config files if missing (render step will overwrite/update)"
[[ -f "$ETC_CH/config.xml" ]]  || touch "$ETC_CH/config.xml"
[[ -f "$ETC_CH/users.xml"  ]]  || touch "$ETC_CH/users.xml"
[[ -f "$ETC_KP/keeper_config.xml" ]] || touch "$ETC_KP/keeper_config.xml"
chown -R clickhouse:clickhouse "$ETC_CH" "$ETC_KP"

echo "[6/6] Enable services (start happens after you render configs)"
systemctl enable clickhouse-server
[[ -f /etc/systemd/system/clickhouse-keeper.service ]] && systemctl enable clickhouse-keeper || true

echo "Custom ClickHouse installed."
echo "Next steps:"
echo "  1) Render configs with your env:"
echo "       sudo KEEPER_SERVER_ID=<0|1|2> DST_DIR=/etc/clickhouse-server \\"
echo "            ./clickhouse/configs/config-templates/render-clickhouse-configs.sh"
echo "  2) If this host runs Keeper:"
echo "       sudo install -o root -g root -m 0644 /etc/clickhouse-server/keeper_config.xml /etc/clickhouse-keeper/keeper_config.xml"
echo "  3) Restart services:"
echo "       sudo systemctl restart clickhouse-keeper || true"
echo "       sudo systemctl restart clickhouse-server"
