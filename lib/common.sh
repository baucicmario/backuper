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

# ── Human-readable file size ─────────────────────────────────────────────────
# Usage: fmt_size <bytes>
fmt_size() {
  local bytes="$1"
  if   (( bytes < 1024 ));        then printf '%dB'    "$bytes"
  elif (( bytes < 1048576 ));     then printf '%.1fKB' "$(echo "$bytes / 1024" | bc -l)"
  elif (( bytes < 1073741824 ));  then printf '%.1fMB' "$(echo "$bytes / 1048576" | bc -l)"
  else                                 printf '%.2fGB' "$(echo "$bytes / 1073741824" | bc -l)"
  fi
}

# ── Yes/No confirmation prompt ───────────────────────────────────────────────
# Usage: confirm_prompt "Do you want to continue?"  →  returns 0 (yes) or 1 (no)
confirm_prompt() {
  local prompt="${1:-Continue?}"
  local answer
  printf '%s [y/N] ' "$prompt"
  read -r answer </dev/tty
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# ── Extract tar.gz with progress bar ─────────────────────────────────────────
# Uses pv for visual progress when available, falls back to plain tar.
# Usage: extract_with_progress <archive_path> <destination_dir> [label]
extract_with_progress() {
  local archive="$1"
  local dest="$2"
  local label="${3:-$(basename "$archive")}"
  local size

  size="$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo 0)"
  mkdir -p "$dest"

  info "  Extracting: $label  ($(fmt_size "$size"))"

  if command -v pv >/dev/null 2>&1; then
    pv -f -N "$label" -s "$size" "$archive" | tar -xzf - -C "$dest"
  else
    warn "  (pv not available — extracting without progress bar)"
    tar -xzf "$archive" -C "$dest"
  fi
}

# ── Smart work directory selection ───────────────────────────────────────────
# Picks /tmp by default; falls back to the largest mounted filesystem if /tmp
# doesn't have enough free space for the given minimum (in MB, default 500).
# Usage: choose_work_dir [min_mb]
# Prints the chosen base directory to stdout.
choose_work_dir() {
  local min_mb="${1:-500}"
  local min_kb=$(( min_mb * 1024 ))

  # Try /tmp first
  local tmp_avail
  tmp_avail="$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$tmp_avail" ]] && (( tmp_avail >= min_kb )); then
    echo "/tmp"
    return 0
  fi

  warn "/tmp has insufficient space (need ${min_mb}MB) — searching for alternative..."

  # Find the mount with the most available space
  local best_mount=""
  local best_avail=0
  while IFS= read -r mount_line; do
    local avail mount
    avail="$(echo "$mount_line" | awk '{print $4}')"
    mount="$(echo "$mount_line" | awk '{print $6}')"
    # Skip pseudo-filesystems
    [[ "$mount" == /dev* || "$mount" == /proc* || "$mount" == /sys* || "$mount" == /run* ]] && continue
    if (( avail > best_avail )); then
      best_avail="$avail"
      best_mount="$mount"
    fi
  done < <(df -k 2>/dev/null | tail -n +2)

  if [[ -n "$best_mount" ]] && (( best_avail >= min_kb )); then
    info "Using $best_mount ($(fmt_size $(( best_avail * 1024 ))) free)"
    echo "$best_mount"
    return 0
  fi

  # Last resort: use /tmp anyway and hope for the best
  warn "No filesystem with ${min_mb}MB free found — using /tmp anyway"
  echo "/tmp"
}

# ── Ensure restore dependencies are installed ────────────────────────────────
# Auto-installs pv and whiptail if missing, using the project's setup helpers.
ensure_restore_deps() {
  local missing=()

  command -v pv       >/dev/null 2>&1 || missing+=(pv)
  command -v whiptail >/dev/null 2>&1 || missing+=(whiptail)

  [[ ${#missing[@]} -eq 0 ]] && return 0

  warn "Missing restore dependencies: ${missing[*]}"
  info "Attempting to install automatically..."

  require_sudo
  detect_pkg_manager

  for dep in "${missing[@]}"; do
    ensure_cmd "$dep" "$dep"
  done

  # Verify
  local still_missing=()
  command -v pv       >/dev/null 2>&1 || still_missing+=(pv)
  command -v whiptail >/dev/null 2>&1 || still_missing+=(whiptail)

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    warn "Could not install: ${still_missing[*]} — some features may be degraded"
  else
    ok "All restore dependencies installed"
  fi
}

# ── Detect if an archive is a bundle ─────────────────────────────────────────
# Usage: is_archive_bundle <archive_path>  → returns 0 (true) if bundle, 1 (false) otherwise
is_archive_bundle() {
  local file="$1"
  local top_level_tarballs=0
  local distinct_top_levels=0

  while IFS= read -r entry; do
    local top="$(echo "$entry" | cut -d'/' -f1)"
    if [[ "$entry" =~ \.tar\.gz$ ]] && [[ "$entry" == "$top" || "$entry" == "$top/" ]]; then
      (( top_level_tarballs++ )) || true
    fi
  done < <(tar -tzf "$file" 2>/dev/null | head -100)

  distinct_top_levels="$(tar -tzf "$file" 2>/dev/null | cut -d'/' -f1 | sort -u | wc -l)"

  if (( top_level_tarballs >= 2 )); then
    return 0
  elif (( distinct_top_levels > 1 )); then
    local tarball_count="$(tar -tzf "$file" 2>/dev/null | grep -cE '^[^/]+\.tar\.gz$' || echo 0)"
    if (( tarball_count >= 2 )); then
      return 0
    fi
  fi
  return 1
}