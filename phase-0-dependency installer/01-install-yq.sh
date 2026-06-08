#!/usr/bin/env bash
# phase-0/01-install-yq.sh
# Downloads and installs the latest yq binary globally to /usr/local/bin.
# Safe to run standalone or called by 00-install-deps.sh.
# Pass --force to reinstall even if yq is already present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

GLOBAL_BIN="/usr/local/bin/yq"

bold "=========================================="
bold "        Global yq Installer               "
bold "=========================================="

require_sudo

# ── Already installed? ────────────────────
if command -v yq >/dev/null 2>&1; then
  ok "yq already installed: $(yq --version)"
  if [[ "${1:-}" != "--force" ]]; then
    info "Pass --force to reinstall/overwrite."
    exit 0
  fi
  warn "Reinstalling yq (--force)..."
fi

# ── Detect OS + arch ─────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l)        ARCH="arm"   ;;
  *) die "Unsupported CPU architecture: $ARCH" ;;
esac

BINARY_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_${OS}_${ARCH}"
info "Downloading yq for ${OS}/${ARCH}..."

# ── Download ──────────────────────────────
if command -v curl >/dev/null 2>&1; then
  $SUDO curl -fsSL "$BINARY_URL" -o "$GLOBAL_BIN"
elif command -v wget >/dev/null 2>&1; then
  $SUDO wget -qO "$GLOBAL_BIN" "$BINARY_URL"
else
  die "Neither curl nor wget found. Install one first."
fi

# ── Permissions + verify ──────────────────
$SUDO chmod +x "$GLOBAL_BIN"

command -v yq >/dev/null 2>&1 \
  || die "yq was installed to $GLOBAL_BIN but is not reachable in PATH."

ok "yq installed: $(yq --version)"