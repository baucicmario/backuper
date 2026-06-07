#!/usr/bin/env bash
# phase-0/04-install-docker.sh
# Installs Docker Engine + Compose plugin, adds current user to docker group.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

bold "${GREEN}🐳 Docker Installer & Setup${RESET}"
line

require_sudo
detect_pkg_manager
ensure_cmd curl curl

CURRENT_USER="$(id -un)"

# ── Download Docker install script ────────
info "Downloading Docker install script..."
TMP_DOCKER="$(mktemp /tmp/get-docker-XXXX.sh)"
trap 'rm -f "$TMP_DOCKER"' EXIT

curl -fsSL https://get.docker.com -o "$TMP_DOCKER"

# ── Run Docker installer ──────────────────
info "Running Docker installer..."
$SUDO sh "$TMP_DOCKER"
line

# ── Add user to docker group ──────────────
if groups "$CURRENT_USER" | grep -qw docker; then
  ok "User '$CURRENT_USER' is already in the docker group."
else
  info "Adding '$CURRENT_USER' to docker group..."
  $SUDO usermod -aG docker "$CURRENT_USER"
  ok "Added '$CURRENT_USER' to docker group."
  warn "Log out and back in (or run 'newgrp docker') for group membership to take effect."
fi
line

# ── Docker Compose plugin ─────────────────
ensure_docker_compose
line

# ── Verify installation ───────────────────
info "Verifying Docker..."
if docker_ver="$(docker --version 2>/dev/null)"; then
  ok "Docker installed: $docker_ver"
  info "Running hello-world test..."
  if command -v sg >/dev/null 2>&1; then
    sg docker -c "docker run --rm hello-world" || warn "hello-world test failed — try after re-login."
  else
    $SUDO docker run --rm hello-world || warn "hello-world test failed."
  fi
else
  die "Docker installation appears to have failed."
fi
line
ok "Docker setup complete."