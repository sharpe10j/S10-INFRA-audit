#!/usr/bin/env bash
# validation/install/ensure_venv.sh
# Create/refresh the validation virtualenv and install dependencies.
# Usage:
#   ./ensure_venv.sh                   # uses requirements.txt (minimal)
#   ./ensure_venv.sh --use-lock        # uses requirements.lock (exact snapshot)
#   ./ensure_venv.sh --python /usr/bin/python3
#   ./ensure_venv.sh --venv-path /opt/sharpe10/validation-venv
set -euo pipefail

# -------- args --------
USE_LOCK=0
PYTHON_BIN="${PYTHON_BIN:-}"
VENV_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --use-lock)   USE_LOCK=1; shift ;;
    --python)     PYTHON_BIN="$2"; shift 2 ;;
    --venv-path)  VENV_PATH="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# -------- paths --------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${VENV_PATH:=${REPO_ROOT}/validation/.venv}"
REQ_TXT="${REPO_ROOT}/validation/requirements.txt"
REQ_LOCK="${REPO_ROOT}/validation/requirements.lock"
REQ="$REQ_TXT"
if [[ $USE_LOCK -eq 1 && -f "$REQ_LOCK" ]]; then REQ="$REQ_LOCK"; fi

# -------- python/venv --------
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN="$(command -v python3)"
  elif command -v python  >/dev/null 2>&1; then PYTHON_BIN="$(command -v python)"
  else echo "ERROR: python3 not found in PATH." >&2; exit 1
  fi
fi

if [[ ! -d "$VENV_PATH" ]]; then
  echo "Creating venv at: $VENV_PATH"
  if ! "$PYTHON_BIN" -m venv "$VENV_PATH"; then
    echo "Failed to create venv. On Debian/Ubuntu run: sudo apt-get install -y python3-venv" >&2
    exit 1
  fi
else
  echo "Using existing venv: $VENV_PATH"
fi

# -------- install deps --------
echo "Using requirements file: $REQ"
"$VENV_PATH/bin/python" -m pip install --upgrade pip wheel setuptools
"$VENV_PATH/bin/python" -m pip install -r "$REQ"

echo "Venv ready."
"$VENV_PATH/bin/python" -V
echo "Top installed packages:"
"$VENV_PATH/bin/python" -m pip freeze | sed -n '1,20p'
