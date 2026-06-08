#!/usr/bin/env bash
# phase-2/02-consolidate-immich.sh — Consolidate Immich backups
# Moves all extracted Immich-related services into a single consolidated folder.
# Also moves database backups into the same folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Configuration ──────────────────────────────────────────────────────────
IMMICH_STACK_PREFIX="${IMMICH_STACK_PREFIX:-immich}"  # Prefix for service folders
IMMICH_OUT_NAME="${IMMICH_OUT_NAME:-immich}"  # Name of consolidated folder

# ── Source and destination paths ──────────────────────────────────────────
SRC_SPLIT_DIR="$CENTRAL_BACKUP_DIR/split_stacks"  # Contains extracted services
SRC_DB_DIR="$CENTRAL_BACKUP_DIR/immich_backups"  # Contains database dumps
DST_DIR="$SRC_SPLIT_DIR/$IMMICH_OUT_NAME"  # Where to consolidate everything

# ── Show what we're doing ──────────────────────────────────────────────────
bold "📦 Immich Stack Consolidator"
line
info "  Source split_stacks : $SRC_SPLIT_DIR"
info "  Source DB backups   : $SRC_DB_DIR"
info "  Destination         : $DST_DIR"
line

# ── Validation ─────────────────────────────────────────────────────────────
[[  -d "$SRC_SPLIT_DIR" ]] || die "split_stacks not found: $SRC_SPLIT_DIR"

# Find all Immich-related service folders
mapfile -t IMMICH_DIRS < <(
  find "$SRC_SPLIT_DIR" -mindepth 1 -maxdepth 1 -type d -name "${IMMICH_STACK_PREFIX}__*" | sort
)

[[ ${#IMMICH_DIRS[@]} -gt 0 ]] || die "No '${IMMICH_STACK_PREFIX}__*' folders found in $SRC_SPLIT_DIR"
[[ -d "$DST_DIR" ]] && die "Destination already exists: $DST_DIR — remove it first or check if consolidation already ran"

# ═══════════════════════════════════════════════════════════════════════════
# CONSOLIDATION
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$DST_DIR"

# ── Step 1: Move all Immich service folders ────────────────────────────────
info "Moving service folders..."
for src_dir in "${IMMICH_DIRS[@]}"; do
  folder_name="$(basename "$src_dir")"
  # Strip the prefix to get the original service name
  service_name="${folder_name#${IMMICH_STACK_PREFIX}__}"
  dst_service_dir="$DST_DIR/$service_name"
  info "  Moving: $folder_name → immich/$service_name"
  mv "$src_dir" "$dst_service_dir"
  ok "  Moved $service_name"
done

# ── Step 2: Move database backups ──────────────────────────────────────────
if [[ -d "$SRC_DB_DIR" ]]; then
  mapfile -t DB_DIRS < <(find "$SRC_DB_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
  if [[ ${#DB_DIRS[@]} -eq 0 ]]; then
    warn "No DB backup folders found in $SRC_DB_DIR — skipping"
  else
    for db_dir in "${DB_DIRS[@]}"; do
      folder_name="$(basename "$db_dir")"
      dst_db="$DST_DIR/$folder_name"
      info "Moving DB backup: $db_dir → $dst_db"
      mv "$db_dir" "$dst_db"
      ok "Moved $folder_name"
    done
  fi

  # Clean up the source DB directory if now empty
  if [[ -z "$(ls -A "$SRC_DB_DIR")" ]]; then
    rmdir "$SRC_DB_DIR"
    info "Removed empty dir: $SRC_DB_DIR"
  fi
else
  warn "No immich_backups dir found at $SRC_DB_DIR — skipping DB dump move"
fi

echo
# ═══════════════════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════════════════
line
bold "✅ Done. Immich consolidated at: $DST_DIR"
line