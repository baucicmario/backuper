#!/usr/bin/env bash
# tasks/03-backup-library.sh
# Locate the Immich upload library from the compose/env and copy it to the
# backup directory using rsync (with cp fallback for unsupportive filesystems).
#
# Inputs (env, all set by orchestrator):
#   STATE_FILE   — path to the state file (must contain BACKUP_DIR after task 02)
#
# Outputs:
#   $BACKUP_DIR/library/   — copy of the Immich upload library
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_sudo

# ── Source state ──────────────────────────────────────────────────────────────
STATE_FILE="${STATE_FILE:?STATE_FILE must be set by the orchestrator}"
[[ -f "$STATE_FILE" ]] || die "Detection state not found: $STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

: "${IMMICH_COMPOSE_FILE:?}"
: "${IMMICH_ENV_FILE:?}"
: "${IMMICH_SERVICE:?}"
: "${BACKUP_DIR:?Missing BACKUP_DIR — did 02-backup-database.sh run first?}"

load_env "$IMMICH_ENV_FILE"

# ── Resolve upload source path ────────────────────────────────────────────────
# Priority: UPLOAD_LOCATION env var → first absolute bind-mount of the immich-server service
upload_src="${UPLOAD_LOCATION:-}"

if [[ -z "$upload_src" ]]; then
  upload_src="$(
    yq -r ".services[\"$IMMICH_SERVICE\"].volumes[]? | select(type == \"!!str\")" \
      "$IMMICH_COMPOSE_FILE" 2>/dev/null \
      | awk -F: '$1 ~ /^\// { print $1; exit }'
  )" || true
fi

[[ -n "$upload_src"    ]] || die "Could not determine upload library path. Set UPLOAD_LOCATION in the Immich .env."
[[ -d "$upload_src"    ]] || die "Upload library source is not a directory: $upload_src"

upload_dst="$BACKUP_DIR/library"

bold "📂 Library Backup"
line
info "  Source  : $upload_src"
info "  Target  : $upload_dst"
line

# ── Copy helper (rsync → cp → sudo cp) ───────────────────────────────────────
smart_copy() {
  local src="$1" dst="$2"
  local stderr_file
  stderr_file="$(mktemp)"
  mkdir -p "$dst"

  # Attempt 1: rsync, no metadata (works across most filesystems)
  if rsync -rltD \
      --no-perms --no-owner --no-group \
      --omit-dir-times \
      "$src"/ "$dst"/ 2>"$stderr_file"; then
    rm -f "$stderr_file"
    return 0
  fi

  # Attempt 2: plain cp (NTFS, WSL, or any rsync-less system)
  if grep -qE 'failed to set times|Operation not permitted|some files/attrs were not transferred' \
      "$stderr_file" || ! command -v rsync >/dev/null 2>&1; then
    info "  (rsync metadata issue — retrying with cp)"
    rm -rf "$dst"; mkdir -p "$dst"
    if cp -r "$src"/. "$dst" 2>"$stderr_file"; then
      rm -f "$stderr_file"
      return 0
    fi
  fi

  # Attempt 3: sudo cp (container-owned files)
  if grep -q 'Permission denied' "$stderr_file"; then
    info "  (permission denied — retrying with sudo cp)"
    rm -rf "$dst"; mkdir -p "$dst"
    if $SUDO cp -r "$src"/. "$dst" 2>"$stderr_file"; then
      rm -f "$stderr_file"
      return 0
    fi
  fi

  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  return 1
}

smart_copy "$upload_src" "$upload_dst" || die "Failed to copy upload library: $upload_src → $upload_dst"

library_size="$(du -sh "$upload_dst" 2>/dev/null | awk '{print $1}')"
ok "Library copied: $upload_dst  ($library_size)"

# ── Append to state ───────────────────────────────────────────────────────────
{
  printf 'UPLOAD_SOURCE=%q\n'    "$upload_src"
  printf 'LIBRARY_DST=%q\n'     "$upload_dst"
  printf 'LIBRARY_SIZE=%q\n'    "$library_size"
} >> "$STATE_FILE"
