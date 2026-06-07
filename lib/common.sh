#!/usr/bin/env bash
set -euo pipefail

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[36m"
BOLD="\e[1m"; RESET="\e[0m"

line()  { echo -e "${BLUE}------------------------------------------------------------${RESET}"; }
info()  { echo -e "${BLUE}$*${RESET}"; }
ok()    { echo -e "${GREEN}✅ $*${RESET}"; }
warn()  { echo -e "${YELLOW}⚠️  $*${RESET}"; }
error() { echo -e "${RED}❌ $*${RESET}" >&2; }
die()   { error "$*"; exit 1; }
bold()  { echo -e "${BOLD}$*${RESET}"; }

CENTRAL_BACKUP_DIR="${CENTRAL_BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups}"
export CENTRAL_BACKUP_DIR

require_sudo() {
  SUDO=""
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "This script needs root or sudo access."
    SUDO=sudo
  fi
}

detect_pkg_manager() {
  for pm in apt dnf yum pacman apk; do
    if command -v "$pm" >/dev/null 2>&1; then
      PKG_MANAGER="$pm"
      info "Detected package manager: ${YELLOW}${PKG_MANAGER}${RESET}"
      return 0
    fi
  done
  die "No supported package manager found (apt/dnf/yum/pacman/apk)."
}

pkg_install() {
  case "$PKG_MANAGER" in
    apt)    $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    *) die "pkg_install: unknown PKG_MANAGER '$PKG_MANAGER'" ;;
  esac
}

_APT_UPDATED=false
apt_update_once() {
  [ "${PKG_MANAGER:-}" = apt ] || return 0
  if [ "$_APT_UPDATED" = false ]; then
    info "Updating apt package lists..."
    $SUDO apt-get update -y
    _APT_UPDATED=true
  fi
}

ensure_cmd() {
  local cmd="$1"; shift
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd already available"
    return 0
  fi
  warn "$cmd missing — installing: $*"
  [ "${PKG_MANAGER:-}" = apt ] && apt_update_once
  pkg_install "$@"
  command -v "$cmd" >/dev/null 2>&1 && ok "Installed: $cmd" || warn "Could not install $cmd."
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found. Run phase-0 first to install dependencies."
}

load_env() {
  local env_file="${1:-./.env}"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    info "Loaded env: $env_file"
  else
    warn "No .env file found at $env_file — continuing without it."
  fi
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose plugin available"
    return 0
  fi
  warn "Docker Compose plugin missing — attempting install"
  case "${PKG_MANAGER:-}" in
    apt)
      apt_update_once
      $SUDO apt-get install -y docker-compose-plugin || warn "Could not install docker-compose-plugin via apt."
      ;;
    *)
      warn "Install the Docker Compose plugin for your distro manually."
      ;;
  esac
}

run_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v sg >/dev/null 2>&1; then
    sg docker -c "docker compose $*"
  else
    $SUDO docker compose "$@"
  fi
}

sanitize_dirname() {
  local raw="$1"
  printf '%s' "$raw" | tr '/' '_' | sed 's/[^A-Za-z0-9._-]/_/g'
}