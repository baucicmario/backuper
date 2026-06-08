#!/usr/bin/env bash
# phase-0/00-install-deps.sh
# Installs common system dependencies needed by subsequent scripts.
# Does NOT install Docker (handled by 04-install-docker.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

bold "${GREEN}🔧 System Dependency Installer${RESET}"
line

require_sudo
detect_pkg_manager

# ── Core utilities ────────────────────────
ensure_cmd curl    curl
ensure_cmd wget    wget
ensure_cmd jq      jq
ensure_cmd whiptail whiptail

# ── yq ────────────────────────────────────
if command -v yq >/dev/null 2>&1; then
  ok "yq already installed ($(yq --version))"
else
  YQ_INSTALLER="$SCRIPT_DIR/01-install-yq.sh"
  if [ -x "$YQ_INSTALLER" ]; then
    info "Running bundled yq installer..."
    bash "$YQ_INSTALLER"
  else
    warn "yq not found and installer not present. Run phase-0/01-install-yq.sh manually."
  fi
fi

# ── Docker Compose plugin ─────────────────
ensure_docker_compose

line
bold "Summary:"
for tool in curl wget jq whiptail yq; do
  command -v "$tool" >/dev/null 2>&1 \
    && echo -e "  ${GREEN}✔ $tool${RESET}" \
    || echo -e "  ${RED}✖ $tool${RESET}"
done
docker compose version >/dev/null 2>&1 \
  && echo -e "  ${GREEN}✔ docker compose plugin${RESET}" \
  || echo -e "  ${RED}✖ docker compose plugin${RESET}"
line
ok "All checks complete."