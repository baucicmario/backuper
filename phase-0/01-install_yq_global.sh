#!/usr/bin/env bash

set -e

# Target directory for global binaries
GLOBAL_BIN="/usr/local/bin/yq"

echo "=========================================="
echo "      Global yq Installer Script          "
echo "=========================================="

# 1. Privilege Check
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo &> /dev/null; then
        SUDO="sudo"
        echo "Root privileges required. You may be prompted for your sudo password."
    else
        echo "Error: This script must be run as root or with 'sudo' access."
        exit 1
    fi
fi

# 2. Check if already installed
if command -v yq &> /dev/null; then
    echo "yq is already installed globally at: $(command -v yq)"
    echo "Current version: $(yq --version)"
    read -p "Do you want to reinstall/overwrite it? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
fi

# 3. Detect OS and CPU Architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l)  ARCH="arm" ;;
    *)
        echo "Error: Unsupported CPU architecture ($ARCH)."
        exit 1
        ;;
esac

BINARY_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_${OS}_${ARCH}"

# 4. Download and Deploy
echo "Downloading latest yq binary for ${OS} (${ARCH})..."

if command -v curl &> /dev/null; then
    $SUDO curl -sL "$BINARY_URL" -o "$GLOBAL_BIN"
elif command -v wget &> /dev/null; then
    $SUDO wget -qO "$GLOBAL_BIN" "$BINARY_URL"
else
    echo "Error: Neither curl nor wget is available. Please install one of them first."
    exit 1
fi

# 5. Set Permissions & Verify
echo "Setting executable permissions..."
$SUDO chmod +x "$GLOBAL_BIN"

if command -v yq &> /dev/null; then
    echo "------------------------------------------"
    echo "Success! yq installed successfully to $GLOBAL_BIN"
    echo "Verified version: $(yq --version)"
    echo "------------------------------------------"
else
    echo "Error: Installation finished, but 'yq' command is still not reachable."
    exit 1
fi