#!/bin/bash
# =============================================================
# 🧩 Cockpit Suite Module Selector
# =============================================================

set -e
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[36m"; RESET="\e[0m"; BOLD="\e[1m"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 🧠 Ensure whiptail
if ! command -v whiptail >/dev/null 2>&1; then
  echo -e "${YELLOW}⚙️ Installing 'whiptail'...${RESET}"
  sudo apt update -y && sudo apt install -y whiptail
fi

# Helper to check installed packages
is_installed() { dpkg -l "$1" &>/dev/null && echo "ON" || echo "OFF"; }

# Define options
OPTIONS=(
  "cockpit-networkmanager" "Network management" $(is_installed cockpit-networkmanager)
  "cockpit-packagekit" "GUI updates" $(is_installed cockpit-packagekit)
  "cockpit-storaged" "Disks & storage" $(is_installed cockpit-storaged)
  "cockpit-podman" "Container management" $(is_installed cockpit-podman)
  "cockpit-sosreport" "Diagnostics reports" $(is_installed cockpit-sosreport)
  "cockpit-navigator" "File browser (45Drives)" $(is_installed cockpit-navigator)
  "cockpit-file-sharing" "SMB/NFS shares (45Drives)" $(is_installed cockpit-file-sharing)
  "cockpit-identities" "User & group management (45Drives)" $(is_installed cockpit-identities)
)

# Show menu
SELECTED=$(whiptail --title "Cockpit Suite Modules" --checklist \
"Select Cockpit components to install (SPACE = select, ENTER = confirm)" 20 80 10 \
"${OPTIONS[@]}" 3>&1 1>&2 2>&3)

# Cleanup quotes and spaces
SELECTED=$(echo $SELECTED | tr -d '"')

# Output selected modules (can be captured by another script)
echo "$SELECTED"

# Call the installer with the selected modules as arguments
"$SCRIPT_DIR/03-cockpit-install-cockpit-suite.disabled.sh" $SELECTED