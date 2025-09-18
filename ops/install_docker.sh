#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }

# --- Pins (read from env). Use SEMVER like 28.1.1, 1.7.27, 2.38.1, 0.25.0 ---
DOCKER_SEMVER="${DOCKER_SEMVER:-}"          # e.g. 28.1.1
CONTAINERD_SEMVER="${CONTAINERD_SEMVER:-}"  # e.g. 1.7.27
COMPOSE_SEMVER="${COMPOSE_SEMVER:-}"        # e.g. 2.38.1  (plugin)
BUILDX_SEMVER="${BUILDX_SEMVER:-}"          # e.g. 0.25.0
APT_HOLD_DOCKER="${APT_HOLD_DOCKER:-1}"     # 1=apt-mark hold after install

# --- Ensure Docker apt repo exists for the current Ubuntu codename (noble) ---
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
fi

apt-get update -y

# --- Remove legacy docker-compose v1 if present (we use the v2 plugin) ---
apt-get remove -y docker-compose || true

# --- Helper: resolve an apt version string that matches the SEMVER you want ---
resolve_ver() {
  # usage: resolve_ver <pkg> <semver>
  local pkg="$1" needle="$2"
  [[ -z "$needle" ]] && { echo ""; return; }
  # Pick the first candidate whose version contains the semver (works across codenames)
  apt-cache madison "$pkg" | awk -v n="$needle" '$3 ~ n {print $3; exit}'
}

# Resolve apt versions from the semvers (lets you keep a single set of pins)
DOCKER_CE_VERSION="$(resolve_ver docker-ce "$DOCKER_SEMVER")"
DOCKER_CLI_VERSION="$(resolve_ver docker-ce-cli "$DOCKER_SEMVER")"
CONTAINERD_VERSION="$(resolve_ver containerd.io "$CONTAINERD_SEMVER")"
DOCKER_COMPOSE_PLUGIN_VERSION="$(resolve_ver docker-compose-plugin "$COMPOSE_SEMVER")"
DOCKER_BUILDX_PLUGIN_VERSION="$(resolve_ver docker-buildx-plugin "$BUILDX_SEMVER")"

# Sanity: require at least the engine pins; plugins are optional
if [[ -z "$DOCKER_CE_VERSION" || -z "$DOCKER_CLI_VERSION" ]]; then
  echo "Could not resolve docker-ce/docker-ce-cli for DOCKER_SEMVER='${DOCKER_SEMVER}'"
  echo "Check: apt-cache madison docker-ce | head -n 20"
  exit 2
fi
if [[ -z "$CONTAINERD_VERSION" ]]; then
  echo "Could not resolve containerd.io for CONTAINERD_SEMVER='${CONTAINERD_SEMVER}'"
  echo "Check: apt-cache madison containerd.io | head -n 20"
  exit 2
fi

# --- Install exact versions (allow downgrades for normalization) ---
PKGS=(
  "docker-ce=${DOCKER_CE_VERSION}"
  "docker-ce-cli=${DOCKER_CLI_VERSION}"
  "containerd.io=${CONTAINERD_VERSION}"
)
[[ -n "$DOCKER_COMPOSE_PLUGIN_VERSION" ]] && PKGS+=("docker-compose-plugin=${DOCKER_COMPOSE_PLUGIN_VERSION}")
[[ -n "$DOCKER_BUILDX_PLUGIN_VERSION"  ]] && PKGS+=("docker-buildx-plugin=${DOCKER_BUILDX_PLUGIN_VERSION}")

apt-get install -y --allow-downgrades "${PKGS[@]}"

# --- Minimal daemon config (log rotation); keep if already present ---
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat >/etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
JSON
fi

systemctl enable docker --now

# Add your user to the docker group (safe if already in group)
usermod -aG docker jake_morrison || true

# --- Hold packages to prevent drift ---
if [[ "$APT_HOLD_DOCKER" == "1" ]]; then
  apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin 2>/dev/null || true
fi

echo "[docker] installed. Versions:"
docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' || true
docker compose version || true
docker buildx version || true
containerd --version || true
