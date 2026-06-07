#!/usr/bin/env bash
# phase-0/03-cockpit-install.sh
# Shows a TUI module selector then installs Cockpit core + chosen modules.
# Can also be called non-interactively: ./03-cockpit-install.sh module1 module2 ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TMP_DIR="$(mktemp -d /tmp/cockpit-suite.XXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

bold "${GREEN}🧰 Cockpit Suite Installer${RESET}"
line

require_sudo
detect_pkg_manager

# ── Load OS info ──────────────────────────
# shellcheck source=/dev/null
source /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
info "Detected OS: ${YELLOW}${PRETTY_NAME}${RESET}"
line

# ── Module selection ──────────────────────
# If modules are passed as arguments, use them directly.
# Otherwise show the whiptail TUI selector.
if [ $# -gt 0 ]; then
  SELECTED=("$@")
  info "Modules provided via arguments: ${SELECTED[*]}"
else
  ensure_cmd whiptail whiptail

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

  raw_selection=$(whiptail \
    --title "Cockpit Suite Modules" \
    --checklist "Select Cockpit components (SPACE = select, ENTER = confirm)" \
    20 80 10 \
    "${OPTIONS[@]}" \
    3>&1 1>&2 2>&3) || { warn "Selection cancelled — nothing will be installed."; exit 0; }

  # whiptail wraps each item in quotes; strip them and split into array
  IFS=' ' read -r -a SELECTED <<< "$(echo "$raw_selection" | tr -d '"')"

  if [ ${#SELECTED[@]} -eq 0 ]; then
    warn "No modules selected. Nothing to install."
    exit 0
  fi

  info "Selected modules: ${SELECTED[*]}"
fi

line

# ── Install Cockpit core ──────────────────
info "Installing Cockpit core + jq..."
apt_update_once
if apt-cache policy cockpit 2>/dev/null | grep -q "${CODENAME}-backports"; then
  $SUDO apt-get install -y -t "${CODENAME}-backports" cockpit jq
else
  $SUDO apt-get install -y cockpit jq
fi
ok "Cockpit core installed."
line

# ── 45Drives GitHub .deb installer ───────
install_45drives_deb() {
  local repo="$1" pattern="$2" name="$3"
  info "Fetching latest release for ${repo}..."

  local url
  url=$(curl -fsSL "https://api.github.com/repos/45Drives/${repo}/releases/latest" \
        | jq -r '.assets[]?.browser_download_url // empty' \
        | grep -E "$pattern" | head -n1)

  if [ -z "$url" ]; then
    url=$(curl -fsSL "https://api.github.com/repos/45Drives/${repo}/releases" \
          | jq -r '.[0].assets[]?.browser_download_url // empty' \
          | grep -E 'bookworm.*\.deb' | head -n1)
  fi

  [ -n "$url" ] || { warn "No .deb found for ${repo}. Skipping."; return; }

  info "Installing ${name} from ${repo}..."
  curl -fsSL -o "${TMP_DIR}/${repo}.deb" "$url"
  $SUDO dpkg -i "${TMP_DIR}/${repo}.deb" || $SUDO apt-get install -yf
  ok "Installed ${name}."
}

# ── Install selected modules ──────────────
info "Installing selected modules..."
apt_update_once

for pkg in "${SELECTED[@]}"; do
  info "Processing: ${pkg}"

  if apt-cache show "$pkg" >/dev/null 2>&1; then
    $SUDO apt-get install -y "$pkg" && ok "Installed ${pkg}." || warn "apt failed for ${pkg}."
  else
    warn "${pkg} not in apt — trying fallback..."
    case "$pkg" in
      cockpit-navigator)
          echo -e "${BLUE}⬇️ Installing Cockpit Navigator (direct download)...${RESET}"
          NAV_URL="https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator_0.5.10-1focal_all.deb"
          curl -L -o "${TMP_DIR}/cockpit-navigator.deb" "$NAV_URL"
          sudo apt install -y "${TMP_DIR}/cockpit-navigator.deb" || sudo apt install -yf
          echo -e "${GREEN}✅ Cockpit Navigator installed.${RESET}"
          ;;
      cockpit-file-sharing)
        install_45drives_deb "cockpit-file-sharing" "(_all|_amd64)\.deb$" "File Sharing"
        ;;
      cockpit-identities)
        install_45drives_deb "cockpit-identities" "(_all|_amd64)\.deb$" "Identities"
        ;;
      *)
        warn "No installation method available for ${pkg}. Skipping."
        ;;
    esac
  fi
done
line

# ── Enable Cockpit ────────────────────────
info "Enabling Cockpit service..."
$SUDO systemctl enable --now cockpit.socket

IP="$(hostname -I | awk '{print $1}')"
line
bold "${GREEN}🎉 Cockpit Suite ready!${RESET}"
echo -e "🌐 Access: ${YELLOW}https://${IP}:9090${RESET}"
echo -e "💡 Login with your normal system credentials."
line

# ── Summary ───────────────────────────────
bold "${BLUE}📋 Module Summary:${RESET}"
for pkg in "${SELECTED[@]}"; do
  dpkg -l "$pkg" &>/dev/null \
    && echo -e "   ${GREEN}✔ ${pkg}${RESET}" \
    || echo -e "   ${RED}✖ ${pkg}${RESET}"
done
line