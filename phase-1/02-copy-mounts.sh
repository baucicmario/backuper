#!/usr/bin/env bash
# phase-1/02-copy-mounts.sh
# Copies host-mounted volume directories into each split stack's compose directory.
# Automatically handles both native Linux (cp -a, full fidelity) and NTFS/WSL
# destinations (cp -r, data-only) by detecting metadata errors at runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Defaults ──────────────────────────────
_default_split_dir="${CENTRAL_BACKUP_DIR:+$CENTRAL_BACKUP_DIR/split_stacks}"
_default_split_dir="${_default_split_dir:-$SCRIPT_DIR/split_stacks}"
SPLIT_DIR="$_default_split_dir"

# ── Argument parsing ──────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      shift
      [[ -n "${1:-}" ]] || die "--output requires a path argument"
      SPLIT_DIR="$1"
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--output <split_stacks_dir>]"
      exit 0
      ;;
    -*) die "Unknown flag: $1" ;;
    *)  SPLIT_DIR="$1" ;;   # positional fallback still works
  esac
  shift
done

require_cmd yq

[ -d "$SPLIT_DIR" ] || die "Split stacks directory not found: $SPLIT_DIR"

# ── Smart copy: tries full archive first, falls back to data-only on NTFS ─────
# Usage: smart_copy <src> <dst>
#
# On native Linux:  cp -a succeeds → full ownership/perms/timestamps preserved.
# On NTFS/WSL:      cp -a exits non-zero with "preserving X" stderr → retry with
#                   cp -r (no metadata) which succeeds silently.
# Real failures:    stderr contains neither "preserving times" nor "preserving
#                   permissions" → shown to user as a genuine error.
smart_copy() {
  local src="$1"
  local dst="$2"
  local stderr_file
  stderr_file="$(mktemp)"

  # First attempt: full archive copy (correct on native Linux)
  if cp -a "$src/." "$dst/" 2>"$stderr_file"; then
    ok "Copied to $dst"
    rm -f "$stderr_file"
    return 0
  fi

  # Check if the failure is purely metadata-related (NTFS/WSL symptom)
  if grep -qE 'preserving (times|permissions|ownership)' "$stderr_file"; then
    # Data copied fine — NTFS just can't store Linux metadata. Retry data-only.
    info "  (metadata not supported by destination filesystem — retrying without preserve)"
    if cp -r "$src/." "$dst/" 2>"$stderr_file"; then
      ok "Copied to $dst (data only — metadata skipped)"
      rm -f "$stderr_file"
      return 0
    fi
    # cp -r itself can still whine about "preserving times" on some WSL builds
    if grep -qE 'preserving (times|permissions|ownership)' "$stderr_file"; then
      ok "Copied to $dst (data only — metadata skipped)"
      rm -f "$stderr_file"
      return 0
    fi
  fi

  # Genuine failure (disk full, read permission denied, etc.)
  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  warn "Failed to copy $src"
}

# ── Discover split stack folders ──────────────────────────────────────────────
mapfile -t STACK_DIRS < <(find "$SPLIT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

[ ${#STACK_DIRS[@]} -gt 0 ] || { warn "No split stack folders found in $SPLIT_DIR"; exit 0; }

# ── Process each split stack ──────────────────────────────────────────────────
for stack_dir in "${STACK_DIRS[@]}"; do
  COMPOSE_FILE="$stack_dir/docker-compose.yml"
  ENV_FILE="$stack_dir/.env"

  if [ ! -f "$COMPOSE_FILE" ]; then
    warn "No docker-compose.yml in $stack_dir — skipping"
    continue
  fi

  line
  info "Processing: $stack_dir"

  load_env "$ENV_FILE"

  COMPOSE_DIR="$(dirname "$(realpath "$COMPOSE_FILE")")"
  info "Target destination folder: $COMPOSE_DIR"

  yq '.services.*.volumes[]' "$COMPOSE_FILE" 2>/dev/null | while read -r raw_volume; do
    [ -z "$raw_volume" ] && continue

    # Expand any $VAR references from the loaded .env
    expanded_volume="$(eval echo "$raw_volume")"
    host_path="$(echo "$expanded_volume" | cut -d':' -f1)"
    container_path="$(echo "$expanded_volume" | cut -d':' -f2)"

    # Skip named/anonymous volumes (no leading / . or ~)
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

    info "Copying: $host_path → $destination_path"
    mkdir -p "$destination_path"
    smart_copy "$host_path" "$destination_path"
  done
done

line
ok "Process complete!"