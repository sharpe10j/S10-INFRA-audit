#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo ./install-clickhouse-custom.sh [--force]
# Requires your repo is present on the host (rsynced by deploy script)
# and binaries exist under clickhouse/artifacts/clickhouse/<VERSION>/

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ART_DIR_BASE="$REPO_ROOT/clickhouse/artifacts/clickhouse"
BIN_DST="/opt/sharpe10/clickhouse/bin"
ETC_CH="/etc/clickhouse-server"
ETC_KP="/etc/clickhouse-keeper"
VAR_DATA="/var/lib/clickhouse"
VAR_LOG="/var/log/clickhouse"
FORCE="${1:-}"

# pick the latest version folder if not specified
if [[ -z "${CH_VER:-}" ]]; then
  CH_VER="$(ls -1 ${ART_DIR_BASE} | sort -V | tail -n1)"
fi
ART_DIR="${ART_DIR_BASE}/${CH_VER}"

if [[ ! -d "$ART_DIR" ]]; then
  echo "ERROR: binaries folder not found: $ART_DIR" >&2
  exit 1
fi

echo "[1/6] Ensure no conflicting apt package is running"
if systemctl is-active --quiet clickhouse-server 2>/dev/null; then
  # If it's your custom unit, fine; if apt package, we stop it
  echo "Stopping running clickhouse-server..."
  systemctl stop clickhouse-server || true
fi

if dpkg -l | grep -q '^ii  clickhouse-server'; then
  echo "APT package detected. You can keep it for deps, but binaries will be overridden."
fi

echo "[2/6] Create user and directories"
id -u clickhouse &>/dev/null || useradd --system --home "$VAR_DATA" --shell /usr/sbin/nologin clickhouse
mkdir -p "$BIN_DST" "$ETC_CH" "$ETC_KP" "$VAR_DATA" "$VAR_LOG"
chown -R clickhouse:clickhouse "$VAR_DATA" "$VAR_LOG"

echo "[3/6] Install binaries"
install -o root -g root -m 0755 "$ART_DIR"/clickhouse* "$BIN_DST"/
# symlinks into PATH
ln -sf "$BIN_DST/clickhouse-server" /usr/local/bin/clickhouse-server
ln -sf "$BIN_DST/clickhouse-client" /usr/local/bin/clickhouse-client
[[ -f "$BIN_DST/clickhouse-keeper" ]] && ln -sf "$BIN_DST/clickhouse-keeper" /usr/local/bin/clickhouse-keeper
ln -sf "$BIN_DST/clickhouse" /usr/local/bin/clickhouse

echo "[4/6] Install systemd units"
install -o root -g root -m 0644 "$REPO_ROOT/clickhouse/install/clickhouse-server.service" /etc/systemd/system/clickhouse-server.service
if [[ -f "$REPO_ROOT/clickhouse/install/clickhouse-keeper.service" && -f "$BIN_DST/clickhouse-keeper" ]]; then
  install -o root -g root -m 0644 "$REPO_ROOT/clickhouse/install/clickhouse-keeper.service" /etc/systemd/system/clickhouse-keeper.service
fi
systemctl daemon-reload

echo "[5/6] Seed config dirs if empty (render step will overwrite/update)"
[[ -f "$ETC_CH/config.xml" ]] || touch "$ETC_CH/config.xml"
[[ -f "$ETC_CH/users.xml"  ]] || touch "$ETC_CH/users.xml"
[[ -f "$ETC_KP/keeper_config.xml" ]] || touch "$ETC_KP/keeper_config.xml"
chown -R clickhouse:clickhouse "$ETC_CH" "$ETC_KP"

echo "[6/6] Enable services (they’ll actually start after configs are rendered)"
systemctl enable clickhouse-server
[[ -f /etc/systemd/system/clickhouse-keeper.service ]] && systemctl enable clickhouse-keeper || true

echo "Custom ClickHouse ${CH_VER} installed under $BIN_DST."
echo "Render configs next, then start/restart services."
