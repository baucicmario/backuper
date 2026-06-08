#!/usr/bin/env bash
# lib/common.sh — Common utilities and helper functions
# Provides logging functions, package manager detection, Docker utilities,
# and environment variable loading for all scripts.
set -euo pipefail

# ── Color codes for terminal output ────────────────────────────────────────
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[36m"
BOLD="\e[1m"; RESET="\e[0m"

# ── Logging functions (use these for all output) ──────────────────────────
line()  { echo -e "${BLUE}------------------------------------------------------------${RESET}"; }
info()  { echo -e "${BLUE}$*${RESET}"; }  # Blue informational message
ok()    { echo -e "${GREEN}✅ $*${RESET}"; }  # Green success message
warn()  { echo -e "${YELLOW}⚠️  $*${RESET}"; }  # Yellow warning message
error() { echo -e "${RED}❌ $*${RESET}" >&2; }  # Red error message to stderr
die()   { error "$*"; exit 1; }  # Print error and exit with status 1
bold()  { echo -e "${BOLD}$*${RESET}"; }  # Bold text (no color)

CENTRAL_BACKUP_DIR="${CENTRAL_BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups}"
export CENTRAL_BACKUP_DIR

# ── Privilege escalation check ─────────────────────────────────────────────
# Sets $SUDO to 'sudo' if not running as root, dies if sudo isn't available
require_sudo() {
  SUDO=""
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "This script needs root or sudo access."
    SUDO=sudo
  fi
}

# ── Package manager detection ──────────────────────────────────────────────
# Finds and sets $PKG_MANAGER to the first available manager (apt, dnf, yum, etc.)
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

# ── Cross-distro package installation ──────────────────────────────────────
# Installs packages using the detected package manager
pkg_install() {
  case "$PKG_MANAGER" in
    apt)    $SUDO apt-get install -y "$@" ;;  # Debian/Ubuntu
    dnf)    $SUDO dnf install -y "$@" ;;  # Fedora
    yum)    $SUDO yum install -y "$@" ;;  # RHEL/CentOS
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;  # Arch
    apk)    $SUDO apk add --no-cache "$@" ;;  # Alpine
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

# ── Ensure a command is available, install if needed ────────────────────────
# Usage: ensure_cmd <command_name> <package_to_install> [more_packages...]
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

# ── Require a command to exist, die if not found ────────────────────────────
# Used by later phases to ensure dependencies from phase-0 are installed
require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found. Run phase-0 first to install dependencies."
}

# ── Load environment variables from a .env file ────────────────────────────
# set -a/set +a ensures all variables are exported
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

# ── Sanitize a string for use as a directory/file name ───────────────────────
# Replaces slashes and special characters with underscores
sanitize_dirname() {
  local raw="$1"
  printf '%s' "$raw" | tr '/' '_' | sed 's/[^A-Za-z0-9._-]/_/g'
}