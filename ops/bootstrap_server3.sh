#!/usr/bin/env bash
set -euo pipefail
make seed ROLE=server3
# sudo ./bootstrap_server.sh
make smoke ENV_NAME=dev ROLE=server3 SMOKE_MODE=live
