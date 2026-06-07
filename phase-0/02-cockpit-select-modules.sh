#!/usr/bin/env bash
# phase-0/02-cockpit-select-modules.sh
# TUI checklist to pick Cockpit modules, then delegates to 03-cockpit-install.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

INSTALLER="$SCRIPT_DIR/03-cockpit-install.sh"
[ -f "$INSTALLER" ] || die "Cockpit installer not found: $INSTALLER"

require_sudo
detect_pkg_manager
ensure_cmd whiptail whiptail

# ── Helper: check if a deb package is installed ───
is_installed() { dpkg -l "$1" &>/dev/null && echo "ON" || echo "OFF"; }

OPTIONS=(
  "cockpit-networkmanager"  "Network management"                  "$(is_installed cockpit-networkmanager)"
  "cockpit-packagekit"      "GUI updates"                         "$(is_installed cockpit-packagekit)"
  "cockpit-storaged"        "Disks & storage"                     "$(is_installed cockpit-storaged)"
  "cockpit-podman"          "Container management"                "$(is_installed cockpit-podman)"
  "cockpit-sosreport"       "Diagnostics reports"                 "$(is_installed cockpit-sosreport)"
  "cockpit-navigator"       "File browser (45Drives)"             "$(is_installed cockpit-navigator)"
  "cockpit-file-sharing"    "SMB/NFS shares (45Drives)"           "$(is_installed cockpit-file-sharing)"
  "cockpit-identities"      "User & group management (45Drives)"  "$(is_installed cockpit-identities)"
)

# ── Show TUI checklist ────────────────────
SELECTED=$(whiptail \
  --title "Cockpit Suite Modules" \
  --checklist "Select Cockpit components (SPACE = select, ENTER = confirm)" \
  20 80 10 \
  "${OPTIONS[@]}" \
  3>&1 1>&2 2>&3) || { warn "Selection cancelled."; exit 0; }

# Strip surrounding quotes added by whiptail
SELECTED=$(echo "$SELECTED" | tr -d '"')

if [ -z "$SELECTED" ]; then
  warn "No modules selected. Nothing to install."
  exit 0
fi

info "Selected modules: $SELECTED"
bash "$INSTALLER" $SELECTED