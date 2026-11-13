#!/usr/bin/env bash
# phase-0/03-cockpit-install.sh
# Shows a TUI module selector then installs Cockpit core + chosen modules.
# Can also be called non-interactively: ./03-cockpit-install.sh module1 module2 ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Create temporary directory for downloading .debs; clean up on exit
TMP_DIR="$(mktemp -d /tmp/cockpit-suite.XXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

bold "${GREEN}🧰 Cockpit Suite Installer${RESET}"
line

# Check for sudo access and detect the package manager
require_sudo
detect_pkg_manager

# ── Load OS info ──────────────────────────────────────────────
# Read /etc/os-release to get distribution details
# shellcheck source=/dev/null
source /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
info "Detected OS: ${YELLOW}${PRETTY_NAME}${RESET}"
line

# ── PackageKit / NetworkManager conflict fix ─────────────────
# Cockpit uses PackageKit (packagekit.service) for software updates.
# On systems where systemd-networkd manages networking (common on Ubuntu Server),
# NetworkManager sees all interfaces as unmanaged and reports disconnected.
# PackageKit queries NetworkManager by default, assumes the machine is offline,
# and fails with: "Cannot refresh cache whilst offline".
# Complete resolution:
# 1. Set UseNetworkManager=false in PackageKit.conf
# 2. Set managed=true in NetworkManager.conf [ifupdown]
# 3. Create a dummy network connection 'fake' with a gateway so NetworkManager detects an active route
# 4. Bring up the dummy connection
# 5. Cleanly restart NetworkManager and purge/restart packagekitd
configure_packagekit_networkmanager() {
  local pk_config="/etc/PackageKit/PackageKit.conf"
  local nm_config="/etc/NetworkManager/NetworkManager.conf"

  info "Applying complete Cockpit connectivity & package update fix..."

  # 1. Update PackageKit configuration (UseNetworkManager=false)
  if [ -f "$pk_config" ] || [ -d "/etc/PackageKit" ] || command -v packagekitd >/dev/null 2>&1; then
    info "Configuring PackageKit (UseNetworkManager=false)..."
    if [ ! -f "$pk_config" ]; then
      $SUDO mkdir -p "/etc/PackageKit"
      printf "[Daemon]\nUseNetworkManager=false\n" | $SUDO tee "$pk_config" >/dev/null
    elif grep -Eq '^[[:space:]]*#?[[:space:]]*UseNetworkManager=' "$pk_config"; then
      $SUDO sed -i -E 's/^[[:space:]]*#?[[:space:]]*UseNetworkManager=.*/UseNetworkManager=false/' "$pk_config"
    elif grep -q '\[Daemon\]' "$pk_config"; then
      $SUDO sed -i '/\[Daemon\]/a UseNetworkManager=false' "$pk_config"
    else
      printf "\n[Daemon]\nUseNetworkManager=false\n" | $SUDO tee -a "$pk_config" >/dev/null
    fi
    ok "Updated PackageKit configuration ($pk_config)."
  fi

  # 2. Update NetworkManager configuration (set managed=true for ifupdown)
  if [ -f "$nm_config" ]; then
    info "Configuring NetworkManager (managed=true)..."
    if grep -q "managed=false" "$nm_config"; then
      $SUDO sed -i 's/managed=false/managed=true/' "$nm_config"
      ok "Updated NetworkManager config: managed=true."
    elif ! grep -q "managed=true" "$nm_config"; then
      if grep -q '\[ifupdown\]' "$nm_config"; then
        $SUDO sed -i '/\[ifupdown\]/a managed=true' "$nm_config"
      else
        printf "\n[ifupdown]\nmanaged=true\n" | $SUDO tee -a "$nm_config" >/dev/null
      fi
      ok "Added managed=true to NetworkManager config."
    fi
  elif [ -d "/etc/NetworkManager" ]; then
    printf "[main]\nplugins=ifupdown,keyfile\n\n[ifupdown]\nmanaged=true\n" | $SUDO tee "$nm_config" >/dev/null
    ok "Created NetworkManager config with managed=true."
  fi

  # 3. Create dummy network connection if it doesn't already exist
  if command -v nmcli >/dev/null 2>&1; then
    if ! nmcli con show 2>/dev/null | grep -q "fake"; then
      info "Creating dummy network connection 'fake'..."
      $SUDO nmcli con add type dummy con-name fake ifname fake0 ip4 1.2.3.4/24 gw4 1.2.3.1 2>/dev/null || warn "Could not add dummy connection 'fake'."
    else
      ok "Dummy network connection 'fake' already exists."
    fi

    # 4. Bring up the dummy connection
    info "Bringing up dummy connection..."
    $SUDO nmcli con up fake 2>/dev/null || true
  fi

  # 5. Restart NetworkManager and PackageKit cleanly
  if command -v systemctl >/dev/null 2>&1; then
    info "Restarting NetworkManager and PackageKit services..."
    $SUDO systemctl restart NetworkManager 2>/dev/null || true
    $SUDO systemctl stop packagekit 2>/dev/null || true
    $SUDO pkill -f packagekitd 2>/dev/null || true
    $SUDO systemctl start packagekit 2>/dev/null || warn "PackageKit service start deferred (starts on demand via D-Bus)."
    ok "NetworkManager and PackageKit services refreshed."
  fi
}

# ── Module selection ──────────────────────
# If modules are passed as arguments, use them directly.
# Otherwise show the whiptail TUI selector.
if [ $# -gt 0 ]; then
  case "${1:-}" in
    --fix-packagekit|--fix-networkmanager|--fix-connectivity|--fix-only)
      configure_packagekit_networkmanager
      exit 0
      ;;
    --help|-h)
      echo "Usage: $0 [module1 module2 ...] [--fix-packagekit]"
      exit 0
      ;;
  esac
  SELECTED=("$@")
  info "Modules provided via arguments: ${SELECTED[*]}"
else
  ensure_cmd whiptail whiptail

  # Helper function to check if a package is installed (for TUI checklist)
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

  # Launch whiptail checklist; redirect stdin/stdout/stderr for proper terminal handling
  raw_selection=$(whiptail \
    --title "Cockpit Suite Modules" \
    --checklist "Select Cockpit components (SPACE = select, ENTER = confirm)" \
    20 80 10 \
    "${OPTIONS[@]}" \
    3>&1 1>&2 2>&3) || { warn "Selection cancelled — nothing will be installed."; exit 0; }

  # Parse whiptail output: it returns quoted strings, so strip quotes and split
  IFS=' ' read -r -a SELECTED <<< "$(echo "$raw_selection" | tr -d '"')"

  if [ ${#SELECTED[@]} -eq 0 ]; then
    warn "No modules selected. Nothing to install."
    exit 0
  fi

  info "Selected modules: ${SELECTED[*]}"
fi

line

# ── Step 1: Install Cockpit core and jq ───────────────────
info "Installing Cockpit core + jq..."
apt_update_once  # Update package lists once
# Try to install from backports if available for newer versions
if apt-cache policy cockpit 2>/dev/null | grep -q "${CODENAME}-backports"; then
  $SUDO apt-get install -y -t "${CODENAME}-backports" cockpit jq
else
  $SUDO apt-get install -y cockpit jq
fi
ok "Cockpit core installed."
line

# ── Step 2: Install selected 45Drives modules ─────────────
# Helper function to download and install a .deb from a 45Drives GitHub repo
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
          $SUDO apt-get install -y "${TMP_DIR}/cockpit-navigator.deb" || $SUDO apt-get install -yf
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

# ── Step 3: Configure PackageKit (Fix NetworkManager conflict) ─
configure_packagekit_networkmanager
line

# ── Step 4: Enable Cockpit ────────────────
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
if [ -f "/etc/PackageKit/PackageKit.conf" ] && grep -Eq '^[[:space:]]*UseNetworkManager=false' /etc/PackageKit/PackageKit.conf 2>/dev/null; then
  echo -e "   ${GREEN}✔ PackageKit & NetworkManager connectivity fix applied${RESET}"
fi
line
