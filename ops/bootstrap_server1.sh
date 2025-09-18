#!/usr/bin/env bash
set -euo pipefail
make seed ROLE=server1
# If you have a real bootstrap script, call it here:
# sudo ./bootstrap_server.sh
make smoke ENV_NAME=dev ROLE=server1 SMOKE_MODE=live
