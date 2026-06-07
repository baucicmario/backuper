#!/usr/bin/env bash
# phase-1/02-copy-mounts.sh
# Copies host-mounted volume directories into the compose file's directory.
# Usage: ./02-copy-mounts.sh [compose_file] [env_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

COMPOSE_FILE="${1:-./docker-compose.yml}"
ENV_FILE="${2:-./.env}"

# ── Pre-flight checks ─────────────────────
require_cmd yq

[ -f "$COMPOSE_FILE" ] \
  || die "Docker Compose file not found at $COMPOSE_FILE"

# ── Load env safely ───────────────────────
load_env "$ENV_FILE"

COMPOSE_DIR="$(dirname "$(realpath "$COMPOSE_FILE")")"
info "Target destination folder: $COMPOSE_DIR"
line

# ── Parse and process volumes ─────────────
info "Scanning for volumes..."

yq '.services.*.volumes[]' "$COMPOSE_FILE" 2>/dev/null | while read -r raw_volume; do
  [ -z "$raw_volume" ] && continue

  # Resolve environment variables in the volume string
  expanded_volume="$(eval echo "$raw_volume")"

  host_path="$(echo "$expanded_volume" | cut -d':' -f1)"
  container_path="$(echo "$expanded_volume" | cut -d':' -f2)"

  # Skip named and anonymous volumes (no leading / . or ~)
  if [[ ! "$host_path" =~ ^[/\.] ]] && [[ ! "$host_path" =~ ^~ ]]; then
    info "Skipping named/anonymous volume: $expanded_volume"
    continue
  fi

  # Expand tilde
  eval host_path="$host_path"

  # Skip if source doesn't exist
  if [ ! -d "$host_path" ]; then
    warn "Skipping: source directory '$host_path' does not exist."
    continue
  fi

  dest_folder_name="$(basename "$container_path")"
  destination_path="$COMPOSE_DIR/$dest_folder_name"

  # Skip self-copy
  if [ "$(realpath "$host_path")" = "$(realpath "$destination_path" 2>/dev/null || echo "")" ]; then
    info "Skipping: '$host_path' is already the destination."
    continue
  fi

  # ── Copy ──────────────────────────────
  info "Copying: $host_path → $destination_path"
  mkdir -p "$destination_path"

  if cp -a "$host_path/." "$destination_path/"; then
    ok "Copied to $destination_path"
  else
    warn "Failed to copy $host_path"
  fi
  line
done

ok "Process complete!"