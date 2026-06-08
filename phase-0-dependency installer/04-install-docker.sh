#!/usr/bin/env bash
# phase-0/04-install-docker.sh
# Installs Docker Engine + Compose plugin, adds current user to docker group.
# Skips the installer entirely if Docker is already present (avoids the 40s wait).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

bold "${GREEN}🐳 Docker Installer & Setup${RESET}"
line

require_sudo
detect_pkg_manager
ensure_cmd curl curl

CURRENT_USER="$(id -un)"

# ── Group membership helper (used in both paths) ──
ensure_docker_group() {
  if groups "$CURRENT_USER" | grep -qw docker; then
    ok "User '$CURRENT_USER' is already in the docker group."
  else
    info "Adding '$CURRENT_USER' to docker group..."
    $SUDO usermod -aG docker "$CURRENT_USER"
    ok "Added '$CURRENT_USER' to docker group."
    warn "Log out and back in (or run 'newgrp docker') for group membership to take effect."
  fi
}

# ── Skip installer if Docker is already present ───
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker and Compose plugin already installed — skipping installer."
  ensure_docker_group
  line
  ok "Docker setup complete."
  exit 0
fi

# ── Download + run Docker install script ──────────
info "Downloading Docker install script..."
TMP_DOCKER="$(mktemp /tmp/get-docker-XXXX.sh)"
trap 'rm -f "$TMP_DOCKER"' EXIT

curl -fsSL https://get.docker.com -o "$TMP_DOCKER"

info "Running Docker installer..."
$SUDO sh "$TMP_DOCKER"
line

# ── Group + Compose ───────────────────────────────
ensure_docker_group
line
ensure_docker_compose
line

# ── Verify ────────────────────────────────────────
info "Verifying Docker..."
if docker_ver="$(docker --version 2>/dev/null)"; then
  ok "Docker installed: $docker_ver"
else
  die "Docker installation appears to have failed."
fi
line
ok "Docker setup complete."