#!/usr/bin/env bash
set -euo pipefail

# Idempotent installer for node_exporter on server1 (non-Swarm)
# Usage: sudo ./install-node-exporter.sh

TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
ETC_DEFAULT_TARGET="/etc/default/prometheus-node-exporter"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

echo "[1/4] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y prometheus-node-exporter prometheus-node-exporter-collectors

echo "[2/4] Ensuring textfile collector directory exists..."
mkdir -p "$TEXTFILE_DIR"
chown -R node-exp*:* "$TEXTFILE_DIR" 2>/dev/null || true
# fallback if user/group names differ on the distro
chown -R prometheus-node-exporter:prometheus-node-exporter "$TEXTFILE_DIR" 2>/dev/null || true
chmod 755 "$TEXTFILE_DIR"

echo "[3/4] Writing /etc/default/prometheus-node-exporter (ARGS flags)..."
# Keep a backup if file exists and differs
if [ -f "$ETC_DEFAULT_TARGET" ] && ! grep -q 'collector.textfile.directory' "$ETC_DEFAULT_TARGET"; then
  cp -a "$ETC_DEFAULT_TARGET" "${ETC_DEFAULT_TARGET}.bak.$(date +%s)"
fi
install -o root -g root -m 0644 "$TEMPLATE_DIR/etc-default" "$ETC_DEFAULT_TARGET"

echo "[4/4] Enabling & restarting service..."
systemctl daemon-reload
systemctl enable --now prometheus-node-exporter
systemctl restart prometheus-node-exporter

echo
echo "=== Verification ==="
systemctl --no-pager --full status prometheus-node-exporter | sed -n '1,8p'
ss -lntp | awk '$4 ~ /:9100$/ {print}'
echo "curl http://localhost:9100/metrics | head"
curl -s http://localhost:9100/metrics | head || true

echo
echo "Done. Prometheus should scrape server1:9100."
