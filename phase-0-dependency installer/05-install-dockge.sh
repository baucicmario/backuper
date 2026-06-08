#!/usr/bin/env bash
# phase-0/05-install-dockge.sh
# Installs and starts Dockge via Docker Compose.
# Falls back to sudo for docker socket access if the docker group
# isn't active yet in the current session (common right after install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

bold "${GREEN}🐳 Dockge Installer${RESET}"
line

require_sudo

# ── Pre-flight: Docker must exist ─────────────────
command -v docker >/dev/null 2>&1 \
  || die "Docker not found. Run 04-install-docker.sh first."
docker compose version >/dev/null 2>&1 \
  || die "Docker Compose plugin not found. Run 04-install-docker.sh first."
ok "Docker and Compose plugin available."
line

# ── Setup /opt/dockge ─────────────────────────────
DOCKGE_DIR="/opt/dockge"
info "Setting up $DOCKGE_DIR..."
$SUDO mkdir -p "$DOCKGE_DIR"
$SUDO chown "$USER":"$USER" "$DOCKGE_DIR"

# ── Download compose.yaml ─────────────────────────
info "Downloading Dockge compose.yaml..."
curl -fsSL https://raw.githubusercontent.com/louislam/dockge/master/compose.yaml \
  -o "$DOCKGE_DIR/compose.yaml"
line

# ── Start Dockge ──────────────────────────────────
# The docker group may not be active yet in this session (just added by 04).
# Try without sudo first; fall back to sudo if the socket is not accessible.
info "Starting Dockge..."

_compose_up() {
  docker compose -f "$DOCKGE_DIR/compose.yaml" up -d
}

_compose_up_sudo() {
  warn "docker socket not accessible without sudo — trying with sudo..."
  warn "This is normal right after a fresh Docker install. Log out and back in to use docker without sudo."
  $SUDO docker compose -f "$DOCKGE_DIR/compose.yaml" up -d
}

if ! _compose_up 2>/dev/null; then
  _compose_up_sudo || die "Failed to start Dockge even with sudo."
fi

line

# ── Done ──────────────────────────────────────────
IP_ADDR="$(hostname -I | awk '{print $1}')"
ok "Dockge installed and running!"
echo -e "💡 Access at: ${YELLOW}http://${IP_ADDR}:5001${RESET}"
echo -e "💡 Manage:    docker compose -f ${DOCKGE_DIR}/compose.yaml"
line