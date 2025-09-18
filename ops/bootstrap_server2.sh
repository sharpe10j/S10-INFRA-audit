#!/usr/bin/env bash
set -euo pipefail
make seed ROLE=server2
# sudo ./bootstrap_server.sh
make swarm-init || true
make deploy-monitor || true
make deploy-kafka || true
make smoke ENV_NAME=dev ROLE=server2 SMOKE_MODE=live
