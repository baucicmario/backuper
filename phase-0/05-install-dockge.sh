#!/usr/bin/env bash
# phase-0/05-install-dockge.sh
# Installs Dockge (Docker Compose stack manager UI).
# Prerequisite: Docker + Compose plugin must already be installed (run 04 first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DOCKGE_DIR="/opt/dockge"
DOCKGE_PORT=5001
COMPOSE_URL="https://raw.githubusercontent.com/louislam/dockge/master/compose.yaml"

bold "${GREEN}🐳 Dockge Installer${RESET}"
line

require_sudo

# ── Pre-flight checks ─────────────────────
require_cmd docker
require_cmd curl

docker compose version >/dev/null 2>&1 \
  || die "Docker Compose plugin not found. Run phase-0/04-install-docker.sh first."
ok "Docker and Compose plugin available."
line

# ── Create Dockge directory ───────────────
info "Setting up $DOCKGE_DIR..."
$SUDO mkdir -p "$DOCKGE_DIR"
$SUDO chown "${USER}:${USER}" "$DOCKGE_DIR"

# ── Download compose file ─────────────────
info "Downloading Dockge compose.yaml..."
curl -fsSL "$COMPOSE_URL" -o "$DOCKGE_DIR/compose.yaml"
line

# ── Start Dockge ──────────────────────────
info "Starting Dockge..."
run_docker_compose -f "$DOCKGE_DIR/compose.yaml" up -d
line

# ── Done ──────────────────────────────────
IP="$(hostname -I | awk '{print $1}')"
ok "Dockge installed and running!"
echo -e "💡 Access at: ${YELLOW}http://${IP}:${DOCKGE_PORT}${RESET}"
echo -e "💡 Manage:    ${YELLOW}docker compose -f $DOCKGE_DIR/compose.yaml${RESET}"
line