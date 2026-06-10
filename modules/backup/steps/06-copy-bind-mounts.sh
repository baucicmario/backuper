#!/usr/bin/env bash
# tasks/06-copy-bind-mounts.sh
# Copy bind-mounted host directories into a service output folder.
# Decision logic per mount:
#   1. container path basename is in known-config-mounts.txt  → always copy
#   2. --copy-all flag                                         → always copy
#   3. --reject-all flag                                       → skip
#   4. mount is small (< SIZE_THRESHOLD_MB)                    → always copy
#   5. otherwise                                               → prompt y/n
# Usage: 06-copy-bind-mounts.sh <service_dir> [prompt|copy-all|reject-all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

require_cmd yq

SERVICE_DIR="${1:?Usage: $0 <service_dir> [prompt|copy-all|reject-all]}"
MOUNT_MODE="${2:-prompt}"

[[ -d "$SERVICE_DIR" ]] || die "Service dir not found: $SERVICE_DIR"

COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
ENV_FILE="$SERVICE_DIR/.env"
META_FILE="$SERVICE_DIR/.stack-meta"
KNOWN_LIST="$SCRIPT_DIR/../data/known-config-mounts.txt"
SIZE_THRESHOLD_MB=50

[[ -f "$COMPOSE_FILE" ]] || { warn "No docker-compose.yml in $SERVICE_DIR — skipping"; exit 0; }

load_env "$ENV_FILE"

ORIGINAL_STACK_DIR=""
SERVICE_NAME=""
if [[ -f "$META_FILE" ]]; then
  SOURCE_FILE="$(grep '^SOURCE_FILE=' "$META_FILE" | cut -d= -f2-)"
  [[ -n "$SOURCE_FILE" ]] && ORIGINAL_STACK_DIR="$(dirname "$SOURCE_FILE")"
  SERVICE_NAME="$(grep '^SERVICE_NAME=' "$META_FILE" | cut -d= -f2-)"
fi

# Load the ORIGINAL stack's .env so all vars like $CONTAINERS_ROOT are available for expansion
if [[ -n "$ORIGINAL_STACK_DIR" && -f "$ORIGINAL_STACK_DIR/.env" ]]; then
  load_env "$ORIGINAL_STACK_DIR/.env"
fi

is_known_config() {
  local name="${1,,}"
  [[ -f "$KNOWN_LIST" ]] || return 1
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" =~ ^# ]] && continue
    [[ "${entry,,}" == "$name" ]] && return 0
  done < "$KNOWN_LIST"
  return 1
}

# Duplicate original stdin (from python/user) to fd 3 so we can read from it inside the piped loop
exec 3<&0

SEEN_MOUNTS=()
while IFS= read -r raw_volume; do
  [[ -z "$raw_volume" ]] && continue

  # Parse container path from raw string BEFORE any expansion — it never contains env vars
  container_path="$(echo "$raw_volume" | cut -d':' -f2)"
  mount_name="$(basename "$container_path")"

  # Expand env vars only for the host path
  raw_host="$(echo "$raw_volume" | cut -d':' -f1)"
  host_path="$(eval echo "$raw_host" 2>/dev/null || echo "$raw_host")"

  # Skip named/anonymous volumes (host side is not a path)
  if [[ ! "$host_path" =~ ^[/\.] ]] && [[ ! "$host_path" =~ ^~ ]]; then
    info "Skipping named volume: $raw_volume"
    continue
  fi

  # Resolve relative paths against the original stack directory
  if [[ "$host_path" =~ ^\. ]] && [[ -n "$ORIGINAL_STACK_DIR" ]]; then
    host_path="$(realpath -m "$ORIGINAL_STACK_DIR/$host_path")"
  fi

  if [[ ! -d "$host_path" ]]; then
    warn "Skipping: source '$host_path' does not exist."
    continue
  fi

  # Destination with collision guard
  dest_name="$mount_name"
  if [[ " ${SEEN_MOUNTS[*]:-} " =~ " $dest_name " ]] && [[ -n "$SERVICE_NAME" ]]; then
    dest_name="${SERVICE_NAME}__${dest_name}"
  fi
  SEEN_MOUNTS+=("$dest_name")
  dest_path="$SERVICE_DIR/$dest_name"

  # Skip self-copy
  if [[ "$(realpath "$host_path")" == "$(realpath "$dest_path" 2>/dev/null || echo "")" ]]; then
    info "Skipping self-copy: $host_path"
    continue
  fi

  # ── Decision logic ──────────────────────────────────────────────────────────

  # 1. Known config mount — always copy
  if is_known_config "$mount_name"; then
    info "Known config mount — copying: $host_path"
    bash "$SCRIPT_DIR/08-copy-dir.sh" "$host_path" "$dest_path"
    continue
  fi

  # 2. copy-all — copy everything
  if [[ "$MOUNT_MODE" == "copy-all" ]]; then
    info "copy-all — copying: $host_path"
    bash "$SCRIPT_DIR/08-copy-dir.sh" "$host_path" "$dest_path"
    continue
  fi

  # 3. reject-all — skip unknown mounts
  if [[ "$MOUNT_MODE" == "reject-all" ]]; then
    warn "reject-all — skipping: $host_path → $container_path"
    continue
  fi

  # 4. Small mount — copy automatically
  size_mb="$(calc_size_with_spinner "  Calculating size of $host_path..." -sm "$host_path")"
  if [[ "$size_mb" -le "$SIZE_THRESHOLD_MB" ]]; then
    info "Small mount (${size_mb}MB) — copying: $host_path"
    bash "$SCRIPT_DIR/08-copy-dir.sh" "$host_path" "$dest_path"
    continue
  fi

  # 5. Large unknown mount — prompt
  echo
  warn "Large mount (${size_mb}MB) — not a known config folder"
  echo -e "  Host path      : $host_path"
  echo -e "  Container path : $container_path"
  printf "  Copy it? [y/N] "
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    read -r answer <&3
  else
    read -r answer </dev/tty 2>/dev/null || read -r answer <&3
  fi
  if [[ "${answer,,}" == "y" ]]; then
    info "  Copying large mount (this may take a while)..."
    bash "$SCRIPT_DIR/08-copy-dir.sh" "$host_path" "$dest_path"
  else
    warn "  Skipped: $host_path"
  fi

done < <(yq '.services.*.volumes[]' "$COMPOSE_FILE" 2>/dev/null || true)

exec 3<&-

ok "Bind-mount copy complete for: $(basename "$SERVICE_DIR")"