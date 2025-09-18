#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./clickhouse/setup_local.sh --keeper-id 1 [--env-file /etc/sharpe10/dev.env] [--force-install]
# If --keeper-id is omitted, we try to infer from hostname (server1=1, server2=2, else 0).

KEEPER_ID=""
ENV_FILE="/etc/sharpe10/dev.env"
FORCE_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keeper-id) KEEPER_ID="$2"; shift 2 ;;
    --env-file)  ENV_FILE="$2";  shift 2 ;;
    --force-install) FORCE_INSTALL=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Infer keeper id from short hostname if not provided
if [[ -z "${KEEPER_ID}" ]]; then
  case "$(hostname -s)" in
    server1) KEEPER_ID=1 ;;
    server2) KEEPER_ID=2 ;;
    *)       KEEPER_ID=0 ;;     # no keeper on this host
  esac
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"            # repo/clickhouse/..
INSTALL_DIR="$REPO_ROOT/clickhouse/install"
TMPL_DIR="$REPO_ROOT/clickhouse/configs/config-templates"

# 1) Make sure LFS objects are present if repo was cloned shallow
if command -v git >/dev/null 2>&1 && command -v git-lfs >/dev/null 2>&1; then
  (cd "$REPO_ROOT" && git lfs pull || true)
fi

# 2) Install custom binaries + systemd units (idempotent)
if ! command -v clickhouse-server >/dev/null 2>&1 || [[ "$FORCE_INSTALL" == "1" ]]; then
  sudo "$INSTALL_DIR/install-clickhouse-custom.sh"
else
  echo "clickhouse-server present; skipping binary install (use --force-install to override)."
fi

# 3) Render configs into /etc/clickhouse-server from /etc/sharpe10/dev.env
sudo KEEPER_SERVER_ID="$KEEPER_ID" DST_DIR=/etc/clickhouse-server ENV_FILE="$ENV_FILE" \
  "$TMPL_DIR/render-clickhouse-configs.sh"

# 4) If this host runs Keeper, copy the keeper config into place
if [[ "$KEEPER_ID" != "0" ]]; then
  sudo install -o root -g root -m 0644 /etc/clickhouse-server/keeper_config.xml \
       /etc/clickhouse-keeper/keeper_config.xml 2>/dev/null || true
fi

# 5) Restart services
sudo systemctl restart clickhouse-keeper || true
sudo systemctl restart clickhouse-server

# 6) Health checks
clickhouse-client -q "SELECT version()" || true
clickhouse-client -q "SELECT host_name,port FROM system.clusters" || true

echo "ClickHouse setup complete on $(hostname -s)."
