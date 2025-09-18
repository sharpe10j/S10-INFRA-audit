#!/usr/bin/env bash
set -euo pipefail

# ---------------- args ----------------
ENV_FILE="/etc/sharpe10/dev.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) shift ;;  # ignore unknown args (keeps script tolerant)
  esac
done

# ---------------- env loading ----------------
set -a
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"
[[ -f /etc/sharpe10/dev.secrets ]] && . /etc/sharpe10/dev.secrets
[[ -f /etc/sharpe10/dev.local   ]] && . /etc/sharpe10/dev.local
set +a

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Optionally only prep on a specific host (default: SERVER2_HOST if set)
INSTALL_HOST="${VALIDATION_INSTALL_HOST:-${SERVER2_HOST:-}}"
THIS_HOST="$(hostname -s 2>/dev/null || true)"
if [[ -n "$INSTALL_HOST" && "$THIS_HOST" != "$INSTALL_HOST" ]]; then
  echo "Skipping validation setup (this is ${THIS_HOST}, not ${INSTALL_HOST})."
  exit 0
fi

# ---------------- ensure venv ----------------
if [[ "${VALIDATION_USE_LOCK:-0}" == "1" ]]; then
  "${REPO_ROOT}/validation/install/ensure_venv.sh" --use-lock
else
  "${REPO_ROOT}/validation/install/ensure_venv.sh"
fi

# ---------------- install wrapper ----------------
WRAPPER_SRC="${REPO_ROOT}/validation/scripts/validator_batched.sh"
WRAPPER_DST="/usr/local/bin/validate-batched"
SUDO_CMD=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then SUDO_CMD="sudo"; fi
$SUDO_CMD install -m 0755 "$WRAPPER_SRC" "$WRAPPER_DST"

echo "Validation ready on ${THIS_HOST:-unknown}."
echo "Run examples:"
echo "  validate-batched 'YYYY-MM-DD HH:MM:SS'   # UTC timestamp"
echo "  validate-batched 1737062400000           # epoch ms"
