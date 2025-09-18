#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release git jq unzip tar chrony
timedatectl set-ntp true || true
echo "[preflight] ok"
