#!/usr/bin/env bash
set -euo pipefail
apt-get install -y python3 python3-pip python3-venv
python3 -m pip install --upgrade pip setuptools wheel
echo "[python] installed"
