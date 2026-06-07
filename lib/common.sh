#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by every phase-0 script
# Source with: source "$(dirname "$0")/../lib/common.sh"

# ── Colors ────────────────────────────────
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[36m"
BOLD="\e[1m"; RESET="\e[0m"

line()  { echo -e "${BLUE}------------------------------------------------------------${RESET}"; }
info()  { echo -e "${BLUE}$*${RESET}"; }
ok()    { echo -e "${GREEN}✅ $*${RESET}"; }
warn()  { echo -e "${YELLOW}⚠️  $*${RESET}"; }
error() { echo -e "${RED}❌ $*${RESET}" >&2; }
die()   { error "$*"; exit 1; }
bold()  { echo -e "${BOLD}$*${RESET}"; }

# ── Privilege helper ──────────────────────
# Sets global $SUDO to "" (root) or "sudo", or exits.
require_sudo() {
  SUDO=""
  if [ "$EUID" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 \
      || die "This script needs root or sudo access."
    SUDO=sudo
  fi
}

# ── Package manager detection ─────────────
# Sets global $PKG_MANAGER or exits.
detect_pkg_manager() {
  for pm in apt dnf yum pacman apk; do
    if command -v "$pm" >/dev/null 2>&1; then
      PKG_MANAGER="$pm"
      info "Detected package manager: ${YELLOW}${PKG_MANAGER}${RESET}"
      return 0
    fi
  done
  die "No supported package manager found (apt/dnf/yum/pacman/apk). Install dependencies manually."
}

# ── Generic package install ───────────────
# Usage: pkg_install <pkg> [pkg...]
pkg_install() {
  case "$PKG_MANAGER" in
    apt)    $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    *)      die "pkg_install: unknown PKG_MANAGER '$PKG_MANAGER'" ;;
  esac
}

# ── apt list update (once per session) ────
_APT_UPDATED=false
apt_update_once() {
  [ "$PKG_MANAGER" = "apt" ] || return 0
  if [ "$_APT_UPDATED" = false ]; then
    info "Updating apt package lists..."
    $SUDO apt-get update -y
    _APT_UPDATED=true
  fi
}

# ── Ensure a command is present ───────────
# Usage: ensure_cmd <cmd> <pkg> [<pkg>...]
# Installs pkg(s) if cmd is missing.
ensure_cmd() {
  local cmd="$1"; shift
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd already available"
    return 0
  fi
  warn "$cmd missing — installing: $*"
  [ "$PKG_MANAGER" = "apt" ] && apt_update_once
  pkg_install "$@"
  command -v "$cmd" >/dev/null 2>&1 \
    && ok "Installed: $cmd" \
    || warn "Could not install $cmd — please install it manually."
}

# ── Docker Compose availability check ─────
ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose plugin available"
    return 0
  fi
  warn "Docker Compose plugin missing — attempting install"
  case "$PKG_MANAGER" in
    apt)
      apt_update_once
      $SUDO apt-get install -y docker-compose-plugin \
        || warn "Could not install docker-compose-plugin via apt."
      ;;
    *)
      warn "Install the Docker Compose plugin for your distro ($PKG_MANAGER) manually."
      ;;
  esac
}