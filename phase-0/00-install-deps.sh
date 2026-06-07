#!/usr/bin/env bash
set -euo pipefail

# Consolidated dependency installer for this workspace
# Installs/common-checks for Debian/Ubuntu systems (apt). Docker is excluded.

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[36m"; RESET="\e[0m"; BOLD="\e[1m"
line() { echo -e "${BLUE}------------------------------------------------------------${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${BOLD}${GREEN}🔧 System Dependency Installer${RESET}"
line

# Require sudo when not root
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
  else
    echo -e "${RED}This script needs root (or sudo) to install packages.${RESET}"
    exit 1
  fi
fi

# Detect package manager (prefer apt)
PKG_MANAGER=""
if command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v apk >/dev/null 2>&1; then
  PKG_MANAGER="apk"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
elif command -v pacman >/dev/null 2>&1; then
  PKG_MANAGER="pacman"
else
  echo -e "${YELLOW}Unsupported package manager. Please install dependencies manually.${RESET}"
  exit 1
fi

echo -e "Detected package manager: ${YELLOW}${PKG_MANAGER}${RESET}"
line

install_apt() {
  echo -e "${BLUE}Updating apt lists...${RESET}"
  $SUDO apt update -y
  echo -e "${BLUE}Installing: $*${RESET}"
  $SUDO apt install -y "$@"
}

install_dnf() { $SUDO dnf install -y "$@"; }
install_yum() { $SUDO yum install -y "$@"; }
install_pacman() { $SUDO pacman -Sy --noconfirm "$@"; }
install_apk() { $SUDO apk add --no-cache "$@"; }

ensure_command() {
  cmd="$1"; shift
  pkgs=("$@")

  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${GREEN}✔ $cmd already available${RESET}"
    return 0
  fi

  echo -e "${YELLOW}⚠ $cmd missing — installing...${RESET}"
  case "$PKG_MANAGER" in
    apt) install_apt "${pkgs[@]}" ;;
    dnf) install_dnf "${pkgs[@]}" ;;
    yum) install_yum "${pkgs[@]}" ;;
    pacman) install_pacman "${pkgs[@]}" ;;
    apk) install_apk "${pkgs[@]}" ;;
  esac

  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Installed: $cmd${RESET}"
  else
    echo -e "${RED}❌ Failed to install $cmd — please install it manually.${RESET}"
  fi
}

# --- Basic utilities used across the scripts ---
ensure_command curl curl
ensure_command wget wget
ensure_command jq jq
ensure_command whiptail whiptail

# yq: prefer existing global, otherwise attempt to run local installer if present
if command -v yq >/dev/null 2>&1; then
  echo -e "${GREEN}✔ yq already installed${RESET}"
else
  if [ -x "${SCRIPT_DIR}/01-install_yq_global.sh" ]; then
    echo -e "${BLUE}⬇️  Running bundled yq installer: 01-install_yq_global.sh${RESET}"
    $SUDO bash "${SCRIPT_DIR}/01-install_yq_global.sh"
  else
    echo -e "${YELLOW}⚠ yq not found and installer not present. You can run 'phase 0/01-install_yq_global.sh' manually.${RESET}"
  fi
fi

# docker compose plugin (not docker itself)
if docker compose version >/dev/null 2>&1; then
  echo -e "${GREEN}✔ Docker Compose plugin available${RESET}"
else
  echo -e "${YELLOW}⚠ Docker Compose plugin missing — attempting installation${RESET}"
  case "$PKG_MANAGER" in
    apt)
      $SUDO apt update -y
      $SUDO apt install -y docker-compose-plugin || echo -e "${YELLOW}Could not install docker-compose-plugin via apt. You may need to install it manually or ensure Docker is set up.${RESET}"
      ;;
    dnf|yum)
      echo -e "${YELLOW}Please install the Docker Compose plugin for your distribution (dnf/yum).${RESET}"
      ;;
    pacman)
      echo -e "${YELLOW}Please install 'docker-compose' or the plugin via pacman.${RESET}"
      ;;
    apk)
      echo -e "${YELLOW}Please install 'docker-compose' or the plugin via apk.${RESET}"
      ;;
  esac
fi

line
echo -e "${BOLD}Summary:${RESET}"
echo -e "- curl: $(command -v curl >/dev/null 2>&1 && echo "installed" || echo "missing")"
echo -e "- wget: $(command -v wget >/dev/null 2>&1 && echo "installed" || echo "missing")"
echo -e "- jq: $(command -v jq >/dev/null 2>&1 && echo "installed" || echo "missing")"
echo -e "- whiptail: $(command -v whiptail >/dev/null 2>&1 && echo "installed" || echo "missing")"
echo -e "- yq: $(command -v yq >/dev/null 2>&1 && echo "installed" || echo "missing (see phase 0/01-install_yq_global.sh)")"
echo -e "- docker-compose plugin: $(docker compose version >/dev/null 2>&1 && echo "available" || echo "missing")"
line

echo -e "${GREEN}All checks complete.${RESET}"
